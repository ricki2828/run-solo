import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/bronco_result_screen.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Bronco (manual sets, founder 28-Sep): the inline instructions, the
/// laps run carrying the bronco spec, SET n OF 5, the self-ending 5th
/// set, and its result screen. Time only - Cooper stays the measure.
void main() {
  testWidgets('TESTS run type: bronco instructions, START BRONCO starts a '
      'Laps run carrying the bronco session', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    // TESTS is a run type in the mode row (founder 28-Sep).
    await tapVisible(tester, find.byKey(const ValueKey('tests-chip')));
    await tester.pumpAndSettle();
    // Cooper stays the default pick, health note on screen before any start.
    expect(find.byKey(const ValueKey('pick-cooper')), findsOneWidget);
    expect(find.textContaining('check with a doctor'), findsOneWidget);
    expect(fake.startCalls, isEmpty, reason: 'the chip alone never starts');
    // His one ask: clear instructions for how to run the test.
    await tapVisible(tester, find.byKey(const ValueKey('pick-bronco')));
    await tester.pumpAndSettle();
    expect(find.textContaining('5 sets of 240 m shuttles'), findsOneWidget);
    expect(
      find.textContaining('Tap LAP at the end of each set'),
      findsOneWidget,
    );
    await tester.tap(find.text('START BRONCO'));
    await pumpTimes(tester, 6);
    final sent = fake.startCalls.single;
    expect(sent.mode, RecordMode.laps);
    expect(sent.spec!.templateId, 'bronco');
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets('recording: SET n OF 5; the 5th LAP pauses into SAVE', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.laps,
      engine.SessionSpec.bronco.toPigeon(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    expect(find.text('SET 1 OF 5'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await fake.lap(LapSource.button);
      await pumpTimes(tester, 4);
    }
    expect(find.text('SET 5 OF 5'), findsOneWidget);
    // The 5th set's tap ends the test itself: paused into the finish
    // flow, SAVE keeps it.
    await tester.tap(find.byType(LapButton));
    await pumpTimes(tester, 6);
    expect(find.text('SAVE'), findsOneWidget);
  });

  testWidgets('a bronco run shows its result, not the laps summary', (
    tester,
  ) async {
    final run = broncoRunFile(n: 1, start: DateTime.utc(2026, 9, 20, 6));
    await pumpApp(
      tester,
      fakeServices(files: [run]),
      pushRoute: Routes.verdict,
      pushArguments: run.id,
    );
    await pumpTimes(tester, 6);
    expect(find.byType(VerdictScreen), findsOneWidget);
    expect(find.byType(BroncoResultScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('bronco-total')), findsOneWidget);
    expect(find.byKey(const ValueKey('bronco-set-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('bronco-set-5')), findsOneWidget);
    expect(find.text('SET 3'), findsOneWidget);
  });

  testWidgets('history tags the run BRN with the session name', (tester) async {
    final run = broncoRunFile(n: 7, start: DateTime.utc(2026, 9, 21, 6));
    await pumpApp(
      tester,
      fakeServices(files: [run]),
      home: const HistoryScreen(),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester, 2);
    expect(find.text('BRN'), findsOneWidget);
  });

  test('result maths: first five manual taps, total is their sum', () {
    lap(int i, int t0, int t1) => engine.Lap(
      index: i,
      t0Ms: t0,
      t1Ms: t1,
      d0M: 0,
      d1M: 240,
      kind: engine.LapKind.manual,
    );
    final run = broncoRunFile(n: 2, start: DateTime.utc(2026, 9, 20, 6));
    final sets = BroncoResultScreen.setsOf(run);
    expect(sets, hasLength(5));
    expect(
      BroncoResultScreen.totalMsOf(sets),
      sets.fold<int>(0, (a, l) => a + l.durationMs),
    );
    // A pause book-keeping lap never counts as a set.
    final withPause = engine.RunFile(
      id: run.id,
      device: run.device,
      app: run.app,
      start: run.start,
      end: run.end,
      tz: run.tz,
      mode: engine.RunMode.laps,
      session: engine.SessionSpec.bronco,
      units: engine.Units.km,
      samples: const [],
      laps: [
        lap(1, 0, 60000),
        engine.Lap(
          index: 2,
          t0Ms: 60000,
          t1Ms: 70000,
          d0M: 0,
          d1M: 0,
          kind: engine.LapKind.pause,
        ),
        lap(3, 70000, 130000),
      ],
    );
    expect(BroncoResultScreen.setsOf(withPause), hasLength(2));
  });
}
