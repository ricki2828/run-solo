import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/send_runs.dart';

import '../run_fixtures.dart';

const _key = 'sekret-key-8f3a91';

class _FakeHttp implements IntervalsHttp {
  _FakeHttp();
  IntervalsResponse Function(IntervalsRequest)? respond;
  Object? throws;
  final List<IntervalsRequest> sent = [];

  @override
  Future<IntervalsResponse> send(IntervalsRequest req) async {
    sent.add(req);
    if (throws != null) throw throws!;
    return respond?.call(req) ?? const IntervalsResponse(200, '{}');
  }
}

String _text(IntervalsRequest r) => utf8.decode(r.body!);

void main() {
  final start = DateTime.utc(2026, 10, 2, 6);
  const creds = IntervalsCredentials(apiKey: _key, athleteId: 'i123');

  group('request building', () {
    final client = IntervalsIcuClient(_FakeHttp(), boundary: () => 'BOUNDARY');

    test('basic auth is API_KEY:<key>', () {
      final r = client.testRequest(creds);
      expect(
        r.headers['Authorization'],
        'Basic ${base64.encode(utf8.encode('API_KEY:$_key'))}',
      );
      expect(r.method, 'GET');
      expect(r.uri.toString(), 'https://intervals.icu/api/v1/athlete/i123');
    });

    test('upload is a multipart POST with file, name and external_id', () {
      final r = client.uploadRequest(
        creds,
        name: 'Morning Norwegian 4x4',
        externalId: 'run-42',
        fileName: 'Run Supreme - Morning - 2026-10-02.tcx',
        fileText: '<TrainingCenterDatabase/>',
        mimeType: 'application/vnd.garmin.tcx+xml',
      );
      expect(r.method, 'POST');
      expect(
        r.uri.toString(),
        'https://intervals.icu/api/v1/athlete/i123/activities',
      );
      expect(
        r.headers['Content-Type'],
        'multipart/form-data; boundary=BOUNDARY',
      );
      final body = _text(r);
      expect(body, contains('name="external_id"\r\n\r\nrun-42\r\n'));
      expect(body, contains('name="name"\r\n\r\nMorning Norwegian 4x4\r\n'));
      expect(
        body,
        contains(
          'name="file"; filename="Run Supreme - Morning - 2026-10-02.tcx"',
        ),
      );
      expect(body, contains('Content-Type: application/vnd.garmin.tcx+xml'));
      expect(body, contains('<TrainingCenterDatabase/>'));
      expect(body, endsWith('--BOUNDARY--\r\n'));
      expect(body, isNot(contains(_key)));
    });

    test('line breaks in the title cannot break the multipart body', () {
      final r = client.uploadRequest(
        creds,
        name: 'Morning\r\n--BOUNDARY\r\nrun',
        externalId: 'run-1',
        fileName: 'a.tcx',
        fileText: '<x/>',
        mimeType: 'application/vnd.garmin.tcx+xml',
      );
      expect(
        _text(r),
        contains('name="name"\r\n\r\nMorning --BOUNDARY run\r\n'),
      );
      expect(RegExp('--BOUNDARY\r\n').allMatches(_text(r)).length, 3);
    });

    test('credentials never print the key', () {
      expect(creds.toString(), isNot(contains(_key)));
    });
  });

  group('response mapping', () {
    String? line(int s, [String body = '']) =>
        mapUploadResponse(IntervalsResponse(s, body)).line;
    bool ok(int s, [String body = '']) =>
        mapUploadResponse(IntervalsResponse(s, body)).ok;

    test('2xx is sent', () => expect(ok(200), isTrue));
    test('409 is sent as a duplicate', () {
      final o = mapUploadResponse(const IntervalsResponse(409));
      expect(o.ok, isTrue);
      expect(o.duplicate, isTrue);
    });
    test('a 4xx that says duplicate is sent', () {
      expect(ok(422, '{"error":"Duplicate activity"}'), isTrue);
    });
    test('401 and 403 are "Key not accepted"', () {
      expect(line(401), 'Key not accepted');
      expect(line(403), 'Key not accepted');
    });
    test('404, busy and other codes get a short line', () {
      expect(line(404), 'Athlete id not found');
      expect(line(429), 'Intervals.icu is busy');
      expect(line(503), 'Intervals.icu is busy');
      expect(line(400), 'Intervals.icu said no (400)');
    });
  });

  group('target', () {
    late MemorySecretStore store;
    late _FakeHttp http;
    late IntervalsIcuTarget target;
    final run = fourByFourFile(n: 1, start: start);
    final req = SendRequest(run: run, title: 'Morning 4x4');

    setUp(() {
      store = MemorySecretStore();
      http = _FakeHttp();
      target = IntervalsIcuTarget(store: store, http: http);
    });

    test('without a key it refuses and sends nothing', () async {
      final r = await target.send(req);
      expect(r.ok, isFalse);
      expect(r.error, 'Connect Intervals.icu in Settings');
      expect(http.sent, isEmpty);
    });

    test('connected: uploads the TCX with the run id as external_id', () async {
      await target.connect(creds);
      final r = await target.send(req);
      expect(r.ok, isTrue);
      final sent = http.sent.single;
      expect(sent.uri.path, '/api/v1/athlete/i123/activities');
      final body = _text(sent);
      expect(body, contains('name="external_id"\r\n\r\n${run.id}\r\n'));
      expect(body, contains('name="name"\r\n\r\nMorning 4x4\r\n'));
      expect(body, contains('<TrainingCenterDatabase'));
      expect(body, contains('.tcx"'));
    });

    test('401 maps to "Key not accepted"; 409 counts as sent', () async {
      await target.connect(creds);
      http.respond = (_) => const IntervalsResponse(401);
      expect((await target.send(req)).error, 'Key not accepted');
      http.respond = (_) => const IntervalsResponse(409);
      expect((await target.send(req)).ok, isTrue);
    });

    test('no network is a failed result, not a throw', () async {
      await target.connect(creds);
      http.throws = const IntervalsNetworkError();
      final r = await target.send(req);
      expect(r.ok, isFalse);
      expect(r.error, 'No network');
    });

    test('disconnect clears the stored key and id', () async {
      await target.connect(creds);
      expect(target.connected, isTrue);
      expect(store.values, isNotEmpty);
      await target.disconnect();
      expect(target.connected, isFalse);
      expect(store.values, isEmpty);
      expect((await target.send(req)).ok, isFalse);
    });

    test('load picks up a saved key', () async {
      await store.write(IntervalsIcuTarget.keyName, _key);
      await target.load();
      expect(target.connected, isTrue);
      expect((await target.credentials())!.athleteId, '0');
    });

    test('test connection reports success and failure', () async {
      http.respond = (_) => const IntervalsResponse(200, '{"name":"Ricki"}');
      expect((await target.client.test(creds)).line, 'Connected as Ricki');
      http.respond = (_) => const IntervalsResponse(403);
      final bad = await target.client.test(creds);
      expect(bad.ok, isFalse);
      expect(bad.line, 'Key not accepted');
      http.throws = const IntervalsNetworkError();
      expect((await target.client.test(creds)).ok, isFalse);
    });
  });

  group('credentials input', () {
    test('trims, defaults the athlete to 0, rejects spaces', () {
      final p = parseCredentials('  abc123 ', '');
      expect(p.creds!.apiKey, 'abc123');
      expect(p.creds!.athleteId, '0');
      expect(parseCredentials('', '').error, isNotNull);
      expect(parseCredentials('ab cd', '').error, isNotNull);
      expect(parseCredentials('abc', 'i1/2').error, isNotNull);
    });
  });

  group('the key never reaches the log', () {
    late List<String?> lines;
    late DebugPrintCallback original;

    setUp(() {
      lines = [];
      original = debugPrint;
      debugPrint = (m, {wrapWidth}) => lines.add(m);
    });
    tearDown(() => debugPrint = original);

    test('intervalsLog blanks any secret it is given', () {
      intervalsLog('boom with $_key inside', secrets: [_key]);
      expect(lines.join(), isNot(contains(_key)));
      expect(lines.join(), contains('***'));
    });

    test('failed sends and a throwing store log no key', () async {
      final http = _FakeHttp();
      final store = MemorySecretStore();
      final target = IntervalsIcuTarget(store: store, http: http);
      await target.connect(creds);
      final run = fourByFourFile(n: 1, start: DateTime.utc(2026, 10, 2, 6));
      final req = SendRequest(run: run, title: 'x');
      http.respond = (_) => const IntervalsResponse(401, 'bad key $_key');
      await target.send(req);
      http.respond = (_) => throw StateError('request had $_key in it');
      await target.send(req);
      http.throws = const IntervalsNetworkError();
      await target.send(req);
      expect(lines, isNotEmpty);
      expect(lines.join('\n'), isNot(contains(_key)));
    });
  });
}
