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
/// - `PUT /v1/me/settings` `{weather: bool}` (Bearer): the weather switch
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

/// `--dart-define=COMPANION=1` (or `true`). ON only in the dogfood build;
/// the Play release build ships without the companion (B2 release gate).
const String _kCompanionFlag = String.fromEnvironment('COMPANION');
const bool kCompanion = _kCompanionFlag == '1' || _kCompanionFlag == 'true';

/// The companion server. Override with `--dart-define=COMPANION_URL=`.
const String kCompanionUrl = String.fromEnvironment(
  'COMPANION_URL',
  defaultValue: 'https://companion.taiaroa.xyz',
);

const String kCompanionPrivacyUrl = 'https://runsupreme.taiaroa.xyz/privacy/';

/// Bump when the consent copy changes in a way that needs a fresh "Turn on".
const int kCompanionConsentVersion = 1;

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

  Future<CompanionReply> deleteMe(String token) => http.send(
    CompanionRequest(
      method: 'DELETE',
      uri: _uri(['v1', 'me']),
      headers: _headers(token),
    ),
  );
}

// ------------------------------------------------------------ what it knows

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
  });

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

  /// Set while the server has not yet confirmed "forget my areas". Retried
  /// on open and before the next send, so a switch-off made offline lands.
  static const String weatherForgetName = 'companion_weather_forget';

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
  bool _weather = false;

  /// "Weather in suggestions" (off until the runner turns it on). The run
  /// summary carries a rounded area only while this is true.
  bool get weatherOn => _weather && enrolled;

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
        _weather = await store.read(weatherName) == '1';
      } catch (e) {
        companionLog('could not read the weather switch (${e.runtimeType})');
      }
    }
    notifyListeners();
    if (_phase == CompanionPhase.on) await syncWeather();
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
    notifyListeners();
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
    } catch (e) {
      companionLog('could not remove the token (${e.runtimeType})');
    }
    _phase = CompanionPhase.off;
    _weather = false;
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
      },
  };
}

/// The compact run summary the companion gets (B6, C4, C6): fields only, no
/// route points, no street, no heart-rate trace. Null when the run has no
/// time zone yet. The server decides staleness (more than 6 h after the run
/// ended: kept, no card) from `start_utc` and `duration_s`.
Map<String, Object?>? companionSummary(
  RunDetail d, {
  engine.HrZones? zones,
  engine.RunFeel? feel,
  bool withArea = false,
  Map<String, Object?> plan = const {},
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
    // The 4-week plan's facts (companionPlanFacts), when there is a plan.
    ...plan,
    // Only with "Weather in suggestions" on: the start point rounded to 0.1
    // degree (about 11 km) here on the phone, so the server never gets more.
    if (withArea && s.startPoint != null) ...{
      'area_lat': areaCell(s.startPoint!.lat),
      'area_lon': areaCell(s.startPoint!.lon),
    },
  };
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
      final summary = companionSummary(
        d,
        zones: zones?.call(),
        withArea: controller.weatherOn,
        plan: await _plan(d),
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
