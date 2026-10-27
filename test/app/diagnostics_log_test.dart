import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/diagnostics_log.dart';
import 'package:run_solo/platform/fake_gateway.dart';
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
      addTearDown(() {
        ErrorWidget.builder = oldBuilder;
        FlutterError.onError = oldOnError;
        PlatformDispatcher.instance.onError = oldDispatch;
      });
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
      final shared = transfer.nextShare();
      await tester.tap(row);
      final paths = await tester.runAsync(
        () => shared.timeout(const Duration(seconds: 5)),
      );
      final body = File(paths!.single).readAsStringSync();
      expect(body, contains('build=abc123'));
      expect(body, contains('earlier'));
    },
  );
}
