import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/diagnostics_log.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/settings_screen.dart';

import '../helpers.dart';

void main() {
  late Directory tmp;
  late DiagnosticsLog log;
  var clock = DateTime.utc(2026, 10, 27, 8);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('diag_test');
    clock = DateTime.utc(2026, 10, 27, 8);
    log = DiagnosticsLog(
      Directory('${tmp.path}/files/diagnostics'),
      version: '0.1.0+4',
      buildSha: 'abc123',
      now: () => clock,
      maxFileBytes: 400,
    );
  });

  tearDown(() {
    DiagnosticsLog.instance = null;
    tmp.deleteSync(recursive: true);
  });

  test('an entry carries version, build, time, error and stack', () {
    log.record(StateError('bad'), StackTrace.fromString('#0 main (a.dart:1)'));
    final text = File('${log.dir.path}/${DiagnosticsLog.currentName}')
        .readAsStringSync();
    expect(text, contains('2026-10-27T08:00:00.000Z'));
    expect(text, contains('app=0.1.0+4 build=abc123'));
    expect(text, contains('Bad state: bad'));
    expect(text, contains('#0 main (a.dart:1)'));
  });

  test('rotation keeps two files and drops the oldest', () {
    for (var i = 0; i < 12; i++) {
      log.record('entry-$i ${'x ' * 30}', null);
    }
    final cur = File('${log.dir.path}/${DiagnosticsLog.currentName}');
    final prev = File('${log.dir.path}/${DiagnosticsLog.previousName}');
    expect(prev.existsSync(), isTrue);
    expect(cur.lengthSync(), lessThan(400 + 200));
    expect(prev.lengthSync(), lessThan(400 + 200));
    final all = cur.readAsStringSync() + prev.readAsStringSync();
    expect(all, contains('entry-11'));
    expect(all, isNot(contains('entry-0 ')));
    expect(log.dir.listSync().length, 2);
  });

  test('coordinates and secrets are redacted', () {
    final out = DiagnosticsLog.redact(
      'lat: 51.507412 lng=-0.127812 "longitude":-0.12 pair 51.50741, -0.12781 '
      'Authorization: Bearer abc.def-123 token=sekrit api_key: "k1" '
      'jwt ${'A' * 40} kept: segment 12',
    );
    expect(out, isNot(contains('51.507412')));
    expect(out, isNot(contains('-0.127812')));
    expect(out, isNot(contains('51.50741')));
    expect(out, isNot(contains('abc.def')));
    expect(out, isNot(contains('sekrit')));
    expect(out, isNot(contains('k1')));
    expect(out, isNot(contains('A' * 40)));
    expect(out, contains('kept: segment 12'));
  });

  test('emails, ids and looser coordinate formats are redacted', () {
    final out = DiagnosticsLog.redact(
      'mail ricki@example.com chat_id=123456789 runner_id: u_ab12cd '
      'LatLng(51.5, -0.12) lat 51.5 and 51.507412 -0.127812 plain 3.14',
    );
    for (final leaked in [
      'ricki@example.com',
      '123456789',
      'ab12cd',
      '51.5',
      '-0.12',
      '51.507412',
      '-0.127812',
    ]) {
      expect(out, isNot(contains(leaked)), reason: leaked);
    }
    expect(out, contains('plain 3.14'));
  });

  test('one entry is size-capped', () {
    log.record('e ${'word ' * 5000}', StackTrace.fromString('s ' * 9000));
    final text = File('${log.dir.path}/${DiagnosticsLog.currentName}')
        .readAsStringSync();
    expect(text.length, lessThan(13 * 1024));
    expect(text, contains('(truncated)'));
  });

  test('the same error again within a minute is counted, not rewritten', () {
    final st = StackTrace.fromString('#0 loop (a.dart:1)');
    log.record('tick failed', st);
    final cur = File('${log.dir.path}/${DiagnosticsLog.currentName}');
    final once = cur.lengthSync();
    for (var i = 0; i < 50; i++) {
      clock = clock.add(const Duration(milliseconds: 500));
      log.record('tick failed', st);
    }
    expect(cur.lengthSync(), once);
    clock = clock.add(const Duration(seconds: 30));
    log.record('different', st);
    final text = cur.readAsStringSync();
    expect(text, contains('(previous entry repeated 50 times)'));
    expect(text, contains('different'));
  });

  test(
    'when the dir is unusable entries are kept in memory for the bundle',
    () async {
      final bad = DiagnosticsLog(
        Directory('/proc/nope/diag'),
        buildSha: 'zzz',
        now: () => clock,
      );
      bad.record('kept in memory', null);
      final file = await bad.writeBundle(Directory('${tmp.path}/out'));
      expect(file!.readAsStringSync(), contains('kept in memory'));
    },
  );

  test('the bundle redacts the native crash log too', () async {
    File('${log.dir.path}/${DiagnosticsLog.nativeCrashName}')
      ..createSync(recursive: true)
      ..writeAsStringSync('IllegalArgumentException: bad lat=51.5074 u@x.com');
    final file = await log.writeBundle(Directory('${tmp.path}/out'));
    final body = file!.readAsStringSync();
    expect(body, contains('IllegalArgumentException'));
    expect(body, isNot(contains('51.5074')));
    expect(body, isNot(contains('u@x.com')));
  });

  test('record never throws, even when the dir cannot be created', () {
    final bad = DiagnosticsLog(Directory('/proc/nope/diag'));
    expect(() => bad.record('x', null), returnsNormally);
  });

  testWidgets(
    'a widget that throws in build is logged and shows the calm screen',
    (tester) async {
      final oldBuilder = ErrorWidget.builder;
      final oldOnError = FlutterError.onError;
      final oldDispatch = PlatformDispatcher.instance.onError;
      try {
        log.install(calmScreen: true);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(builder: (_) => throw StateError('build exploded')),
          ),
        );
        expect(tester.takeException(), isNotNull);
        expect(find.text('SOMETHING BROKE'), findsOneWidget);
        expect(find.textContaining('The run is safe'), findsOneWidget);
        final text = File('${log.dir.path}/${DiagnosticsLog.currentName}')
            .readAsStringSync();
        expect(text, contains('build exploded'));
        expect(text, contains(' flutter '));
      } finally {
        ErrorWidget.builder = oldBuilder;
        FlutterError.onError = oldOnError;
        PlatformDispatcher.instance.onError = oldDispatch;
      }
    },
  );

  testWidgets(
    'Settings → About → Share diagnostics hands a bundle to the share sheet',
    (tester) async {
      log.record(StateError('earlier'), null);
      DiagnosticsLog.instance = log;
      final transfer = FakeTransferGateway();
      await pumpApp(
        tester,
        fakeServices(transfer: transfer),
        home: SettingsScreen(now: now),
      );
      await pumpTimes(tester, 3);
      final row = find.text('Share diagnostics');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('diagnostics-line')), findsOneWidget);
      await tester.tap(row);
      // File I/O completes on the real event loop; keep pumping the fake one.
      for (var i = 0; i < 100 && transfer.shared.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(transfer.shared, hasLength(1));
      final paths = transfer.shared.single;
      final body = File(paths.single).readAsStringSync();
      expect(body, contains('build=abc123'));
      expect(body, contains('earlier'));
    },
  );

  testWidgets('a share sheet that cannot open shows a toast, not an error', (
    tester,
  ) async {
    DiagnosticsLog.instance = log;
    final transfer = FakeTransferGateway()..failShare = true;
    await pumpApp(
      tester,
      fakeServices(transfer: transfer),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    final row = find.text('Share diagnostics');
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(row);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.text('Could not open the share sheet.').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text('Could not open the share sheet.'), findsOneWidget);
  });
}
