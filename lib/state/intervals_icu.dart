/// Intervals.icu as a send target (founder 2 Oct). The runner pastes their
/// own API key and athlete id; the key lives in Android Keystore-backed
/// secure storage, never in settings, the run log, backups or logs.
///
/// Upload: `POST /api/v1/athlete/{id}/activities`, multipart `file` (the
/// run's TCX), `name` (the run title) and `external_id` (the run id, so a
/// second upload of the same run is refused as a duplicate and counts as
/// sent). Basic auth, user `API_KEY`, password the key.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'send_runs.dart';

const String kIntervalsHost = 'intervals.icu';
const String kIntervalsKeyHelp =
    'In Intervals.icu open Settings, then Developer settings. Copy your API '
    'key and your athlete id (it looks like i12345) from there.';

/// Where the key and athlete id are kept. One implementation is the Android
/// Keystore (see [SecureSecretStore]); tests use [MemorySecretStore].
abstract class SecretStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> delete(String name) async => values.remove(name);
}

/// Keystore-backed storage (flutter_secure_storage). Its files live in
/// shared preferences, which the Auto Backup rules never include (and the
/// rules exclude them by name as well).
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String name) => _s.read(key: name);
  @override
  Future<void> write(String name, String value) =>
      _s.write(key: name, value: value);
  @override
  Future<void> delete(String name) => _s.delete(key: name);
}

@immutable
class IntervalsCredentials {
  const IntervalsCredentials({required this.apiKey, required this.athleteId});
  final String apiKey;

  /// `i12345`, or `0` for "the owner of this key".
  final String athleteId;

  /// Never prints the key.
  @override
  String toString() => 'IntervalsCredentials(athlete: $athleteId, key: ***)';
}

/// What the Connect sheet accepts: a key with no spaces and an id of
/// letters and digits (blank means "0", the key's own athlete).
({IntervalsCredentials? creds, String? error}) parseCredentials(
  String key,
  String athleteId,
) {
  final k = key.trim();
  if (k.isEmpty) return (creds: null, error: 'Paste your API key');
  if (RegExp(r'\s').hasMatch(k)) {
    return (creds: null, error: 'The key has a space in it. Copy it again');
  }
  var id = athleteId.trim();
  if (id.isEmpty) id = '0';
  if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(id)) {
    return (creds: null, error: 'The athlete id is letters and digits only');
  }
  return (creds: IntervalsCredentials(apiKey: k, athleteId: id), error: null);
}

/// One HTTP exchange, so tests never touch the network.
@immutable
class IntervalsRequest {
  const IntervalsRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

@immutable
class IntervalsResponse {
  const IntervalsResponse(this.status, [this.body = '']);
  final int status;
  final String body;
}

/// Thrown by an [IntervalsHttp] when no response arrived (offline, timeout).
class IntervalsNetworkError implements Exception {
  const IntervalsNetworkError();
}

abstract class IntervalsHttp {
  /// Throws [IntervalsNetworkError] when there is no response.
  Future<IntervalsResponse> send(IntervalsRequest req);
}

/// dart:io over HTTPS with timeouts. Logs the error type only: error text
/// can carry request details.
class DartIoIntervalsHttp implements IntervalsHttp {
  const DartIoIntervalsHttp({
    this.connectTimeout = const Duration(seconds: 15),
    this.timeout = const Duration(seconds: 60),
  });
  final Duration connectTimeout;
  final Duration timeout;

  @override
  Future<IntervalsResponse> send(IntervalsRequest req) async {
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
      return IntervalsResponse(res.statusCode, text);
    } catch (e) {
      intervalsLog('request failed (${e.runtimeType})');
      throw const IntervalsNetworkError();
    } finally {
      client.close(force: true);
    }
  }
}

/// The only logger in this file. [secrets] are blanked out of the line, so
/// a key can never reach the log even through an exception message.
void intervalsLog(String line, {Iterable<String> secrets = const []}) {
  var out = line;
  for (final s in secrets) {
    if (s.isNotEmpty) out = out.replaceAll(s, '***');
  }
  debugPrint('intervals: $out');
}

/// `Basic ` plus base64 of `API_KEY:` and the key.
String intervalsAuthHeader(String apiKey) =>
    'Basic ${base64.encode(utf8.encode('API_KEY:$apiKey'))}';

Uri intervalsUri(String athleteId, [String tail = '']) => Uri(
  scheme: 'https',
  host: kIntervalsHost,
  pathSegments: ['api', 'v1', 'athlete', athleteId, if (tail.isNotEmpty) tail],
);

/// How a response reads: [sent] covers a fresh upload and a duplicate.
@immutable
class IntervalsOutcome {
  const IntervalsOutcome.sent({this.duplicate = false})
    : ok = true,
      line = null;
  const IntervalsOutcome.failed(String this.line)
    : ok = false,
      duplicate = false;
  final bool ok;
  final bool duplicate;
  final String? line;
}

const String kKeyNotAccepted = 'Key not accepted';

IntervalsOutcome mapUploadResponse(IntervalsResponse r) {
  final s = r.status;
  if (s >= 200 && s < 300) return const IntervalsOutcome.sent();
  if (s == 409) return const IntervalsOutcome.sent(duplicate: true);
  if (s == 401 || s == 403) {
    return const IntervalsOutcome.failed(kKeyNotAccepted);
  }
  final lower = r.body.toLowerCase();
  if (s >= 400 &&
      s < 500 &&
      (lower.contains('duplicate') || lower.contains('already exists'))) {
    return const IntervalsOutcome.sent(duplicate: true);
  }
  if (s == 404) return const IntervalsOutcome.failed('Athlete id not found');
  if (s == 408 || s == 429 || s >= 500) {
    return const IntervalsOutcome.failed('Intervals.icu is busy');
  }
  return IntervalsOutcome.failed('Intervals.icu said no ($s)');
}

class IntervalsIcuClient {
  IntervalsIcuClient(this.http, {String Function()? boundary})
    : _boundary = boundary ?? _defaultBoundary;
  final IntervalsHttp http;
  final String Function() _boundary;

  static int _n = 0;
  static String _defaultBoundary() =>
      'runsupreme${DateTime.now().microsecondsSinceEpoch}x${_n++}';

  /// GET athlete: proves the key and the id together.
  IntervalsRequest testRequest(IntervalsCredentials c) => IntervalsRequest(
    method: 'GET',
    uri: intervalsUri(c.athleteId),
    headers: {
      'Authorization': intervalsAuthHeader(c.apiKey),
      'Accept': 'application/json',
    },
  );

  IntervalsRequest uploadRequest(
    IntervalsCredentials c, {
    required String name,
    required String externalId,
    required String fileName,
    required String fileText,
    required String mimeType,
  }) {
    final b = _boundary();
    final out = BytesBuilder();
    void field(String n, String v) {
      out.add(
        utf8.encode(
          '--$b\r\nContent-Disposition: form-data; name="$n"\r\n\r\n'
          // A line break in a value would end the part early.
          '${v.replaceAll(RegExp(r'[\r\n]+'), ' ').trim()}\r\n',
        ),
      );
    }

    field('name', name);
    field('external_id', externalId);
    out.add(
      utf8.encode(
        '--$b\r\nContent-Disposition: form-data; name="file"; '
        'filename="${fileName.replaceAll('"', "'")}"\r\n'
        'Content-Type: $mimeType\r\n\r\n',
      ),
    );
    out.add(utf8.encode(fileText));
    out.add(utf8.encode('\r\n--$b--\r\n'));
    return IntervalsRequest(
      method: 'POST',
      uri: intervalsUri(c.athleteId, 'activities'),
      headers: {
        'Authorization': intervalsAuthHeader(c.apiKey),
        'Accept': 'application/json',
        'Content-Type': 'multipart/form-data; boundary=$b',
      },
      body: out.takeBytes(),
    );
  }

  Future<IntervalsOutcome> upload(
    IntervalsCredentials c, {
    required String name,
    required String externalId,
    required String fileName,
    required String fileText,
    required String mimeType,
  }) async {
    try {
      final res = await http.send(
        uploadRequest(
          c,
          name: name,
          externalId: externalId,
          fileName: fileName,
          fileText: fileText,
          mimeType: mimeType,
        ),
      );
      return mapUploadResponse(res);
    } on IntervalsNetworkError {
      return const IntervalsOutcome.failed('No network');
    }
  }

  /// One line for the Connect sheet.
  Future<({bool ok, String line})> test(IntervalsCredentials c) async {
    try {
      final res = await http.send(testRequest(c));
      if (res.status >= 200 && res.status < 300) {
        var who = '';
        try {
          final j = jsonDecode(res.body);
          if (j is Map && j['name'] is String) who = ' as ${j['name']}';
        } on FormatException {
          // The status alone proves the key.
        }
        return (ok: true, line: 'Connected$who');
      }
      if (res.status == 401 || res.status == 403) {
        return (ok: false, line: kKeyNotAccepted);
      }
      if (res.status == 404) return (ok: false, line: 'Athlete id not found');
      return (ok: false, line: 'Intervals.icu said no (${res.status})');
    } on IntervalsNetworkError {
      return (ok: false, line: 'No network. Try again');
    }
  }
}

class IntervalsIcuTarget extends ExportTarget with ChangeNotifier {
  IntervalsIcuTarget({required this.store, IntervalsHttp? http})
    : client = IntervalsIcuClient(http ?? const DartIoIntervalsHttp());

  static const String targetId = 'intervals_icu';
  static const String keyName = 'intervals_icu_api_key';
  static const String athleteName = 'intervals_icu_athlete_id';

  final SecretStore store;
  final IntervalsIcuClient client;

  bool _connected = false;

  /// A key is saved. Set by [load], [connect] and [disconnect].
  bool get connected => _connected;

  @override
  String get id => targetId;
  @override
  String get label => 'Intervals.icu';
  @override
  String get blurb => 'Sends the run to your Intervals.icu calendar';
  @override
  bool get supportsAutomatic => true;

  Future<IntervalsCredentials?> credentials() async {
    try {
      final key = await store.read(keyName);
      if (key == null || key.isEmpty) return null;
      return IntervalsCredentials(
        apiKey: key,
        athleteId: await store.read(athleteName) ?? '0',
      );
    } catch (e) {
      intervalsLog('could not read the key (${e.runtimeType})');
      return null;
    }
  }

  Future<void> load() async {
    final has = await credentials() != null;
    if (has != _connected) {
      _connected = has;
      notifyListeners();
    }
  }

  /// Saves the key. False when secure storage refuses.
  Future<bool> connect(IntervalsCredentials c) async {
    try {
      await store.write(keyName, c.apiKey);
      await store.write(athleteName, c.athleteId);
    } catch (e) {
      intervalsLog('could not save the key (${e.runtimeType})');
      return false;
    }
    _connected = true;
    notifyListeners();
    return true;
  }

  Future<void> disconnect() async {
    try {
      await store.delete(keyName);
      await store.delete(athleteName);
    } catch (e) {
      intervalsLog('could not remove the key (${e.runtimeType})');
    }
    _connected = false;
    notifyListeners();
  }

  @override
  Future<SendResult> send(SendRequest req) async {
    final c = await credentials();
    if (c == null) {
      return const SendResult.failed('Connect Intervals.icu in Settings');
    }
    try {
      final o = await client.upload(
        c,
        name: req.title,
        externalId: req.run.id,
        fileName: exportFileName(req.title, req.run.start, req.format),
        fileText: exportFileText(req),
        mimeType: req.format.mimeType,
      );
      if (!o.ok) intervalsLog('upload failed (${o.line})', secrets: [c.apiKey]);
      return o.ok ? const SendResult.ok() : SendResult.failed(o.line!);
    } catch (e) {
      intervalsLog('upload threw (${e.runtimeType})', secrets: [c.apiKey]);
      return const SendResult.failed('Could not send');
    }
  }
}
