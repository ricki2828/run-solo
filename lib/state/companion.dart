/// Run companion (phase 1): after a run the runner gets a short note in
/// Telegram (WhatsApp later). Everything here is behind the dogfood-only
/// compile flag `--dart-define=COMPANION=1` and, inside that, behind an
/// explicit "Turn on" tap (nothing pre-selected).
///
/// Enrolment (eng-review B1): the app asks the server for a nonce and a
/// Telegram deep link, opens the link, and polls until the runner's first
/// message in Telegram binds the nonce and the server hands back a device
/// token. The app never collects a phone number. The token lives in the
/// Android Keystore (flutter_secure_storage, excluded from backups) and goes
/// out as a Bearer header, never in a URL.
///
/// API contract (the server is `companion-server/`, PR #217):
/// - `POST /v1/enrol/start` (no body) -> `{nonce, poll_secret, expires_in,
///   links:{telegram}}`. The runner taps Start in Telegram; the bot replies
///   with a 6-digit code.
/// - `POST /v1/enrol/status` `{nonce, poll_secret}` -> `{state: pending|
///   awaiting_code|claimed|expired|denied|unknown}` (never a token)
/// - `POST /v1/enrol/confirm` `{nonce, poll_secret, code}` -> 200 `{state:
///   claimed, token}` (once); 403 wrong code, 410 expired or locked, 422 bad
/// - `POST /v1/runs` (Bearer) -> 202 `{status: accepted|stored}` or 200
///   `{status: duplicate}`; 401 bad token, 429 daily cap
/// - `PATCH /v1/runs/{run_id}/feel` (Bearer) `{feel}`
/// - `GET /v1/me`, `DELETE /v1/me` (Bearer)
/// - `GET /v1/me/next-session` (Bearer): the coach's next session and latest
///   line, for Home. 404 from a server without check-ins means "nothing".
/// - `PUT /v1/me/settings` `{weather: bool}`, `{route_shape: bool}` or
///   `{place_names: bool}` or `{heart_rate: bool}` (Bearer): the weather
///   switch, the "Show route shape on cards" switch, the "Show trail names on
///   cards" switch and the "Heart rate on cards" switch
///
/// A run summary carries, besides its totals, `splits` (per km), `reps` (a
/// structured run) and, while "Show route shape on cards" is on, `route`: a
/// outline with the ends cut off (see `companion_shape.dart` in run_engine), never a coordinate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/transfer_gateway.dart';
import 'coach_briefing.dart';
import 'history_store.dart';
import 'intervals_icu.dart' show SecretStore;
import 'send_runs.dart';
import 'settings.dart' show AppSettings;
import 'zone_histogram.dart';

/// `--dart-define=COMPANION=1` (or `true`). ON in the dogfood build and in the Play
/// release AAB (closed test, plan run-supreme-testers M1). The companion itself stays off
/// until the runner turns it on and accepts the consent.
const String _kCompanionFlag = String.fromEnvironment('COMPANION');
const bool kCompanion = _kCompanionFlag == '1' || _kCompanionFlag == 'true';

/// The companion server. Override with `--dart-define=COMPANION_URL=`.
const String kCompanionUrl = String.fromEnvironment(
  'COMPANION_URL',
  defaultValue: 'https://companion.taiaroa.xyz',
);

const String kCompanionPrivacyUrl = 'https://runsupreme.taiaroa.xyz/privacy/';

/// Bump when the consent copy changes in a way that needs a fresh "Turn on".
/// 2: check-ins (readiness and skip answers, kept 14 days).
const int kCompanionBaseConsent = 2;

/// 3: the coach (chat); what the server drops a runner to when memory is turned off.
const int kCompanionCoachConsent = 3;

/// 4: coach memory (the memory sheet: notes, training numbers, optional
/// health notes). Asked as its own step on top of version 2, never silently:
/// a runner who says "Not now" keeps everything they had, minus memory.
const int kCompanionConsentVersion = 4;

// ---------------------------------------------------------------- HTTP seam

@immutable
class CompanionRequest {
  const CompanionRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

@immutable
class CompanionReply {
  const CompanionReply(this.status, [this.body = '']);
  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;

  Map<String, Object?> get json {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, Object?>) return j;
    } on FormatException {
      // Falls through to empty.
    }
    return const {};
  }
}

/// Thrown by a [CompanionHttp] when no response arrived (offline, timeout).
class CompanionNetworkError implements Exception {
  const CompanionNetworkError();
}

abstract class CompanionHttp {
  /// Throws [CompanionNetworkError] when there is no response.
  Future<CompanionReply> send(CompanionRequest req);
}

/// dart:io over HTTPS with timeouts. Logs the error type only: error text
/// can carry request details.
class DartIoCompanionHttp implements CompanionHttp {
  const DartIoCompanionHttp({
    this.connectTimeout = const Duration(seconds: 15),
    this.timeout = const Duration(seconds: 30),
  });
  final Duration connectTimeout;
  final Duration timeout;

  @override
  Future<CompanionReply> send(CompanionRequest req) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final r = await client.openUrl(req.method, req.uri).timeout(timeout);
      req.headers.forEach(r.headers.set);
      if (req.body != null) {
        r.contentLength = req.body!.length;
        r.add(req.body!);
      }
      final res = await r.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      return CompanionReply(res.statusCode, text);
    } catch (e) {
      companionLog('request failed (${e.runtimeType})');
      throw const CompanionNetworkError();
    } finally {
      client.close(force: true);
    }
  }
}

/// The only logger here. [secrets] are blanked out of the line.
void companionLog(String line, {Iterable<String> secrets = const []}) {
  var out = line;
  for (final s in secrets) {
    if (s.isNotEmpty) out = out.replaceAll(s, '***');
  }
  debugPrint('companion: $out');
}

// ------------------------------------------------------------------- client

@immutable
class EnrolStart {
  const EnrolStart({
    required this.nonce,
    required this.pollSecret,
    required this.link,
  });
  final String nonce;

  /// Kept in memory only; never in a link or a message.
  final String pollSecret;
  final Uri link;
}

/// [awaitingCode]: the runner has tapped Start; the bot has sent the code.
/// [denied]: this build's owner is not on the server's allowlist.
enum EnrolPhase { pending, awaitingCode, claimed, expired, denied }

/// What a code entry came to.
enum ConfirmOutcome { ok, wrongCode, expired, malformed, busy }

@immutable
class ConfirmResult {
  const ConfirmResult(this.outcome, [this.token, this.chatName]);
  final ConfirmOutcome outcome;
  final String? token;

  /// The Telegram chat's display name, so the runner can see whose chat
  /// they just connected. Never the chat id.
  final String? chatName;
}

/// What a run send came to. [duplicate] counts as sent.
enum RunSendOutcome { sent, duplicate, unauthorized, outdated, rejected, busy }

class CompanionClient {
  CompanionClient({String? baseUrl, CompanionHttp? http})
    : base = Uri.parse(baseUrl ?? kCompanionUrl),
      http = http ?? const DartIoCompanionHttp();

  final Uri base;
  final CompanionHttp http;

  Uri _uri(List<String> segments, [Map<String, String>? query]) => base.replace(
    pathSegments: [
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...segments,
    ],
    queryParameters: query,
  );

  Map<String, String> _headers(String? token, {bool json = false}) => {
    'Accept': 'application/json',
    if (json) 'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// Null when the server said no or did not answer.
  Future<EnrolStart?> enrolStart() async {
    final r = await http.send(
      CompanionRequest(
        method: 'POST',
        uri: _uri(['v1', 'enrol', 'start']),
        headers: _headers(null),
      ),
    );
    if (!r.ok) return null;
    final j = r.json;
    final nonce = j['nonce'];
    final secret = j['poll_secret'];
    final links = j['links'];
    final link = links is Map ? links['telegram'] : null;
    if (nonce is! String || nonce.isEmpty) return null;
    if (secret is! String || secret.isEmpty || link is! String) return null;
    final uri = Uri.tryParse(link);
    if (uri == null || !uri.hasScheme) return null;
    return EnrolStart(nonce: nonce, pollSecret: secret, link: uri);
  }

  Future<EnrolPhase> enrolStatus(EnrolStart e) async {
    final r = await http.send(
      CompanionRequest(
        method: 'POST',
        uri: _uri(['v1', 'enrol', 'status']),
        headers: _headers(null, json: true),
        body: utf8.encode(
          jsonEncode({'nonce': e.nonce, 'poll_secret': e.pollSecret}),
        ),
      ),
    );
    if (!r.ok) return EnrolPhase.pending;
    return switch (r.json['state']) {
      'awaiting_code' => EnrolPhase.awaitingCode,
      'claimed' => EnrolPhase.claimed,
      'denied' => EnrolPhase.denied,
      'expired' || 'unknown' => EnrolPhase.expired,
      _ => EnrolPhase.pending,
    };
  }

  Future<ConfirmResult> enrolConfirm(EnrolStart e, String code) async {
    final r = await http.send(
      CompanionRequest(
        method: 'POST',
        uri: _uri(['v1', 'enrol', 'confirm']),
        headers: _headers(null, json: true),
        body: utf8.encode(
          jsonEncode({
            'nonce': e.nonce,
            'poll_secret': e.pollSecret,
            'code': code,
          }),
        ),
      ),
    );
    if (r.ok) {
      final t = r.json['token'];
      final name = r.json['chat_name'];
      return t is String && t.isNotEmpty
          ? ConfirmResult(
              ConfirmOutcome.ok,
              t,
              name is String && name.isNotEmpty ? name : null,
            )
          : const ConfirmResult(ConfirmOutcome.busy);
    }
    return ConfirmResult(switch (r.status) {
      403 => ConfirmOutcome.wrongCode,
      410 => ConfirmOutcome.expired,
      422 => ConfirmOutcome.malformed,
      _ => ConfirmOutcome.busy,
    });
  }

  Future<RunSendOutcome> postRun(
    String token,
    Map<String, Object?> summary,
  ) async {
    final r = await http.send(
      CompanionRequest(
        method: 'POST',
        uri: _uri(['v1', 'runs']),
        headers: _headers(token, json: true),
        body: utf8.encode(jsonEncode(summary)),
      ),
    );
    if (r.status == 401 || r.status == 403) return RunSendOutcome.unauthorized;
    // 422 with an `extra_forbidden` error: the server refuses a field it does
    // not know, so it is older than this app. Not the run's fault; the caller
    // waits and tries again later. Any other 422 (a start time in the future,
    // an unknown zone, a value out of range) is the run's own and will not
    // fix itself.
    if (r.status == 422) {
      return _isExtraForbidden(r.body)
          ? RunSendOutcome.outdated
          : RunSendOutcome.rejected;
    }
    if (!r.ok) return RunSendOutcome.busy;
    return r.json['status'] == 'duplicate'
        ? RunSendOutcome.duplicate
        : RunSendOutcome.sent;
  }

  static bool _isExtraForbidden(String body) {
    try {
      final j = jsonDecode(body);
      final detail = j is Map ? j['detail'] : null;
      return detail is List &&
          detail.any((e) => e is Map && e['type'] == 'extra_forbidden');
    } on FormatException {
      return false;
    }
  }

  /// True when the server has the feel (or already had it).
  Future<bool> patchFeel(
    String token,
    String runId,
    engine.RunFeel? feel,
  ) async {
    final r = await http.send(
      CompanionRequest(
        method: 'PATCH',
        uri: _uri(['v1', 'runs', runId, 'feel']),
        headers: _headers(token, json: true),
        body: utf8.encode(jsonEncode({'feel': feel?.name})),
      ),
    );
    return r.ok;
  }

  Future<({CompanionReply reply, CompanionMe? me})> getMe(String token) async {
    final r = await http.send(
      CompanionRequest(
        method: 'GET',
        uri: _uri(['v1', 'me']),
        headers: _headers(token),
      ),
    );
    return (reply: r, me: r.ok ? CompanionMe.fromJson(r.json) : null);
  }

  /// `GET /v1/me/next-session`: the coach's next session and latest note.
  Future<CompanionReply> getNextSession(String token) => http.send(
    CompanionRequest(
      method: 'GET',
      uri: _uri(['v1', 'me', 'next-session']),
      headers: _headers(token),
    ),
  );

  /// `GET /v1/me/briefing`: the coach's start-briefing template for the next
  /// planned session (C2b). 200 with a template, 200 `{status: suppress}`,
  /// 202 pending, 204 nothing. Called on Home load and after a run upload,
  /// never on the Start path.
  Future<CompanionReply> getBriefing(String token) => http.send(
    CompanionRequest(
      method: 'GET',
      uri: _uri(['v1', 'me', 'briefing']),
      headers: _headers(token),
    ),
  );

  /// `PUT /v1/me/settings {weather}`: the "Weather in suggestions" switch.
  /// Off also makes the server delete every area it holds for this runner.
  Future<CompanionReply> putWeather(String token, bool on) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'settings']),
      headers: _headers(token, json: true),
      body: utf8.encode(jsonEncode({'weather': on})),
    ),
  );

  /// `PUT /v1/me/settings {route_shape}`: the "Show route shape on cards"
  /// switch. Off also makes the server delete every route shape it holds.
  Future<CompanionReply> putRouteShape(String token, bool on) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'settings']),
      headers: _headers(token, json: true),
      body: utf8.encode(jsonEncode({'route_shape': on})),
    ),
  );

  /// `PUT /v1/me/settings {heart_rate}`: the "Heart rate on cards" switch.
  /// Off also makes the server delete every heart-rate series it holds.
  Future<CompanionReply> putHeartRate(String token, bool on) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'settings']),
      headers: _headers(token, json: true),
      body: utf8.encode(jsonEncode({'heart_rate': on})),
    ),
  );

  /// `PUT /v1/me/settings {place_names}`: the "Show trail names on cards"
  /// switch. Off also makes the server delete every trail name it holds.
  Future<CompanionReply> putPlaceNames(String token, bool on) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'settings']),
      headers: _headers(token, json: true),
      body: utf8.encode(jsonEncode({'place_names': on})),
    ),
  );

  /// `PUT /v1/me/consent {consent_version}`: the consent version the runner
  /// agreed to. The server sends no check-in until it is at least the version
  /// it requires; the latest value wins, so it is safe to repeat.
  Future<CompanionReply> putConsent(
    String token,
    int version, {
    bool? healthNotes,
    bool? trainingSync,
    bool? coachMemory,
    bool? coachChat,
  }) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'consent']),
      headers: _headers(token, json: true),
      body: utf8.encode(
        jsonEncode({
          'consent_version': version,
          'health_notes': ?healthNotes,
          'training_sync': ?trainingSync,
          'coach_memory': ?coachMemory,
          'coach_chat': ?coachChat,
        }),
      ),
    ),
  );

  Future<CompanionReply> deleteMe(String token) => http.send(
    CompanionRequest(
      method: 'DELETE',
      uri: _uri(['v1', 'me']),
      headers: _headers(token),
    ),
  );
}

// ------------------------------------------------------- the coach's plan

/// The next session the coach has in mind, from `GET /v1/me/next-session`.
/// Read leniently: a missing or odd field is just absent.
@immutable
class CoachSession {
  const CoachSession({
    required this.date,
    required this.type,
    this.minutes,
    this.distanceM,
    this.week,
    this.weeks,
    this.moved = false,
    this.originalDate,
    this.label,
    this.name,
    this.sessionId,
    this.derived = false,
    this.sessionRef,
    this.fingerprint,
    this.reps,
  });

  /// The server's slug for it (`norwegian_4x4`, `tempo`, or the type).
  final String? sessionId;

  /// True for the coach's own default week (the runner has no plan in the app).
  final bool derived;

  /// What the coach's start briefing for this session is keyed on (`GET /v1/me/briefing`): Start matches a cached
  /// briefing to today's coach-week session with these, from memory. Null from an older server.
  final String? sessionRef;
  final String? fingerprint;

  /// `{reps}` for a quality session the server knows the rep count of.
  final int? reps;

  /// The session's own name (Tempo, Norwegian 4x4...) when the server sends
  /// one as `name` or `session_name`. Absent today: the type is all it knows.
  final String? name;

  /// The runner's local calendar day (no time, no zone).
  final DateTime date;

  /// `easy`, `long` or `quality`.
  final String type;
  final int? minutes;
  final double? distanceM;
  final int? week;
  final int? weeks;

  /// True when the coach moved it: shown as "moved by your coach".
  final bool moved;
  final DateTime? originalDate;
  final String? label;

  /// "Quality session, 6 km" as the server wrote it, else built from the type.
  String get title {
    final n = name;
    if (n != null && n.isNotEmpty) return n;
    final l = label;
    if (l != null && l.isNotEmpty) return l;
    return switch (type) {
      'long' => 'Long run',
      'quality' => 'Quality session',
      _ => 'Easy run',
    };
  }

  static DateTime? _day(Object? v) {
    final m = v is String
        ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v)
        : null;
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static CoachSession? fromJson(Object? j) {
    if (j is! Map) return null;
    final date = _day(j['date']);
    if (date == null) return null;
    final type = j['type'];
    final dist = j['distance_m'];
    final label = j['label'];
    final nm = j['name'] ?? j['session_name'];
    final sid = j['session_id'], ref = j['session_ref'], fp = j['fingerprint'];
    int? whole(Object? v) => v is int && v > 0 ? v : null;
    return CoachSession(
      date: date,
      type: type is String ? type : 'easy',
      minutes: whole(j['minutes']),
      distanceM: dist is num && dist > 0 ? dist.toDouble() : null,
      week: whole(j['week']),
      weeks: whole(j['weeks']),
      moved: j['moved'] == true,
      originalDate: _day(j['original_date']),
      label: label is String && label.isNotEmpty ? label : null,
      name: nm is String && nm.trim().isNotEmpty ? nm.trim() : null,
      sessionId: sid is String && sid.isNotEmpty ? sid : null,
      derived: j['derived'] == true,
      sessionRef: ref is String && ref.isNotEmpty ? ref : null,
      fingerprint: fp is String && fp.isNotEmpty ? fp : null,
      reps: whole(j['reps']),
    );
  }
}

/// The coach's latest note (the headline and body of its last card).
@immutable
class CoachLine {
  const CoachLine({required this.headline, this.body, this.sentAt});
  final String headline;
  final String? body;
  final DateTime? sentAt;

  static CoachLine? fromJson(Object? j) {
    if (j is! Map) return null;
    final h = j['headline'], b = j['body'], at = j['sent_at'];
    if (h is! String || h.trim().isEmpty) return null;
    return CoachLine(
      headline: h.trim(),
      body: b is String && b.trim().isNotEmpty ? b.trim() : null,
      sentAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// The quest the runner accepted in Telegram, from `quest` in
/// `GET /v1/me/next-session`: just its offer id and when. The app matches the
/// id against its own offer; the server never sends the quest itself.
@immutable
class CoachQuest {
  const CoachQuest({required this.id, required this.acceptedAt});
  final String id;
  final DateTime? acceptedAt;

  static CoachQuest? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], state = j['state'], at = j['accepted_at'];
    if (id is! String || state != 'accepted') return null;
    return CoachQuest(
      id: id,
      acceptedAt: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// What Home shows from the coach. Either part can be absent.
@immutable
class CoachNext {
  const CoachNext({
    this.session,
    this.line,
    this.generatedAt,
    this.careWeeks = const [],
    this.quest,
    this.supportsQuests = false,
    this.supportsLoad = false,
    this.supportsGoalTarget = false,
    this.supportsGoalEased = false,
    this.supportsPbTime = false,
  });
  final CoachSession? session;
  final CoachLine? line;
  final DateTime? generatedAt;

  /// Mondays (local dates) of recent weeks the coach treated as care weeks
  /// (ill or sore). Never the reason. The streak pauses on them.
  final List<DateTime> careWeeks;

  /// The quest accepted in Telegram, if any.
  final CoachQuest? quest;

  /// The server knows quests: its reply carries the `quest` and `care_weeks`
  /// keys (an older server sends neither). Only then does a run upload carry a
  /// `quest` block, because an older server refuses any key it does not know.
  final bool supportsQuests;

  /// The server takes `load` and `load_basis` on a run: its reply says
  /// `accepts_load`. An older server refuses the whole run for either key.
  final bool supportsLoad;

  /// The server takes `goal_target_s` and `goal_target_from` on a run: its
  /// reply says `accepts_goal_target`. An older server refuses the whole run
  /// for either key.
  final bool supportsGoalTarget;

  /// The server takes `goal_eased` on a run (the runner chose ease off on a
  /// goal run, so the finish is not judged against the target): its reply
  /// says `accepts_goal_eased`. An older server refuses the whole run for the
  /// key.
  final bool supportsGoalEased;

  /// The server takes `pb_s`, a pb effort's own time, and speaks of the
  /// effort rather than the run: its reply says `accepts_pb_time`. Without
  /// it a pb is only sent for a run that is that distance.
  final bool supportsPbTime;

  bool get isEmpty => session == null && line == null;

  /// Null when the body is not a version-1 reply.
  static CoachNext? parse(Map<String, Object?> j) {
    if (j['v'] != 1) return null;
    final at = j['generated_at'];
    return CoachNext(
      session: CoachSession.fromJson(j['next_session']),
      line: CoachLine.fromJson(j['coach_line']),
      generatedAt: at is String ? DateTime.tryParse(at) : null,
      careWeeks: [
        if (j['care_weeks'] is List)
          for (final d in j['care_weeks']! as List<Object?>)
            ?CoachSession._day(d),
      ],
      quest: CoachQuest.fromJson(j['quest']),
      supportsQuests: j.containsKey('quest') || j.containsKey('care_weeks'),
      supportsLoad: j['accepts_load'] == true,
      supportsGoalTarget: j['accepts_goal_target'] == true,
      supportsGoalEased: j['accepts_goal_eased'] == true,
      supportsPbTime: j['accepts_pb_time'] == true,
    );
  }
}

// ------------------------------------------------------------ what it knows

/// One answer to a coach check-in, from `checkins` in `GET /v1/me`
/// (`{kind, local_date, value, created_at}`). Enums only on the wire; they are
/// turned into plain words here and an unknown one is dropped, so a raw name
/// never reaches the screen.
@immutable
class CheckinAnswer {
  const CheckinAnswer({
    required this.kind,
    required this.value,
    required this.day,
    required this.words,
    required this.sortKey,
  });
  final String kind;
  final String value;
  final DateTime day;
  final String words;
  final String sortKey;

  static const _when = {
    'ready': 'evening before',
    'today': 'morning of',
    'why': 'why you skipped',
    'postrun': 'after the run',
    'shape': 'Sunday',
  };

  static const _words = {
    'ready': {
      'fresh': 'Felt fresh',
      'normal': 'Felt normal',
      'flat': 'Felt flat',
      'sore': 'Sore somewhere',
      'not_tomorrow': 'Not running tomorrow',
    },
    'today': {
      'going': 'Going now',
      'later': 'Later today',
      'skip': 'Skipped the session',
    },
    'why': {
      'busy': 'Busy',
      'tired': 'Tired',
      'sore': 'Sore',
      'travelling': 'Travelling',
      'ill': 'Feeling ill',
    },
    'postrun': {
      'sleep': 'Short sleep',
      'stress': 'Stressed',
      'heat': 'The heat',
      'none': 'Nothing in particular',
    },
    'shape': {
      '3': '3 runs next week',
      '4': '4 runs next week',
      '5': '5 runs next week',
      'away': 'Away next week',
    },
  };

  /// "Tue 13 Oct, evening before".
  String get when => '${Fmt.dayDate(day)}, ${_when[kind]}';

  static CheckinAnswer? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = j['kind'], value = j['value'], date = j['local_date'];
    if (kind is! String || value is! String || date is! String) return null;
    final words = _words[kind]?[value];
    final d = CoachSession._day(date);
    if (words == null || d == null) return null;
    final at = j['created_at'];
    return CheckinAnswer(
      kind: kind,
      value: value,
      day: d,
      words: words,
      sortKey: at is String ? at : date,
    );
  }
}

/// `GET /v1/me`, read leniently (an unknown or missing field is just absent)
/// and rendered in plain words by [lines].
@immutable
class CompanionMe {
  const CompanionMe({
    this.goal,
    this.raceMonth,
    this.usualDays,
    this.niggle,
    this.feelEasy = 0,
    this.feelRight = 0,
    this.feelHard = 0,
    this.runsReceived = 0,
    this.messagesSent30d = 0,
    this.chatName,
    this.quietStartMin,
    this.quietEndMin,
    this.channel,
    this.checkins = const [],
    this.quests,
    this.serverConsent,
    this.coachAvailable,
    this.coachLink,
  });

  /// `profile.coach_available`: the server has a coach for this runner (the coach
  /// is on and open to them). Null from an older server, which means "do not
  /// offer": nobody should agree to a coach that may not be there.
  final bool? coachAvailable;

  /// `profile.coach_link`: the https link that opens the coach's Telegram chat.
  final String? coachLink;

  /// The consent version the server holds for this runner (`profile.checkin_consent`),
  /// null from an older server. The memory sheet is offered only at 3 or above.
  final int? serverConsent;

  /// How many quests the server keeps, by state (`taken`, `waiting` = offered,
  /// `ended` = done, expired or passed on), from `quests` in `GET /v1/me`.
  /// Null when the server does not send the list (an older server).
  final ({int taken, int waiting, int ended})? quests;

  /// The check-in answers the server holds (kept 14 days), newest first.
  final List<CheckinAnswer> checkins;

  /// Memory is enums only (no free text): `goal_type`, `race_month`
  /// ("YYYY-MM" or "none"), `usual_days` ("weekdays", "weekends", "both"),
  /// `niggle_area`.
  final String? goal;
  final String? raceMonth;
  final String? usualDays;
  final String? niggle;
  final int feelEasy;
  final int feelRight;
  final int feelHard;
  final int runsReceived;
  final int messagesSent30d;

  /// The connected chat's display name (never the chat id).
  final String? chatName;

  /// Quiet hours as minutes after local midnight, both or neither.
  final int? quietStartMin;
  final int? quietEndMin;
  final String? channel;

  int get feelTotal => feelEasy + feelRight + feelHard;

  static CompanionMe fromJson(Map<String, Object?> j) {
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    Map<String, Object?> m(Object? v) =>
        v is Map<String, Object?> ? v : const {};
    final memory = m(j['memory']);
    final profile = m(j['profile']);
    final runs = j['runs_received'];
    var easy = 0, right = 0, hard = 0;
    if (runs is List) {
      for (final r in runs) {
        switch (r is Map ? r['feel'] : null) {
          case 'easy':
            easy++;
          case 'right':
            right++;
          case 'hard':
            hard++;
        }
      }
    }
    final sent = j['messages_sent_30d'];
    final answers = j['checkins'];
    final checkins = <CheckinAnswer>[
      if (answers is List)
        for (final a in answers) ?CheckinAnswer.fromJson(a),
    ]..sort((a, b) => b.sortKey.compareTo(a.sortKey));
    int? mins(Object? v) => v is int && v >= 0 && v < 1440 ? v : null;
    final qs = j['quests'];
    ({int taken, int waiting, int ended})? quests;
    if (qs is List) {
      var taken = 0, waiting = 0, ended = 0;
      for (final q in qs) {
        switch (q is Map ? q['state'] : null) {
          case 'accepted':
            taken++;
          case 'offered':
            waiting++;
          case 'done' || 'expired' || 'skipped':
            ended++;
        }
      }
      quests = (taken: taken, waiting: waiting, ended: ended);
    }
    return CompanionMe(
      quests: quests,
      goal: s(memory['goal_type']),
      raceMonth: s(memory['race_month']),
      usualDays: s(memory['usual_days']),
      niggle: s(memory['niggle_area']),
      feelEasy: easy,
      feelRight: right,
      feelHard: hard,
      runsReceived: runs is List ? runs.length : 0,
      messagesSent30d: sent is int && sent > 0 ? sent : 0,
      quietStartMin: mins(profile['quiet_start_min']),
      quietEndMin: mins(profile['quiet_end_min']),
      channel: s(profile['channel']),
      serverConsent: profile['checkin_consent'] is int
          ? profile['checkin_consent'] as int
          : null,
      coachAvailable: profile['coach_available'] is bool
          ? profile['coach_available'] as bool
          : null,
      coachLink: s(profile['coach_link']),
      checkins: checkins,
      chatName:
          s(j['chat_name']) ??
          s(profile['chat_name']) ??
          s(profile['chat_ref_hint']),
    );
  }

  static String _clock(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  /// "2026-11" as "Nov 2026"; anything else as sent.
  static String _month(String v) {
    final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(v);
    final month = m == null ? null : int.parse(m[2]!);
    if (month == null || month < 1 || month > 12) return v;
    return Fmt.monthShortYear(DateTime(int.parse(m![1]!), month));
  }

  static String _words(String v) => switch (v) {
    'weekdays' => 'Weekdays',
    'weekends' => 'Weekends',
    'both' => 'Weekdays and weekends',
    _ => v.replaceAll('_', ' '),
  };

  /// The check-in answers in plain words: (day and moment, answer).
  List<(String, String)> get checkinLines => [
    for (final c in checkins) (c.when, c.words),
  ];

  /// Plain words, one fact per entry: (what, answer).
  List<(String, String)> get lines => [
    ('Connected to', chatName ?? 'Telegram'),
    ('Runs it has', runsReceived == 0 ? 'None yet' : '$runsReceived'),
    ('Your goal', goal == null ? 'Not told yet' : _words(goal!)),
    (
      'Your race',
      switch (raceMonth) {
        null => 'Not told yet',
        'none' => 'No race planned',
        final m => _month(m),
      },
    ),
    (
      'Days you usually run',
      usualDays == null ? 'Not told yet' : _words(usualDays!),
    ),
    ('Niggles', niggle == null ? 'None told' : _words(niggle!)),
    (
      'How runs felt',
      feelTotal == 0
          ? 'No taps yet'
          : '$feelEasy easy, $feelRight right, $feelHard hard',
    ),
    (
      'Quiet hours',
      quietStartMin == null || quietEndMin == null
          ? 'None set'
          : '${_clock(quietStartMin!)} to ${_clock(quietEndMin!)}',
    ),
    (
      'Notes sent, last 30 days',
      messagesSent30d == 0 ? 'None' : '$messagesSent30d',
    ),
    if (quests case final q?) ('Quests', _questsWords(q)),
  ];

  /// "1 running, 3 offered, 2 ended". The numbers only: no quest, run or
  /// trail is named here, and each is kept 90 days after it ends.
  static String _questsWords(({int taken, int waiting, int ended}) q) {
    final parts = [
      if (q.taken > 0) '${q.taken} running',
      if (q.waiting > 0) '${q.waiting} offered',
      if (q.ended > 0) '${q.ended} ended',
    ];
    return parts.isEmpty
        ? 'None'
        : '${parts.join(', ')}. Kept 90 days after they end';
  }
}

// --------------------------------------------------------------- controller

enum CompanionPhase {
  /// Not turned on (never asked, or "Not now", or turned off).
  off,

  /// The link is open; waiting for the runner to tap Start in Telegram.
  waiting,

  /// The bot has sent a 6-digit code; waiting for the runner to type it.
  awaitingCode,

  /// Waited long enough without a message, or the server said no. Retry UI.
  failed,

  /// Enrolled: a token is stored.
  on,
}

class CompanionController extends ChangeNotifier {
  CompanionController({
    required this.store,
    required this.transfer,
    CompanionClient? client,
    this.onEnrolled,
    this.pollEvery = const Duration(seconds: 3),
    this.waitFor = const Duration(minutes: 3),
    DateTime Function()? now,
  }) : client = client ?? CompanionClient(),
       _now = now ?? DateTime.now;

  static const String tokenName = 'companion_token';
  static const String consentName = 'companion_consent_version';
  static const String askedName = 'companion_asked';
  static const String weatherName = 'companion_weather';

  /// The last good `next-session` reply, kept so Home has something to show
  /// between fetches. Holds no check-in answer, only the plan and the line.
  static const String nextName = 'companion_next_session';

  /// The last briefing answer (template for one session, or the suppress
  /// marker), kept so Start can read it without waiting for the network.
  static const String briefingName = 'companion_briefing';

  /// Set while the server has not yet confirmed "forget my areas". Retried
  /// on open and before the next send, so a switch-off made offline lands.
  static const String weatherForgetName = 'companion_weather_forget';

  /// "Show trail names on cards" is OFF unless this holds '1'.
  static const String placeNamesName = 'companion_place_names';

  /// Set while the server has not yet confirmed "forget my trail names".
  static const String placeNamesForgetName = 'companion_place_names_forget';

  /// "Heart rate on cards" is OFF unless this holds '1'. Heart rate is health
  /// data: nothing leaves the phone unless the runner turned this on.
  static const String heartRateName = 'companion_heart_rate';

  /// Set while the server has not yet confirmed "forget my heart-rate series".
  static const String heartRateForgetName = 'companion_heart_rate_forget';

  /// "Show route shape on cards" is ON unless this holds '1'.
  static const String routeOffName = 'companion_route_off';

  /// Set while the server has not yet confirmed "forget my route shapes".
  static const String routeForgetName = 'companion_route_forget';

  /// The secret privacy zones (see `PrivacyZone` in run_engine): circles
  /// around places the runner starts from, clipped from every route. They live
  /// only here, in secure storage excluded from backups. They are never sent,
  /// never put in a payload or a log, and they survive a wipe (a new server
  /// record must not get a different zone for the same door).
  static const String zonesName = 'companion_privacy_zones';

  final SecretStore store;
  final TransferGateway transfer;
  final CompanionClient client;

  /// Called once the token is stored: wires the after-run send on.
  final Future<void> Function(DateTime now)? onEnrolled;
  final Duration pollEvery;
  final Duration waitFor;
  final DateTime Function() _now;

  CompanionPhase _phase = CompanionPhase.off;
  CompanionPhase get phase => _phase;
  bool get enrolled => _phase == CompanionPhase.on;

  bool _asked = false;
  int _consent = 0;
  bool _weather = false;
  bool _placeNames = false;
  bool _heartRate = false;
  CoachNext? _coachNext;
  bool _nextBusy = false;
  DateTime? _nextAt;
  CachedBriefing? _briefing;
  bool _briefingBusy = false;
  DateTime? _briefingAt;
  bool _routeShape = true;

  /// "Weather in suggestions" (off until the runner turns it on). The run
  /// summary carries a rounded area only while this is true.
  bool get weatherOn => _weather && enrolled;

  /// "Show trail names on cards" (off until the runner turns it on). The
  /// trail block carries a name only while this is true.
  bool get placeNamesOn => _placeNames && enrolled;

  /// "Heart rate on cards" (off until the runner turns it on). The trail
  /// block carries a heart-rate series only while this is true.
  bool get heartRateOn => _heartRate && enrolled;

  /// "Show route shape on cards" (on until the runner turns it off). The run
  /// summary carries the route SHAPE only while this is true: an outline with
  /// no place, scale or direction in it.
  bool get routeShapeOn => _routeShape && enrolled;

  /// True when the runner agreed to the check-ins copy. A runner who turned on
  /// before [kCompanionBaseConsent] went up has to agree again.
  bool get consentCurrent => _consent >= kCompanionBaseConsent;

  /// Coach memory: the runner agreed to the memory sheet (version 4).
  bool get memoryOn => enrolled && _consent >= kCompanionConsentVersion;

  /// The memory sheet is on offer: linked, on the check-ins copy, not yet on
  /// version 4, and the runner has not said "Not now". No silent upgrade.
  bool get memoryOffered =>
      enrolled &&
      consentCurrent &&
      coachAvailable &&
      !memoryOn &&
      !_memoryDismissed &&
      (_serverConsent ?? 0) >= kCompanionCoachConsent;

  /// The server says it has a coach for this runner. False until it says so.
  bool get coachAvailable => _coachAvailable == true;
  bool? _coachAvailable;

  /// The Telegram link that opens the coach, when the server gave one.
  String? get coachLink => _coachLink;
  String? _coachLink;

  /// The coach chat sheet is on offer: linked, on the check-ins copy, the server
  /// holds this runner below the coach version (3), and they have not said "Not
  /// now". It comes before the memory sheet, which needs the server at 3.
  bool get coachOffered =>
      enrolled &&
      consentCurrent &&
      coachAvailable &&
      !_coachDismissed &&
      _serverConsent != null &&
      _serverConsent! < kCompanionCoachConsent &&
      _consent < kCompanionCoachConsent;

  /// The runner agreed to the coach chat (here, or earlier by the operator).
  bool get coachOn =>
      enrolled &&
      (_consent >= kCompanionCoachConsent ||
          (_serverConsent ?? 0) >= kCompanionCoachConsent);

  /// Said no to the coach chat (Not now, or turned off): can be offered again.
  bool get coachDeclined =>
      enrolled && consentCurrent && !coachOn && _coachDismissed;

  bool _coachDismissed = false;
  static const String coachDismissedName = 'companion_coach_not_now';

  /// "Agree" on the coach sheet: version 3. Server first: the phone changes only
  /// once the server took it (it records when). True when it did.
  Future<bool> acceptCoach() async {
    final t = await token();
    if (t == null) return false;
    try {
      final r = await client.putConsent(t, kCompanionCoachConsent);
      final j = r.ok ? r.json : null;
      if (!r.ok || (j != null && j['status'] == 'ignored')) {
        problem = 'Could not turn the coach on. Try again.';
        notifyListeners();
        return false;
      }
    } on CompanionNetworkError {
      problem = 'No network. Try again.';
      notifyListeners();
      return false;
    }
    problem = null;
    _consent = kCompanionCoachConsent;
    _serverConsent = kCompanionCoachConsent;
    _consentSent = _consent;
    _coachDismissed = false;
    try {
      await store.write(consentName, '$_consent');
      await store.delete(coachDismissedName);
    } catch (e) {
      companionLog('could not save the coach choice (${e.runtimeType})');
    }
    notifyListeners();
    return true;
  }

  /// Settings: "Turn off coach chat". The server deletes the chats and any
  /// memory and drops the runner to check-ins; the phone follows only once the
  /// server said yes. True when it did.
  Future<bool> turnOffCoach() async {
    final t = await token();
    if (t == null) return false;
    try {
      final r = await client.putConsent(
        t,
        kCompanionBaseConsent,
        coachChat: false,
      );
      if (!r.ok) {
        problem = 'Could not turn the coach off. Try again.';
        notifyListeners();
        return false;
      }
    } on CompanionNetworkError {
      problem = 'No network. The coach is still on. Try again.';
      notifyListeners();
      return false;
    }
    problem = null;
    _consent = kCompanionBaseConsent;
    _serverConsent = kCompanionBaseConsent;
    _consentSent = _consent;
    _healthNotes = false;
    _trainingSync = true;
    _memoryDismissed = false;
    _coachDismissed = true;
    try {
      await store.write(consentName, '$_consent');
      await store.delete(healthNotesName);
      await store.delete(trainingSyncName);
      await store.delete(memoryDismissedName);
      await store.write(coachDismissedName, '1');
    } catch (e) {
      companionLog('could not save the coach choice (${e.runtimeType})');
    }
    notifyListeners();
    return true;
  }

  /// Settings: "Review" after Not now or Turn off shows the coach sheet again.
  Future<void> reviewCoach() async {
    _coachDismissed = false;
    try {
      await store.delete(coachDismissedName);
    } catch (e) {
      companionLog('could not save the coach choice (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// "Not now" on the coach sheet: nothing changes, nothing is sent.
  Future<void> dismissCoach() async {
    _coachDismissed = true;
    try {
      await store.write(coachDismissedName, '1');
    } catch (e) {
      companionLog('could not save the coach choice (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// What the server last said it holds (from `GET /v1/me`); null until read.
  /// The sheet is never offered to a runner the server holds below the coach
  /// version: agreeing would otherwise grant more than they agreed to.
  int? _serverConsent;

  /// "Keep health notes too" as agreed (off unless ticked).
  bool get healthNotesOn => _healthNotes && memoryOn;

  /// Training numbers sync as agreed (on unless switched off).
  bool get trainingSyncOn => _trainingSync && memoryOn;

  bool _healthNotes = false;
  bool _trainingSync = true;
  bool _memoryDismissed = false;

  static const String healthNotesName = 'companion_memory_health';
  static const String trainingSyncName = 'companion_memory_sync_off';
  static const String memoryDismissedName = 'companion_memory_not_now';

  /// "Agree" on the memory sheet: version 4 with the two choices, kept on the
  /// phone and sent with the version.
  Future<void> acceptMemory({
    bool healthNotes = false,
    bool trainingSync = false,
  }) async {
    final before = (_consent, _healthNotes, _trainingSync, _memoryDismissed);
    _consentIgnored = false;
    _consent = kCompanionConsentVersion;
    _healthNotes = healthNotes;
    _trainingSync = trainingSync;
    _memoryDismissed = false;
    _consentSent = 0;
    try {
      await store.write(consentName, '$kCompanionConsentVersion');
      if (healthNotes) {
        await store.write(healthNotesName, '1');
      } else {
        await store.delete(healthNotesName);
      }
      if (trainingSync) {
        await store.delete(trainingSyncName);
      } else {
        await store.write(trainingSyncName, '1');
      }
      await store.delete(memoryDismissedName);
    } catch (e) {
      companionLog('could not save memory consent (${e.runtimeType})');
    }
    notifyListeners();
    await syncConsent();
    if (_consentIgnored && _consent == kCompanionConsentVersion) {
      // The server answered {"status":"ignored"}: it holds this runner below
      // the coach version and did not take version 4. Memory is not on.
      _consent = before.$1;
      _healthNotes = before.$2;
      _trainingSync = before.$3;
      _memoryDismissed = before.$4;
      _consentSent = _consent;
      problem = 'The companion did not take that. Memory is still off.';
      try {
        await store.write(consentName, '$_consent');
        if (_healthNotes) {
          await store.write(healthNotesName, '1');
        } else {
          await store.delete(healthNotesName);
        }
        if (_trainingSync) {
          await store.delete(trainingSyncName);
        } else {
          await store.write(trainingSyncName, '1');
        }
      } catch (e) {
        companionLog('could not save memory consent (${e.runtimeType})');
      }
      notifyListeners();
    }
  }

  bool _consentIgnored = false;

  /// Settings: the health notes tick and the training numbers switch. Server
  /// first, like Turn off memory: the phone changes only once the server says
  /// yes (it deletes the health notes on a health off), otherwise a problem
  /// shows and nothing moves. True when it landed.
  Future<bool> setMemoryChoices({
    required bool healthNotes,
    required bool trainingSync,
  }) async {
    final t = await token();
    if (t == null || !memoryOn) return false;
    try {
      final r = await client.putConsent(
        t,
        kCompanionConsentVersion,
        healthNotes: healthNotes,
        trainingSync: trainingSync,
      );
      final j = r.ok ? r.json : null;
      if (!r.ok || (j != null && j['status'] == 'ignored')) {
        problem = 'Could not save that. Nothing changed. Try again.';
        notifyListeners();
        return false;
      }
    } on CompanionNetworkError {
      problem = 'No network. Nothing changed. Try again.';
      notifyListeners();
      return false;
    }
    problem = null;
    _healthNotes = healthNotes;
    _trainingSync = trainingSync;
    try {
      if (healthNotes) {
        await store.write(healthNotesName, '1');
      } else {
        await store.delete(healthNotesName);
      }
      if (trainingSync) {
        await store.delete(trainingSyncName);
      } else {
        await store.write(trainingSyncName, '1');
      }
    } catch (e) {
      companionLog('could not save the memory choices (${e.runtimeType})');
    }
    notifyListeners();
    return true;
  }

  /// Settings: "Turn off memory". The server deletes every coach note, drops
  /// the runner to the check-ins and coach version and keeps everything else.
  /// Only changes the phone once the server said yes; false when it could not.
  Future<bool> turnOffMemory() async {
    final t = await token();
    if (t == null) return false;
    try {
      final r = await client.putConsent(
        t,
        kCompanionCoachConsent,
        coachMemory: false,
      );
      if (!r.ok) {
        problem = 'Could not turn memory off. Try again.';
        notifyListeners();
        return false;
      }
    } on CompanionNetworkError {
      problem = 'No network. Memory is still on. Try again.';
      notifyListeners();
      return false;
    }
    problem = null;
    _consent = kCompanionCoachConsent;
    _consentSent = _consent;
    _healthNotes = false;
    _trainingSync = true;
    _memoryDismissed = true;
    try {
      await store.write(consentName, '$_consent');
      await store.delete(healthNotesName);
      await store.delete(trainingSyncName);
      await store.write(memoryDismissedName, '1');
    } catch (e) {
      companionLog('could not save the memory choice (${e.runtimeType})');
    }
    notifyListeners();
    return true;
  }

  /// Settings: "Review" after Not now or Turn off memory shows the sheet again.
  Future<void> reviewMemory() async {
    _memoryDismissed = false;
    try {
      await store.delete(memoryDismissedName);
    } catch (e) {
      companionLog('could not save the memory choice (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// Whether memory was said no to (Not now, or turned off) and can be offered again.
  bool get memoryDeclined =>
      enrolled && consentCurrent && !memoryOn && _memoryDismissed;

  /// "Not now" on the memory sheet: nothing changes, nothing is sent.
  Future<void> dismissMemory() async {
    _memoryDismissed = true;
    try {
      await store.write(memoryDismissedName, '1');
    } catch (e) {
      companionLog('could not save the memory choice (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// Turned on, but under older consent copy: ask again before the coach's
  /// check-in data is shown or asked for.
  bool get needsReconsent => enrolled && !consentCurrent;

  /// The runner agrees to the current copy ("Agree" on the new check-ins).
  Future<void> acceptConsent() async {
    _consent = kCompanionBaseConsent;
    try {
      await store.write(consentName, '$kCompanionBaseConsent');
    } catch (e) {
      companionLog('could not save consent (${e.runtimeType})');
    }
    notifyListeners();
    await syncConsent();
  }

  /// The consent version the server last accepted from this app session. A new
  /// session, a wipe or a different version sends it again.
  int _consentSent = 0;

  /// Tells the server which consent version the runner agreed to, so it can
  /// hold check-ins back until it knows. Quiet: a failure is retried on the
  /// next call (the next run upload, Agree tap or app start); nothing shows.
  /// Does nothing before the runner has agreed or while not linked.
  Future<void> syncConsent() async {
    final v = _consent;
    if (v <= 0 || !enrolled || _consentSent == v) return;
    final t = await token();
    if (t == null) return;
    try {
      final r = await client.putConsent(
        t,
        v,
        healthNotes: v >= kCompanionConsentVersion ? _healthNotes : null,
        trainingSync: v >= kCompanionConsentVersion ? _trainingSync : null,
      );
      if (r.status == 401 || r.status == 403) {
        await _wipe();
      } else if (r.ok) {
        final j = r.json;
        if (j['status'] == 'ignored') {
          _consentIgnored = true; // the server did not take it
        } else {
          _consentSent = v;
        }
      }
      // 404/422: a server older than this app; the next try is after its update.
    } on CompanionNetworkError {
      // offline: tried again with the next run upload
    } catch (e) {
      companionLog('consent sync failed (${e.runtimeType})', secrets: [t]);
    }
  }

  /// What Home shows from the coach; null when there is nothing to show
  /// (companion off, not linked, not agreed, offline with no cache, error).
  CoachNext? get coachNext =>
      enrolled && consentCurrent && !(_coachNext?.isEmpty ?? true)
      ? _coachNext
      : null;

  /// Mondays the coach treated as care weeks (ill or sore), read from the
  /// last next-session reply. Empty when the companion is off or not agreed.
  /// Only the dates: the server never says why.
  List<DateTime> get careWeeks =>
      enrolled && consentCurrent ? _coachNext?.careWeeks ?? const [] : const [];

  /// The server's last next-session reply says it knows quests, so a run may
  /// carry a `quest` block. False until a reply says so (and for an older
  /// server): the block is optional, so waiting costs only a later offer.
  bool get questsSupported =>
      enrolled && consentCurrent && (_coachNext?.supportsQuests ?? false);

  /// The server's last next-session reply says it takes `load` and
  /// `load_basis`. False until a reply says so.
  bool get loadSupported =>
      enrolled && consentCurrent && (_coachNext?.supportsLoad ?? false);

  /// The server's last next-session reply says it takes a goal run's target
  /// (`accepts_goal_target`). False until a reply says so.
  bool get goalTargetSupported =>
      enrolled && consentCurrent && (_coachNext?.supportsGoalTarget ?? false);

  /// The server's last next-session reply says it takes `goal_eased`
  /// (`accepts_goal_eased`). False until a reply says so.
  bool get goalEasedSupported =>
      goalTargetSupported && (_coachNext?.supportsGoalEased ?? false);

  /// The server's last next-session reply says it takes `pb_s`
  /// (`accepts_pb_time`). False until a reply says so.
  bool get pbTimeSupported =>
      enrolled && consentCurrent && (_coachNext?.supportsPbTime ?? false);

  /// The quest accepted in Telegram, if the last reply said so.
  CoachQuest? get coachQuest =>
      enrolled && consentCurrent ? _coachNext?.quest : null;

  /// The runner has answered the setup step ("Turn on" or "Not now"), so
  /// onboarding does not ask again.
  bool get asked => _asked;

  /// A plain reason when [phase] is [CompanionPhase.failed] or a call failed.
  String? problem;

  bool _loaded = false;
  int _attempt = 0;

  Future<String?> token() async {
    try {
      final t = await store.read(tokenName);
      return t == null || t.isEmpty ? null : t;
    } catch (e) {
      companionLog('could not read the token (${e.runtimeType})');
      return null;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _asked = await store.read(askedName) == '1';
    } catch (e) {
      companionLog('could not read setup state (${e.runtimeType})');
    }
    if (await token() != null) {
      _phase = CompanionPhase.on;
      _asked = true;
      try {
        _consent = int.tryParse(await store.read(consentName) ?? '') ?? 0;
        _healthNotes = await store.read(healthNotesName) == '1';
        _trainingSync = await store.read(trainingSyncName) != '1';
        _memoryDismissed = await store.read(memoryDismissedName) == '1';
        _coachDismissed = await store.read(coachDismissedName) == '1';
        final cached = await store.read(nextName);
        if (cached != null && cached.isNotEmpty) {
          final j = jsonDecode(cached);
          if (j is Map<String, Object?>) _coachNext = CoachNext.parse(j);
        }
        _briefing = CachedBriefing.decode(await store.read(briefingName));
      } catch (e) {
        companionLog('could not read the coach cache (${e.runtimeType})');
      }
      try {
        _weather = await store.read(weatherName) == '1';
      } catch (e) {
        companionLog('could not read the weather switch (${e.runtimeType})');
      }
      try {
        _placeNames = await store.read(placeNamesName) == '1';
      } catch (e) {
        companionLog(
          'could not read the trail names switch (${e.runtimeType})',
        );
      }
      try {
        _heartRate = await store.read(heartRateName) == '1';
      } catch (e) {
        companionLog('could not read the heart rate switch (${e.runtimeType})');
      }
    }
    // The route choice outlives a wipe, so it is read with or without a token.
    try {
      _routeShape = await store.read(routeOffName) != '1';
    } catch (e) {
      companionLog('could not read the route switch (${e.runtimeType})');
    }
    notifyListeners();
    if (_phase == CompanionPhase.on) {
      await syncWeather();
      await syncPlaceNames();
      await syncHeartRate();
      await syncRouteShape();
      await syncConsent();
    }
  }

  /// The privacy zones to clip [run]'s route with: the stored ones, plus a new
  /// secret one when the run starts outside all of them (saved here at once).
  /// Null when the zones cannot be read or saved: the caller then sends no
  /// route at all, because a fresh zone invented for the same door every run
  /// would leak more than none.
  Future<List<engine.PrivacyZone>?> privacyZonesFor(engine.RunFile run) async {
    var zones = <engine.PrivacyZone>[];
    try {
      final raw = await store.read(zonesName);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is List) {
          zones = [for (final z in j) ?engine.PrivacyZone.fromJson(z)];
        }
      }
    } catch (e) {
      companionLog('could not read the privacy zones (${e.runtimeType})');
      return null;
    }
    // A zone for where the run starts and where it finishes (home, work, the
    // gym), made once and reused for every later run.
    final next = engine.ensureZonesForRun(zones, run.samples);
    if (!identical(next, zones)) {
      try {
        await store.write(
          zonesName,
          jsonEncode([for (final z in next) z.toJson()]),
        );
      } catch (e) {
        companionLog('could not save the privacy zones (${e.runtimeType})');
        return null;
      }
    }
    return next;
  }

  /// "Show route shape on cards". Off: the phone stops sending a shape at
  /// once, then the server is told to forget the shapes it holds (retried
  /// until it has). On: the server is told first and only then does the phone
  /// start sending a shape again. True when the switch now reads as asked.
  Future<bool> setRouteShape(bool on) async {
    final t = await token();
    if (t == null) return false;
    if (on == _routeShape) return true;
    if (on) {
      try {
        final r = await client.putRouteShape(t, true);
        if (r.status == 401 || r.status == 403) {
          await _wipe();
          return false;
        }
        if (!r.ok) {
          problem =
              'The companion is busy. The route shape is still off. Try again.';
          notifyListeners();
          return false;
        }
      } on CompanionNetworkError {
        problem = 'No network. The route shape is still off. Try again.';
        notifyListeners();
        return false;
      }
      problem = null;
      await _saveRouteShape(true);
      return true;
    }
    await _saveRouteShape(false);
    await syncRouteShape();
    return true;
  }

  /// Tells the server to forget the route shapes if a switch-off has not
  /// landed yet.
  Future<void> syncRouteShape() async {
    String? pending;
    try {
      pending = await store.read(routeForgetName);
    } catch (_) {
      return;
    }
    if (pending != '1') return;
    final t = await token();
    if (t == null) return;
    try {
      final r = await client.putRouteShape(t, false);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.ok) {
        await store.delete(routeForgetName);
        problem = null;
      } else {
        problem = _routePending;
      }
    } on CompanionNetworkError {
      problem = _routePending;
    } catch (e) {
      companionLog('route switch sync failed (${e.runtimeType})');
    }
    notifyListeners();
  }

  static const String _routePending =
      'The route shape is off on your phone. The server will be told when '
      'you are back online.';

  Future<void> _saveRouteShape(bool on) async {
    _routeShape = on;
    try {
      if (on) {
        await store.delete(routeOffName);
        await store.delete(routeForgetName);
      } else {
        await store.write(routeOffName, '1');
        await store.write(routeForgetName, '1');
      }
    } catch (e) {
      companionLog('could not save the route switch (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// "Weather in suggestions". On: the server is told first and only then
  /// does the phone start sending an area. Off: the phone stops at once, then
  /// the server is told to forget the areas it holds (retried until it has).
  /// True when the switch now reads as asked.
  Future<bool> setWeather(bool on) async {
    final t = await token();
    if (t == null) return false;
    if (on) {
      try {
        final r = await client.putWeather(t, true);
        if (r.status == 401 || r.status == 403) {
          await _wipe();
          return false;
        }
        if (!r.ok) {
          problem = 'The companion is busy. Weather is still off. Try again.';
          notifyListeners();
          return false;
        }
      } on CompanionNetworkError {
        problem = 'No network. Weather is still off. Try again.';
        notifyListeners();
        return false;
      }
      problem = null;
      await _saveWeather(true, forgetPending: false);
      return true;
    }
    await _saveWeather(false, forgetPending: true);
    await syncWeather();
    return true;
  }

  /// Tells the server to forget the areas if a switch-off has not landed yet.
  Future<void> syncWeather() async {
    String? pending;
    try {
      pending = await store.read(weatherForgetName);
    } catch (_) {
      return;
    }
    if (pending != '1') return;
    final t = await token();
    if (t == null) return;
    try {
      final r = await client.putWeather(t, false);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.ok) {
        await store.delete(weatherForgetName);
        problem = null;
      } else {
        problem = _weatherPending;
      }
    } on CompanionNetworkError {
      problem = _weatherPending;
    } catch (e) {
      companionLog('weather sync failed (${e.runtimeType})');
    }
    notifyListeners();
  }

  static const String _weatherPending =
      'Weather is off on your phone. The server will be told when you are '
      'back online.';

  Future<void> _saveWeather(bool on, {required bool forgetPending}) async {
    _weather = on;
    try {
      if (on) {
        await store.write(weatherName, '1');
        await store.delete(weatherForgetName);
      } else {
        await store.delete(weatherName);
        if (forgetPending) await store.write(weatherForgetName, '1');
      }
    } catch (e) {
      companionLog('could not save the weather switch (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// "Show trail names on cards". Same shape as [setWeather]: on tells the
  /// server first, off stops the phone at once and then tells the server to
  /// forget the names it holds (retried until it has).
  Future<bool> setPlaceNames(bool on) async {
    if (!on) {
      // Off stops the phone first, with or without a token.
      await _savePlaceNames(false, forgetPending: true);
      await syncPlaceNames();
      return true;
    }
    final t = await token();
    if (t == null) return false;
    {
      try {
        final r = await client.putPlaceNames(t, true);
        if (r.status == 401 || r.status == 403) {
          await _wipe();
          return false;
        }
        if (!r.ok) {
          problem =
              'The companion is busy. Trail names are still off. Try again.';
          notifyListeners();
          return false;
        }
      } on CompanionNetworkError {
        problem = 'No network. Trail names are still off. Try again.';
        notifyListeners();
        return false;
      }
      problem = null;
      await _savePlaceNames(true, forgetPending: false);
      return true;
    }
  }

  /// Tells the server to forget the trail names if a switch-off has not
  /// landed yet.
  Future<void> syncPlaceNames() async {
    String? pending;
    try {
      pending = await store.read(placeNamesForgetName);
    } catch (_) {
      return;
    }
    if (pending != '1') return;
    final t = await token();
    if (t == null) return;
    try {
      final r = await client.putPlaceNames(t, false);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.ok) {
        await store.delete(placeNamesForgetName);
        problem = null;
      } else {
        problem = _placeNamesPending;
      }
    } on CompanionNetworkError {
      problem = _placeNamesPending;
    } catch (e) {
      companionLog('trail names sync failed (${e.runtimeType})');
    }
    notifyListeners();
  }

  static const String _placeNamesPending =
      'Trail names are off on your phone. The server will be told when you '
      'are back online.';

  Future<void> _savePlaceNames(bool on, {required bool forgetPending}) async {
    _placeNames = on;
    try {
      if (on) {
        await store.write(placeNamesName, '1');
        await store.delete(placeNamesForgetName);
      } else {
        await store.delete(placeNamesName);
        if (forgetPending) await store.write(placeNamesForgetName, '1');
      }
    } catch (e) {
      companionLog('could not save the trail names switch (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// "Heart rate on cards". Same shape as [setPlaceNames]: on tells the
  /// server first, off stops the phone at once and then tells the server to
  /// forget the series it holds (retried until it has).
  Future<bool> setHeartRate(bool on) async {
    if (!on) {
      // Off stops the phone first, with or without a token.
      await _saveHeartRate(false, forgetPending: true);
      await syncHeartRate();
      return true;
    }
    final t = await token();
    if (t == null) return false;
    {
      try {
        final r = await client.putHeartRate(t, true);
        if (r.status == 401 || r.status == 403) {
          await _wipe();
          return false;
        }
        if (!r.ok) {
          problem =
              'The companion is busy. Heart rate is still off. Try again.';
          notifyListeners();
          return false;
        }
      } on CompanionNetworkError {
        problem = 'No network. Heart rate is still off. Try again.';
        notifyListeners();
        return false;
      }
      problem = null;
      await _saveHeartRate(true, forgetPending: false);
      return true;
    }
  }

  /// Tells the server to forget the heart-rate series if a switch-off has not
  /// landed yet.
  Future<void> syncHeartRate() async {
    String? pending;
    try {
      pending = await store.read(heartRateForgetName);
    } catch (_) {
      return;
    }
    if (pending != '1') return;
    final t = await token();
    if (t == null) return;
    try {
      final r = await client.putHeartRate(t, false);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.ok) {
        await store.delete(heartRateForgetName);
        problem = null;
      } else {
        problem = _heartRatePending;
      }
    } on CompanionNetworkError {
      problem = _heartRatePending;
    } catch (e) {
      companionLog('heart rate sync failed (${e.runtimeType})');
    }
    notifyListeners();
  }

  static const String _heartRatePending =
      'Heart rate is off on your phone. The server will be told when you '
      'are back online.';

  Future<void> _saveHeartRate(bool on, {required bool forgetPending}) async {
    _heartRate = on;
    try {
      if (on) {
        await store.write(heartRateName, '1');
        await store.delete(heartRateForgetName);
      } else {
        await store.delete(heartRateName);
        if (forgetPending) await store.write(heartRateForgetName, '1');
      }
    } catch (e) {
      companionLog('could not save the heart rate switch (${e.runtimeType})');
    }
    notifyListeners();
  }

  Future<void> _markAsked() async {
    _asked = true;
    try {
      await store.write(askedName, '1');
    } catch (e) {
      companionLog('could not save setup state (${e.runtimeType})');
    }
  }

  /// "Not now" in setup.
  Future<void> notNow() async {
    await _markAsked();
    notifyListeners();
  }

  /// "Turn on": ask for a nonce and link, open the link, and poll until the
  /// runner's message arrives. Ends in [CompanionPhase.on] or
  /// [CompanionPhase.failed] (retry UI); [cancel] stops it.
  Future<void> turnOn() async {
    if (_phase == CompanionPhase.waiting ||
        _phase == CompanionPhase.awaitingCode ||
        _phase == CompanionPhase.on) {
      return;
    }
    final attempt = ++_attempt;
    problem = null;
    _phase = CompanionPhase.waiting;
    notifyListeners();
    await _markAsked();
    _consent = kCompanionBaseConsent;
    try {
      await store.write(consentName, '$kCompanionBaseConsent');
    } catch (e) {
      companionLog('could not save consent (${e.runtimeType})');
    }
    final EnrolStart? start;
    try {
      start = await client.enrolStart();
    } on CompanionNetworkError {
      return _fail(attempt, 'No network. Try again.');
    }
    if (attempt != _attempt) return;
    if (start == null) {
      return _fail(attempt, 'The companion did not answer. Try again.');
    }
    final opened = await transfer.openUrl(start.link);
    if (attempt != _attempt) return;
    if (!opened) {
      return _fail(attempt, 'Could not open Telegram. Is it installed?');
    }
    _enrol = start;
    final deadline = _now().add(waitFor);
    while (attempt == _attempt && _now().isBefore(deadline)) {
      await Future<void>.delayed(pollEvery);
      if (attempt != _attempt) return;
      try {
        final phase = await client.enrolStatus(start);
        if (attempt != _attempt) return;
        switch (phase) {
          case EnrolPhase.awaitingCode:
            _phase = CompanionPhase.awaitingCode;
            problem = null;
            notifyListeners();
            return;
          case EnrolPhase.expired || EnrolPhase.claimed:
            return _fail(attempt, 'That link ran out. Try again.');
          case EnrolPhase.denied:
            return _fail(attempt, 'The companion is not open to you yet.');
          case EnrolPhase.pending:
            break;
        }
      } on CompanionNetworkError {
        // Keep waiting until the deadline.
      }
    }
    if (attempt == _attempt) {
      _fail(attempt, 'We did not see your message in Telegram yet.');
    }
  }

  EnrolStart? _enrol;

  /// The chat just connected (display name), shown once after enrolment.
  String? connectedTo;

  /// The runner typed the code from Telegram. Wrong code: stay on the code
  /// step with a line (five wrong tries lock it on the server).
  Future<void> submitCode(String code) async {
    final e = _enrol;
    if (_phase != CompanionPhase.awaitingCode || e == null) return;
    final attempt = _attempt;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      problem = 'The code is 6 digits.';
      notifyListeners();
      return;
    }
    try {
      final r = await client.enrolConfirm(e, code);
      if (attempt != _attempt) return;
      switch (r.outcome) {
        case ConfirmOutcome.ok:
          connectedTo = r.chatName;
          return await _bound(r.token!);
        case ConfirmOutcome.wrongCode:
          problem = 'That code is not right. Check Telegram and try again.';
        case ConfirmOutcome.malformed:
          problem = 'The code is 6 digits.';
        case ConfirmOutcome.expired:
          return _fail(attempt, 'That code ran out. Start again.');
        case ConfirmOutcome.busy:
          problem = 'The companion is busy. Try again.';
      }
    } on CompanionNetworkError {
      problem = 'No network. Try again.';
    }
    notifyListeners();
  }

  Future<void> _bound(String token) async {
    _enrol = null;
    try {
      await store.write(tokenName, token);
    } catch (e) {
      companionLog('could not save the token (${e.runtimeType})');
      _phase = CompanionPhase.failed;
      problem = 'Could not keep the key safe on this phone.';
      notifyListeners();
      return;
    }
    _phase = CompanionPhase.on;
    problem = null;
    _consentSent = 0;
    notifyListeners();
    await syncConsent();
    await onEnrolled?.call(_now());
  }

  void _fail(int attempt, String why) {
    if (attempt != _attempt) return;
    _phase = CompanionPhase.failed;
    problem = why;
    notifyListeners();
  }

  /// Stop waiting (the Cancel button).
  void cancel() {
    if (_phase != CompanionPhase.waiting &&
        _phase != CompanionPhase.awaitingCode) {
      return;
    }
    _attempt++;
    _enrol = null;
    _phase = CompanionPhase.off;
    problem = null;
    notifyListeners();
  }

  /// Fetches the coach's next session for Home. Quiet by design: only runs
  /// when the companion is on, linked and agreed; offline or an error keeps
  /// the last good reply; a 404 (a server without check-ins) or a bad token
  /// clears it. Never sets [problem]. At most one call a minute.
  Future<void> refreshNext() async {
    if (!enrolled || !consentCurrent || _nextBusy) return;
    final at = _nextAt;
    if (at != null && _now().difference(at) < const Duration(minutes: 1)) {
      return;
    }
    final t = await token();
    if (t == null) return;
    _nextBusy = true;
    _nextAt = _now();
    try {
      final r = await client.getNextSession(t);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.status == 404) {
        await _setNext(null, null);
        return;
      }
      if (!r.ok) return;
      final parsed = CoachNext.parse(r.json);
      if (parsed == null) return;
      await _setNext(parsed, r.body);
    } on CompanionNetworkError {
      // Keep what we have.
    } catch (e) {
      companionLog('next session failed (${e.runtimeType})');
    } finally {
      _nextBusy = false;
    }
  }

  /// What Start does with the cached briefing for the session it is starting.
  /// SYNCHRONOUS: it reads only memory (filled by [load] and [refreshBriefing]), so
  /// the Start path never waits on the network or on storage. [sessionRef] and
  /// [fingerprint] are the started session's (see [companionSessionRef] and
  /// `StartBriefing.fingerprintOf`); pass null for a run that is not today's plan
  /// session. Nothing is used while the companion is off, not linked or not agreed.
  BriefingChoice briefingChoice({
    required String? sessionRef,
    required String? fingerprint,
  }) => enrolled && consentCurrent
      ? BriefingCache.choose(
          _briefing,
          sessionRef: sessionRef,
          fingerprint: fingerprint,
          now: _now(),
        )
      : BriefingChoice.none;

  /// Today's session from the coach's own default week (the runner has no plan
  /// in the app), when the server sent the keys its briefing is stored under.
  /// Null for any other day, an app plan session (Start matches those through
  /// the plan itself) or an older server. Memory only, like [briefingChoice].
  CoachSession? get coachDayToday {
    final s = coachNext?.session;
    if (s == null || !s.derived) return null;
    if (s.sessionRef == null || s.fingerprint == null) return null;
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    return s.date == today ? s : null;
  }

  /// Fetches the coach's start briefing (`GET /v1/me/briefing`) and updates
  /// the cache. Quiet like [refreshNext]: never sets [problem]. Only on Home
  /// load and after a run upload ([force] skips the one-a-minute limit), never
  /// at Start. 200 with a template replaces the cache; 200 suppress keeps a
  /// marker (no briefing at Start, not even the app's own); 202 pending keeps
  /// the cache; 204 clears it; offline or an error keeps it.
  Future<void> refreshBriefing({bool force = false}) async {
    if (!enrolled || !consentCurrent || _briefingBusy) return;
    final at = _briefingAt;
    if (!force &&
        at != null &&
        _now().difference(at) < const Duration(minutes: 1)) {
      return;
    }
    final t = await token();
    if (t == null) return;
    _briefingBusy = true;
    _briefingAt = _now();
    try {
      final r = await client.getBriefing(t);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
        return;
      }
      if (r.status == 204) {
        await _setBriefing(null);
        return;
      }
      if (r.status == 202) return; // pending: keep the cache
      if (r.status != 200) return; // 404 (older server), 429, 5xx: keep it
      final c = CachedBriefing.fromReply(r.json, _now());
      if (c != null) await _setBriefing(c);
    } on CompanionNetworkError {
      // Keep what we have.
    } catch (e) {
      companionLog('briefing failed (${e.runtimeType})', secrets: [t]);
    } finally {
      _briefingBusy = false;
    }
  }

  Future<void> _setBriefing(CachedBriefing? c) async {
    _briefing = c;
    try {
      if (c == null) {
        await store.delete(briefingName);
      } else {
        await store.write(briefingName, c.encode());
      }
    } catch (e) {
      companionLog('could not keep the briefing (${e.runtimeType})');
    }
  }

  Future<void> _setNext(CoachNext? next, String? raw) async {
    _coachNext = next;
    try {
      if (raw == null) {
        await store.delete(nextName);
      } else {
        await store.write(nextName, raw);
      }
    } catch (e) {
      companionLog('could not keep the coach reply (${e.runtimeType})');
    }
    notifyListeners();
  }

  /// GET /v1/me. Null with [problem] set when it could not be read.
  Future<CompanionMe?> fetchMe() async {
    final t = await token();
    if (t == null) return null;
    try {
      final r = await client.getMe(t);
      if (r.reply.status == 401 || r.reply.status == 403) {
        await _wipe();
        return null;
      }
      if (r.me == null) {
        problem = 'The companion is busy. Try again.';
        notifyListeners();
      } else if (r.me!.serverConsent != _serverConsent ||
          r.me!.coachAvailable != _coachAvailable ||
          r.me!.coachLink != _coachLink) {
        _serverConsent = r.me!.serverConsent;
        _coachAvailable = r.me!.coachAvailable;
        _coachLink = r.me!.coachLink;
        notifyListeners();
      }
      return r.me;
    } on CompanionNetworkError {
      problem = 'No network. Try again.';
      notifyListeners();
      return null;
    }
  }

  /// "Delete everything" and "Turn off": DELETE /v1/me, then wipe the local
  /// token. Only wipes once the server has confirmed (or says the token is
  /// already dead), so a failed call can be retried. True when done.
  Future<bool> deleteEverything() async {
    final t = await token();
    if (t == null) {
      await _wipe();
      return true;
    }
    try {
      final r = await client.deleteMe(t);
      if (r.ok || r.status == 401 || r.status == 403 || r.status == 404) {
        await _wipe();
        return true;
      }
      problem = 'The companion is busy. Nothing was deleted yet. Try again.';
    } on CompanionNetworkError {
      problem = 'No network. Nothing was deleted yet. Try again.';
    }
    notifyListeners();
    return false;
  }

  Future<void> _wipe() async {
    _attempt++;
    try {
      await store.delete(tokenName);
      await store.delete(consentName);
      await store.delete(healthNotesName);
      await store.delete(trainingSyncName);
      await store.delete(memoryDismissedName);
      await store.delete(coachDismissedName);
      await store.delete(weatherName);
      await store.delete(weatherForgetName);
      await store.delete(placeNamesName);
      await store.delete(placeNamesForgetName);
      await store.delete(heartRateName);
      await store.delete(heartRateForgetName);
      await store.delete(nextName);
      await store.delete(briefingName);
      // The route choice is the runner's and survives a wipe (a 401, a
      // re-enrol): an OFF stays off, and the new server record is told so as
      // soon as there is a token again.
      if (!_routeShape) await store.write(routeForgetName, '1');
    } catch (e) {
      companionLog('could not remove the token (${e.runtimeType})');
    }
    _phase = CompanionPhase.off;
    _weather = false;
    _placeNames = false;
    _heartRate = false;
    _consent = 0;
    _consentSent = 0;
    _healthNotes = false;
    _trainingSync = true;
    _memoryDismissed = false;
    _coachDismissed = false;
    _serverConsent = null;
    _coachAvailable = null;
    _coachLink = null;
    _coachNext = null;
    _briefing = null;
    problem = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _attempt++;
    super.dispose();
  }
}

// ------------------------------------------------------------------ summary

/// The IANA zone for the summary. The run's own when it has one, else a
/// fixed `Etc/GMT` zone for a whole-hour offset (an indoor run); null when
/// neither can be named, and the run waits.
String? companionZoneId(String? zoneId, int? offsetMin) {
  if (zoneId != null && zoneId.isNotEmpty) return zoneId;
  if (offsetMin == null || offsetMin % 60 != 0) return null;
  final h = offsetMin ~/ 60;
  if (h == 0) return 'Etc/UTC';
  if (h < -12 || h > 14) return null;
  // Etc/GMT zones are signed the other way round.
  return h > 0 ? 'Etc/GMT-$h' : 'Etc/GMT+${-h}';
}

/// One coordinate rounded to 0.1 degree (about 11 km). Never -0.0.
double areaCell(double v) {
  final r = (v * 10).roundToDouble() / 10;
  return r == 0 ? 0.0 : r;
}

/// The coach's word for a planned session: easy, long or quality (intervals
/// and goal runs). The server accepts nothing else.
String companionPlanType(engine.BlockKind k) => switch (k) {
  engine.BlockKind.easy => 'easy',
  engine.BlockKind.long => 'long',
  engine.BlockKind.interval || engine.BlockKind.goal => 'quality',
};

String _planDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// What the stored 4-week plan says about [runId] and what comes next. Only
/// what the plan already holds, and only when there is a plan: the session
/// type, the week numbers, the planned local day, and a size where the plan
/// has one (minutes, or a minimum distance on the long test). No reason text,
/// no preset, no heart rate. Empty with no plan.
///
/// - `plan_kind`, `plan_target_m`: the planned session this run was done as.
/// - `plan_week`, `plan_weeks`: that session's week (else the current week)
///   of the plan's [engine.BlockPlanner.weeks]. Only for a run in the plan or
///   started on or after the plan began ([runStart], the wall clock where it
///   was run): a backfilled old run never gets today's week.
/// - `plan_next`: the first session still to do that is planned for the day
///   after the run or later (an overdue one is skipped, so tomorrow's is not
///   hidden by it), with its planned day.
/// - Any value outside what the server accepts is left out, so one corrupt
///   stored number can never fail the whole run.
///   `plan_weeks_to_race` is never sent: the app has no race date.
Map<String, Object?> companionPlanFacts(
  engine.BlockView? view,
  String runId, {
  DateTime? runStart,
  engine.TargetPaces? paces,
}) {
  if (view == null) return const {};
  engine.BlockSessionState? own;
  for (final st in view.all) {
    if (st.runId == runId) own = st;
  }
  final inPlan =
      own != null || (runStart != null && !runStart.isBefore(view.plan.start));
  if (!inPlan) return const {};
  int? within(num? v, int lo, int hi) {
    if (v == null) return null;
    final r = v.round();
    return r >= lo && r <= hi ? r : null;
  }

  final week = within(own?.session.week ?? view.currentWeek, 1, 52);
  engine.BlockSessionState? next;
  if (runStart != null) {
    final from = DateTime(runStart.year, runStart.month, runStart.day + 1);
    for (final st in view.all) {
      if (st.status != engine.BlockStatus.done &&
          st.status != engine.BlockStatus.missed &&
          !st.date.isBefore(from)) {
        next = st;
        break;
      }
    }
  }
  final nextWeek = within(next?.session.week, 1, 52);
  final minutes = within(next?.session.minutes, 1, 600);
  final dist = within(next?.session.minDistanceM, 500, 100000);
  return {
    if (own != null) 'plan_kind': companionPlanType(own.session.kind),
    'plan_target_m': ?within(own?.session.minDistanceM, 0, 300000),
    'plan_week': ?week,
    if (week != null) 'plan_weeks': engine.BlockPlanner.weeks,
    if (next != null && nextWeek != null)
      'plan_next': {
        'type': companionPlanType(next.session.kind),
        'day': _planDay(next.date),
        'week': nextWeek,
        'minutes': ?minutes,
        'distance_m': ?dist,
        'session_ref': ?companionSessionRef(next.session),
        ...companionTemplateFacts(next.session),
        ...companionPaceFacts(next.session, paces),
      },
  };
}

/// The work pace the coach's morning card shows for a quality session:
/// `target_pace_lo_s`, `target_pace_hi_s` (the same True Pace, whole seconds
/// per km) and `target_pace_method` (`vdot`, or `moved` after a nudge the
/// runner accepted). Quality sessions only: an easy or long pace is a
/// ceiling, not a target to hit. Nothing without targets or off the range the
/// server accepts.
Map<String, Object?> companionPaceFacts(
  engine.BlockSession session,
  engine.TargetPaces? paces,
) {
  if (paces == null ||
      (session.kind != engine.BlockKind.interval &&
          session.kind != engine.BlockKind.goal)) {
    return const {};
  }
  final p = paces.sessionPace(session);
  if (p == null || !p.isFinite) return const {};
  final s = p.roundToDouble();
  if (s < 120 || s > 1200) return const {};
  return {
    'target_pace_lo_s': s,
    'target_pace_hi_s': s,
    'target_pace_method': paces.sessionPaceMoved(session) ? 'moved' : 'vdot',
  };
}

final RegExp _sessionRef = RegExp(r'^[a-z0-9_]{1,16}$');

/// A session id as the server slugs it (`norwegian-4x4` -> `norwegian_4x4`), to match a coach-week quality day's
/// `session_id` against the built-in session picked at Start. Null in, null out.
String? coachSlug(String? id) {
  if (id == null) return null;
  final s = id
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return s.isEmpty ? null : s;
}

/// The plan session's opaque ref, sent as `plan_next.session_ref` and compared
/// at Start against the ref of a cached coach briefing (C2b A3). It is the
/// plan slot id (`w1s1`, stable across swaps), which is what the server stores
/// as `plan_next_session_ref` and keys its briefing on. Null when it is not in
/// the shape the server accepts (the briefing then simply never matches).
String? companionSessionRef(engine.BlockSession session) =>
    _sessionRef.hasMatch(session.id) ? session.id : null;

final RegExp _templateId = RegExp(r'^[a-z0-9_]{1,40}$');

/// `session_id` and `session_name` for a planned session, both or neither:
/// the built-in template's id (`norwegian_4x4`, hyphens as underscores; never
/// the plan slot id like `w1s1`) and its built-in display name. A session with
/// no built-in template (an easy or long run, a goal run, a custom session)
/// sends neither. The name is always the catalogue's, never text the runner
/// typed.
Map<String, Object?> companionTemplateFacts(engine.BlockSession session) {
  if (session.kind != engine.BlockKind.interval) return const {};
  final preset = session.presetId == null
      ? null
      : engine.SessionCatalogue.byId(session.presetId!);
  if (preset == null) return const {};
  final id = preset.id.toLowerCase().replaceAll('-', '_');
  final name = preset.name;
  if (!_templateId.hasMatch(id) || name.isEmpty || name.length > 40) {
    return const {};
  }
  return {'session_id': id, 'session_name': name};
}

/// The compact run summary the companion gets (B6, C4, C6): fields only, no
/// GPS points, no street, no heart-rate trace. Besides the totals it carries
/// `splits` (per km: length, pace, HR zone), `reps` (a structured run's rep
/// times) and, with [withRoute], `route`: an outline of the run, ends cut off, at most 120 whole
/// number points in a unit box with no coordinates or compass direction (made by
/// `routeShape` in run_engine). Null when the run has no time zone yet. The server decides staleness (more than 6 h after the run
/// ended: kept, no card) from `start_utc` and `duration_s`.
Map<String, Object?>? companionSummary(
  RunDetail d, {
  engine.HrZones? zones,
  engine.RunFeel? feel,
  bool withArea = false,
  bool withRoute = false,
  List<engine.PrivacyZone> privacyZones = const [],
  Map<String, Object?> plan = const {},
  Map<String, Object?>? trail,
  Map<String, Object?>? quest,
  Map<String, Object?> load = const {},
  Map<String, Object?> goal = const {},
  String? pb,
  int? pbS,
}) {
  final s = d.summary;
  final run = d.run;
  double r1(double v) => (v * 10).roundToDouble() / 10;
  final offset = d.sidecar.utcOffsetMin ?? s.utcOffsetMin;
  final zone = companionZoneId(d.sidecar.zoneId ?? s.row?.zoneId, offset);
  if (offset == null || zone == null) return null;
  // The server takes VerdictHeadline.name as is.
  final headline = s.verdict?.headline.name;
  Map<String, double>? zoneMin;
  if (zones != null) {
    final secs = zoneSecondsOf(run, zones);
    if (secs.skip(1).any((x) => x > 0)) {
      zoneMin = {for (var z = 1; z <= 5; z++) 'z$z': r1(secs[z] / 60)};
    }
  }
  final pace = s.avgSecPerKm;
  final tp = s.truePaceSecPerKm;
  // The index row is null on an upload (the run is read from its file), so
  // fall back to the file's own elevation, as the spoken summary does.
  final climb = s.row?.climbM ?? engine.RunElevation.of(run)?.ascentM;
  return {
    'run_id': run.id,
    'type': s.uploadMode.name,
    'start_utc': run.start.toUtc().toIso8601String(),
    'utc_offset_min': offset,
    'zone_id': zone,
    'duration_s': (s.durationMs / 1000).round(),
    'distance_m': r1(s.distanceM),
    'pace_s_per_km': ?(pace == null ? null : r1(pace)),
    'true_pace_s_per_km': ?(tp == null ? null : r1(tp)),
    'verdict': ?headline,
    'zone_min': ?zoneMin,
    'climb_m': ?(climb == null ? null : r1(climb)),
    // The area name only (locality), never the street.
    'locality': ?s.place,
    // 5k, 10k or half: a strict personal best (Boards.companionPb).
    'pb': ?pb,
    'pb_s': ?(pb == null ? null : pbS),
    'feel': ?(feel ?? d.sidecar.feel)?.name,
    // The session's name and work/rep/recovery paces (interval runs only).
    ...companionIntervalFacts(s),
    // A goal run's target time and where it came from (companionGoalFacts).
    ...goal,
    // The 4-week plan's facts (companionPlanFacts), when there is a plan.
    ...plan,
    'trail': ?trail,
    // load, load_basis, load_state (LoadWire.facts).
    ...load,
    // Built by questWire, only for a server that knows quests.
    'quest': ?quest,
    // Only with "Weather in suggestions" on: the start point rounded to 0.1
    // degree (about 11 km) here on the phone, so the server never gets more.
    if (withArea && s.startPoint != null) ...{
      'area_lat': areaCell(s.startPoint!.lat),
      'area_lon': areaCell(s.startPoint!.lon),
    },
    // route (only with the switch), splits, reps: built in run_engine so the
    // history replay sends exactly the same.
    ...engine.companionShapeFields(
      run,
      zones: zones,
      intervals: d.analysis.mode == engine.RunMode.intervals
          ? d.analysis.intervals
          : null,
      withRoute: withRoute,
      privacyZones: privacyZones,
    ),
  };
}

/// What the coach needs to name and judge a session. An interval session
/// sends its name and the verdict's own numbers (engine `coachIntervalFacts`);
/// one without a work pace (no reps found, stopped early) still sends the
/// name, so the card can say which session it was. A goal run goes up as a
/// free run named by its goal ("10K goal") with whether it was reached, never
/// as an interval session. Parkrun sends none.
Map<String, Object?> companionIntervalFacts(RunSummary s) {
  if (s.isParkrun || !(s.isFourByFour || s.spec?.isGoal == true)) {
    return const {};
  }
  if (s.spec?.isGoal == true) {
    final g = s.goalResult;
    final name = g == null ? null : '${g.name} goal';
    if (name == null || !_goalName.hasMatch(name)) return const {};
    return {'session_name': name, 'goal_reached': g!.reached};
  }
  final name = s.spec?.name ?? engine.SessionCatalogue.norwegian4x4.name;
  if (s.uploadsAsFree || !s.hasIntervals) {
    return {'session_name': engine.coachSessionName(name)};
  }
  final facts = engine.coachIntervalFacts(
    sessionName: name,
    workPaceSecPerKm: s.trueWorkPaceSecPerKm ?? s.workPaceSecPerKm,
    repsDone: s.detectedReps,
    cleanRepPacesSecPerKm: s.cleanRepPacesSecPerKm.whereType<double>(),
    recoveryPaceSecPerKm: s.recoveryPaceSecPerKm,
  );
  return facts.isEmpty
      ? {'session_name': engine.coachSessionName(name)}
      : facts;
}

/// A distance goal run's target time as the Start card showed it, with the
/// effort it was read from ("5K on 26 Oct"): `goal_target_s` and
/// `goal_target_from`; this rebuilds it from a [engine.StartTarget] (only for a
/// run recorded before the target was kept with the run). A training number, the same class as pace. Empty for
/// any other run, or without a target; an older server never gets them
/// (the caller only asks a server that takes them).
Map<String, Object?> companionGoalFacts(engine.StartTarget? t) {
  final ms = t?.liveTargetMs;
  if (t == null || ms == null || ms <= 0) return const {};
  return companionGoalFactsOf(
    engine.GoalTargetRecord(targetMs: ms, source: t.sourceText),
  );
}

/// The same facts from the target the run kept (what Start showed, as raced),
/// plus `goal_eased` when the runner chose ease off on purpose (the debrief
/// never judges the finish against the target), and `goal_retarget_s` for a
/// run an older build re-aimed (retired; kept for old sidecars).
Map<String, Object?> companionGoalFactsOf(engine.GoalTargetRecord? g) {
  if (g == null || g.targetMs <= 0) return const {};
  final from = g.source;
  final re = g.retargetMs;
  return {
    'goal_target_s': (g.targetMs / 1000).round(),
    if (from != null && _goalFrom.hasMatch(from)) 'goal_target_from': from,
    if (re != null && re > 0) 'goal_retarget_s': (re / 1000).round(),
    if (g.eased) 'goal_eased': true,
  };
}

final RegExp _goalFrom = RegExp(r'^[A-Za-z0-9 .]{1,40}$');

/// The goal names the server accepts (`GoalCatalogue.nameFor` and
/// `Settings.goalName` plus " goal": "10K goal", "12.3 km goal", "1 hour goal").
final RegExp _goalName = RegExp(
  r'^(\d{1,2}K|Half|Marathon|\d{1,3}\.\d (km|mi)|\d{1,2} min|1 hour|\d{1,2} h( \d{1,2} min)?) goal$',
);

// ------------------------------------------------------------------- target

/// The companion as an [ExportTarget] (B6): it inherits the sidecar
/// `autoSendDue` log, the `autoSendSince` cutoff (no backfill of old runs on
/// enrolment) and the coordinator's in-flight dedupe. Not listed in the Send
/// sheet or the Settings send list: it has its own Settings > Companion.
class CompanionTarget extends ExportTarget {
  CompanionTarget({
    required this.controller,
    this.zones,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  static const String targetId = 'companion';

  /// Marks "the feel for this run reached the server" in the sidecar log.
  static const String feelLogId = engine.RunSidecar.feelSendId;

  final CompanionController controller;
  final engine.HrZones Function()? zones;

  /// The plan's facts for a run (companionPlanFacts over the stored plan),
  /// wired by AppServices; null sends no plan fields.
  Future<Map<String, Object?>> Function(RunDetail run)? planFacts;

  /// The trail block for a run (`trailBlockFor`), wired by AppServices; null
  /// sends none. Gets whether trail names may go out.
  Future<Map<String, Object?>?> Function(RunDetail run, {required bool names})?
  trailFacts;

  /// The quest block for a run (`questWire`), wired by AppServices; null sends
  /// none. Gets whether trail names may go out. Only called for a server that
  /// has said it knows quests.
  Future<Map<String, Object?>?> Function(RunDetail run, {required bool names})?
  questFacts;

  /// The goal run's target for a run (`companionGoalFacts`), wired by
  /// AppServices; null sends none.
  Future<Map<String, Object?>> Function(RunDetail run)? goalFacts;

  /// The load fields for a run (`LoadWire.facts`), wired by AppServices; null
  /// sends none. Gets whether the server takes `load` and `load_basis`.
  Future<Map<String, Object?>> Function(
    RunDetail run, {
    required bool withLoad,
  })?
  loadFacts;

  /// The `pb` for a run (`Boards.companionPb`), wired by AppServices; null
  /// sends none.
  Future<({String wire, int seconds})?> Function(RunDetail run)? pbFacts;

  /// When the server last answered 422 (older than this app). For
  /// [outdatedWait] no run is sent and no automatic try is spent; a new app
  /// start clears it, so it is also retried on the next open.
  DateTime? _outdatedAt;
  static const Duration outdatedWait = Duration(hours: 6);
  @override
  String get id => targetId;
  @override
  String get label => 'Run companion';
  @override
  String get blurb => 'A short note after each run';
  @override
  bool get supportsAutomatic => true;
  @override
  bool get listed => false;

  /// On exactly while enrolled; the runner's switch is Settings > Companion.
  @override
  bool isEnabled(AppSettings s) => controller.enrolled;

  /// A plan read that fails sends the run without plan fields, never fails it.
  Future<Map<String, Object?>> _plan(RunDetail run) async {
    try {
      return await planFacts?.call(run) ?? const {};
    } catch (e) {
      companionLog('plan read failed (${e.runtimeType})');
      return const {};
    }
  }

  /// A goal-target read that fails sends the run without it, never fails it;
  /// never sent to a server that has not said it takes it.
  Future<Map<String, Object?>> _goal(RunDetail run) async {
    if (!controller.goalTargetSupported) return const {};
    try {
      final facts = await goalFacts?.call(run) ?? const {};
      // goal_eased is newer than the goal target: its own capability.
      if (controller.goalEasedSupported || !facts.containsKey('goal_eased')) {
        return facts;
      }
      return {...facts}..remove('goal_eased');
    } catch (e) {
      companionLog('goal target read failed (${e.runtimeType})');
      return const {};
    }
  }

  /// A load read that fails sends the run without load fields, never fails it.
  Future<Map<String, Object?>> _load(RunDetail run) async {
    try {
      return await loadFacts?.call(run, withLoad: controller.loadSupported) ??
          const {};
    } catch (e) {
      companionLog('load read failed (${e.runtimeType})');
      return const {};
    }
  }

  /// A pb read that fails sends the run without a pb, never fails it.
  Future<({String wire, int? seconds})?> _pb(RunDetail run) async {
    try {
      final pb = await pbFacts?.call(run);
      if (pb == null) return null;
      if (controller.pbTimeSupported) {
        return (wire: pb.wire, seconds: pb.seconds);
      }
      // An older server speaks of the run, not the effort: only a run that
      // is that distance (within 3%) is its own PB.
      final whole = switch (pb.wire) {
        '5k' => 5000.0,
        '10k' => 10000.0,
        _ => 21097.5,
      };
      return run.summary.distanceM <= whole * 1.03
          ? (wire: pb.wire, seconds: null)
          : null;
    } catch (e) {
      companionLog('pb read failed (${e.runtimeType})');
      return null;
    }
  }

  /// A trail read that fails or takes over 3 s sends the run without a trail block.
  Future<Map<String, Object?>?> _trail(RunDetail run) async {
    try {
      // Never holds the upload: a slow file read just means no trail block.
      return await trailFacts
          ?.call(run, names: controller.placeNamesOn)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      companionLog('trail read failed (${e.runtimeType})');
      return null;
    }
  }

  /// A quest read that fails or takes over 3 s sends the run without a quest
  /// block. Never sent to a server that has not said it knows quests: it
  /// refuses the whole run for a key it does not know.
  Future<Map<String, Object?>?> _quest(RunDetail run) async {
    if (!controller.questsSupported) return null;
    try {
      return await questFacts
          ?.call(run, names: controller.placeNamesOn)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      companionLog('quest read failed (${e.runtimeType})');
      return null;
    }
  }

  @override
  Future<SendResult> send(SendRequest req) async {
    final d = req.detail;
    if (d == null) return const SendResult.failed('Run not found');
    final token = await controller.token();
    if (token == null) return const SendResult.failed('Companion is off');
    final out = _outdatedAt;
    if (out != null && _now().difference(out) < outdatedWait) {
      return const SendResult.failed(
        'Companion server needs an update. Will retry later',
        retryLater: true,
      );
    }
    try {
      await controller.syncWeather();
      await controller.syncPlaceNames();
      await controller.syncHeartRate();
      await controller.syncRouteShape();
      await controller.syncConsent();
      final hide = controller.routeShapeOn
          ? await controller.privacyZonesFor(d.run)
          : const <engine.PrivacyZone>[];
      final routeOk = controller.routeShapeOn && hide != null;
      final pbRead = await _pb(d);
      final summary = companionSummary(
        d,
        zones: zones?.call(),
        withArea: controller.weatherOn,
        withRoute: routeOk,
        privacyZones: hide ?? const [],
        plan: await _plan(d),
        trail: await _trail(d),
        quest: await _quest(d),
        load: await _load(d),
        goal: await _goal(d),
        pb: pbRead?.wire,
        pbS: pbRead?.seconds,
      );
      if (summary == null) {
        return const SendResult.failed('Run has no time zone yet');
      }
      final o = await controller.client.postRun(token, summary);
      switch (o) {
        case RunSendOutcome.sent || RunSendOutcome.duplicate:
          // The server now queues a briefing for the next session; ask for it
          // (quietly, not awaited: the send does not wait on it).
          unawaited(controller.refreshBriefing(force: true));
          return const SendResult.ok();
        case RunSendOutcome.unauthorized:
          return const SendResult.failed('Companion key not accepted');
        case RunSendOutcome.outdated:
          _outdatedAt = _now();
          return const SendResult.failed(
            'Companion server needs an update. Will retry later',
            retryLater: true,
          );
        case RunSendOutcome.rejected:
          return const SendResult.failed(
            'Companion refused this run (check the phone clock)',
            permanent: true,
          );
        case RunSendOutcome.busy:
          return const SendResult.failed('Companion is busy');
      }
    } on CompanionNetworkError {
      return const SendResult.failed('No network');
    } catch (e) {
      companionLog('send threw (${e.runtimeType})', secrets: [token]);
      return const SendResult.failed('Could not send');
    }
  }
}

/// After a feel tap, or on app open: tell the server about feels it has not
/// got. A run whose summary has not gone yet carries its feel in the summary,
/// so only runs already sent need the PATCH. Idempotent on the server.
/// Returns how many PATCHes went.
Future<int> flushCompanionFeels(
  RunStore history,
  CompanionController controller, {
  int window = SendCoordinator.retryWindow,
  DateTime Function()? now,
}) async {
  if (!controller.enrolled) return 0;
  final token = await controller.token();
  if (token == null) return 0;
  var sent = 0;
  final runs = await history.list();
  for (final r in runs.take(window)) {
    if (r.missing) continue;
    final d = await history.load(r.id);
    if (d == null) continue;
    final feel = d.sidecar.feel;
    final log = d.sidecar.sends;
    if (feel == null || log[CompanionTarget.targetId]?.ok != true) continue;
    if (log[CompanionTarget.feelLogId]?.ok == true) continue;
    try {
      final ok = await controller.client.patchFeel(token, r.id, feel);
      await history.recordSend(
        r.id,
        CompanionTarget.feelLogId,
        ok: ok,
        at: (now ?? DateTime.now)(),
        auto: false,
      );
      if (ok) sent += 1;
    } on CompanionNetworkError {
      return sent;
    }
  }
  return sent;
}

/// Save a feel tap with the run and, when the companion is on, send it. The
/// local save comes first so the tap works offline.
Future<void> recordFeel(
  RunStore history,
  CompanionController? companion,
  String runId,
  engine.RunFeel feel,
) async {
  await history.setFeel(runId, feel);
  if (companion == null || !companion.enrolled) return;
  try {
    await flushCompanionFeels(history, companion);
  } catch (e) {
    companionLog('feel flush failed (${e.runtimeType})');
  }
}
