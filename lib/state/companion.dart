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
const int kCompanionConsentVersion = 2;

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
  Future<CompanionReply> putConsent(String token, int version) => http.send(
    CompanionRequest(
      method: 'PUT',
      uri: _uri(['v1', 'me', 'consent']),
      headers: _headers(token, json: true),
      body: utf8.encode(jsonEncode({'consent_version': version})),
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
  });

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

/// What Home shows from the coach. Either part can be absent.
@immutable
class CoachNext {
  const CoachNext({this.session, this.line, this.generatedAt});
  final CoachSession? session;
  final CoachLine? line;
  final DateTime? generatedAt;

  bool get isEmpty => session == null && line == null;

  /// Null when the body is not a version-1 reply.
  static CoachNext? parse(Map<String, Object?> j) {
    if (j['v'] != 1) return null;
    final at = j['generated_at'];
    return CoachNext(
      session: CoachSession.fromJson(j['next_session']),
      line: CoachLine.fromJson(j['coach_line']),
      generatedAt: at is String ? DateTime.tryParse(at) : null,
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
  });

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
    return CompanionMe(
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
  ];
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

  /// True when the runner agreed to the current consent copy. A runner who
  /// turned on before [kCompanionConsentVersion] went up has to agree again.
  bool get consentCurrent => _consent >= kCompanionConsentVersion;

  /// Turned on, but under older consent copy: ask again before the coach's
  /// check-in data is shown or asked for.
  bool get needsReconsent => enrolled && !consentCurrent;

  /// The runner agrees to the current copy ("Agree" on the new check-ins).
  Future<void> acceptConsent() async {
    _consent = kCompanionConsentVersion;
    try {
      await store.write(consentName, '$kCompanionConsentVersion');
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
      final r = await client.putConsent(t, v);
      if (r.status == 401 || r.status == 403) {
        await _wipe();
      } else if (r.ok) {
        _consentSent = v;
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
        final cached = await store.read(nextName);
        if (cached != null && cached.isNotEmpty) {
          final j = jsonDecode(cached);
          if (j is Map<String, Object?>) _coachNext = CoachNext.parse(j);
        }
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
    _consent = kCompanionConsentVersion;
    try {
      await store.write(consentName, '$kCompanionConsentVersion');
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
      await store.delete(weatherName);
      await store.delete(weatherForgetName);
      await store.delete(placeNamesName);
      await store.delete(placeNamesForgetName);
      await store.delete(heartRateName);
      await store.delete(heartRateForgetName);
      await store.delete(nextName);
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
    _coachNext = null;
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
  final climb = s.row?.climbM;
  return {
    'run_id': run.id,
    'type': s.mode.name,
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
    'feel': ?(feel ?? d.sidecar.feel)?.name,
    // The session's name and work/rep/recovery paces (interval runs only).
    ...companionIntervalFacts(s),
    // The 4-week plan's facts (companionPlanFacts), when there is a plan.
    ...plan,
    'trail': ?trail,
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

/// What the coach needs to judge an interval session on its work, not the
/// whole-run average: the session's name and the verdict's own numbers
/// (engine `coachIntervalFacts`). A goal run or parkrun sends none, and
/// neither does a run without a work pace.
Map<String, Object?> companionIntervalFacts(RunSummary s) {
  if (!s.isFourByFour || s.isParkrun || !s.hasIntervals) return const {};
  return engine.coachIntervalFacts(
    sessionName: s.spec?.name ?? engine.SessionCatalogue.norwegian4x4.name,
    workPaceSecPerKm: s.trueWorkPaceSecPerKm ?? s.workPaceSecPerKm,
    repsDone: s.detectedReps,
    cleanRepPacesSecPerKm: s.cleanRepPacesSecPerKm.whereType<double>(),
    recoveryPaceSecPerKm: s.recoveryPaceSecPerKm,
  );
}

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
      final summary = companionSummary(
        d,
        zones: zones?.call(),
        withArea: controller.weatherOn,
        withRoute: routeOk,
        privacyZones: hide ?? const [],
        plan: await _plan(d),
        trail: await _trail(d),
      );
      if (summary == null) {
        return const SendResult.failed('Run has no time zone yet');
      }
      final o = await controller.client.postRun(token, summary);
      switch (o) {
        case RunSendOutcome.sent || RunSendOutcome.duplicate:
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
