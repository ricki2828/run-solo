import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/goal_picker.dart';

import '../helpers.dart';

/// G3 (plan §G, A8): every GOAL option on Start runs G1's spec, Custom
/// distance and time, the GPS gate's reason above START, and the goal
/// record screens (before, last stretch, cool-down).
void main() {
  Future<FakeRecorderGateway> openGoal(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(
      onboardingDone: true,
      goalRun: true,
    ),
  }) async {
    final fake = FakeRecorderGateway(now: now);
    await pumpApp(
      tester,
      fakeServices(recorder: fake, settings: settings),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 4);
    return fake;
  }

  Future<void> ready(WidgetTester tester, FakeRecorderGateway fake) async {
    fake.emitGpsProbe(GpsProbeEvent(fix: true, accuracyM: 5));
    await pumpTimes(tester, 2);
  }

  testWidgets('each standard goal starts G1\'s spec with its catalogue name', (
    tester,
  ) async {
    final cases = {
      'd5000': (engine.TargetKind.distance, 5000, '5K'),
      'd10000': (engine.TargetKind.distance, 10000, '10K'),
      'd21098': (engine.TargetKind.distance, 21098, 'Half'),
      'd42195': (engine.TargetKind.distance, 42195, 'Marathon'),
      't1800': (engine.TargetKind.time, 1800, '30 min'),
      't3600': (engine.TargetKind.time, 3600, '1 hour'),
    };
    for (final MapEntry(key: id, value: (kind, value, label))
        in cases.entries) {
      final fake = await openGoal(
        tester,
        settings: AppSettings(onboardingDone: true, goalRun: true, goalId: id),
      );
      await ready(tester, fake);
      await tester.tap(find.text('START GOAL'));
      await pumpTimes(tester, 6);
      final spec = fake.startCalls.single.spec!;
      expect(spec.templateId, engine.SessionSpec.goalId, reason: id);
      expect(spec.name, label);
      expect(spec.warmupSeconds, 0);
      expect(spec.autoStop, isNot(isTrue), reason: 'open cool-down');
      expect(spec.steps, hasLength(1));
      expect(spec.steps.single.value, value);
      expect(
        spec.steps.single.target.name,
        kind.name,
        reason: '$id is a ${kind.name} goal',
      );
      expect(fake.startCalls.single.mode, RecordMode.intervals);
    }
  });

  testWidgets('Custom distance: the sheet takes km to 0.1; the chip, the card '
      'and the spec follow', (tester) async {
    final fake = await openGoal(tester);
    await tester.tap(find.byKey(const ValueKey('goal-dcustom')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('goal-custom-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('goal-custom-field')),
      '200',
    );
    await tester.tap(find.byKey(const ValueKey('goal-custom-save')));
    await pumpTimes(tester, 2);
    expect(find.text('Pick 0.1 to 100 km.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('goal-custom-field')),
      '12,34',
    );
    await tester.tap(find.byKey(const ValueKey('goal-custom-save')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Custom'), findsNothing);
    expect(find.text('12.3 km'), findsNWidgets(2), reason: 'chip + GOAL');
    await ready(tester, fake);
    await tester.tap(find.text('START GOAL'));
    await pumpTimes(tester, 6);
    final spec = fake.startCalls.single.spec!;
    expect(spec.steps.single.value, 12300);
    expect(spec.name, '12.3 km');
  });

  testWidgets('Custom distance in miles: entered, shown and named in miles, '
      'stored and run in metres', (tester) async {
    final fake = await openGoal(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        goalRun: true,
        units: Units.mi,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('goal-dcustom')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('mi'), findsOneWidget, reason: 'field suffix');
    await tester.enterText(
      find.byKey(const ValueKey('goal-custom-field')),
      '7.5',
    );
    await tester.tap(find.byKey(const ValueKey('goal-custom-save')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('7.5 mi'), findsNWidgets(2), reason: 'chip + GOAL');
    await ready(tester, fake);
    await tester.tap(find.text('START GOAL'));
    await pumpTimes(tester, 6);
    final spec = fake.startCalls.single.spec!;
    expect(spec.steps.single.value, 12070);
    expect(spec.name, '7.5 mi');
    expect(
      engine.ComparisonKey.of(spec.toEngine()),
      'goal:d12070',
      reason: 'its own board, not 12.1 km\'s',
    );
  });

  testWidgets('Custom time: 1 h and 15 min fields make 75 minutes', (
    tester,
  ) async {
    final fake = await openGoal(
      tester,
      settings: const AppSettings(
        onboardingDone: true,
        goalRun: true,
        goalId: 't1800',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('goal-tcustom')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const ValueKey('goal-custom-hours')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('goal-custom-minutes')),
      '15',
    );
    await tester.tap(find.byKey(const ValueKey('goal-custom-save')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 400));
    await ready(tester, fake);
    await tester.tap(find.text('START GOAL'));
    await pumpTimes(tester, 6);
    final spec = fake.startCalls.single.spec!;
    expect(spec.steps.single.value, 4500);
    expect(spec.name, '1 h 15 min');
  });

  testWidgets('360 x 640: the GPS reason sits right above the greyed START, '
      'on screen without scrolling (#53 P2)', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
    await openGoal(tester);
    tester.view.physicalSize = const Size(1080, 1920);
    await pumpTimes(tester, 4);
    final gps = find.byKey(const ValueKey('event-gps'));
    expect(gps.hitTestable(), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'START 5 KM');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    final gpsBox = tester.getRect(gps);
    final btnBox = tester.getRect(button);
    expect(gpsBox.bottom, lessThanOrEqualTo(btnBox.top));
    expect(btnBox.top - gpsBox.bottom, lessThan(32));
    expect(gpsBox.bottom, lessThanOrEqualTo(640));
  });

  test('custom entry parsing and limits', () {
    expect(parseGoalDistance('12.34', Units.km), 12300);
    expect(parseGoalDistance('12,36', Units.km), 12400);
    expect(parseGoalDistance('0.1', Units.km), 100);
    expect(parseGoalDistance('0.04', Units.km), isNull);
    expect(parseGoalDistance('100', Units.km), 100000);
    expect(parseGoalDistance('100.1', Units.km), isNull);
    expect(parseGoalDistance('x', Units.km), isNull);
    expect(parseGoalDistance('7.5', Units.mi), 12070);
    expect(parseGoalDistance('7.46', Units.mi), 12070, reason: 'to 0.1 mi');
    expect(parseGoalDistance('62.1', Units.mi), 99940);
    expect(parseGoalDistance('62.2', Units.mi), isNull);
    expect(parseGoalHoursMinutes('', '45'), 2700);
    expect(parseGoalHoursMinutes('1', '15'), 4500);
    expect(parseGoalHoursMinutes('1', ''), 3600);
    expect(parseGoalHoursMinutes('1', '75'), isNull);
    expect(parseGoalHoursMinutes('', '0'), isNull);
    expect(parseGoalHoursMinutes('24', '0'), 86400);
    expect(parseGoalHoursMinutes('24', '1'), isNull);
    expect(parseGoalHoursMinutes('x', '5'), isNull);
  });

  test('settings keep the custom values, clamped to the engine limits', () {
    const s = AppSettings(goalCustomMetres: 12300, goalCustomSeconds: 4500);
    final back = AppSettings.fromJson(s.toJson());
    expect(back.goalCustomMetres, 12300);
    expect(back.goalCustomSeconds, 4500);
    final wild = AppSettings.fromJson({
      ...s.toJson(),
      'goalCustomMetres': 12345678,
      'goalCustomSeconds': 5,
    });
    expect(wild.goalCustomMetres, engine.SessionSpec.goalMaxMetres);
    expect(wild.goalCustomSeconds, engine.SessionSpec.goalMinSeconds);
    expect(
      const AppSettings(goalRun: true, goalId: 'dcustom').goalSpec('x')!.name,
      '12.0 km',
    );
  });

  test('no END REP on a goal or the event, however long GPS is gone '
      '(#75 P2)', () {
    RecordingSnapshot lost(engine.SessionSpec spec) => RecordingSnapshot(
      state: RecorderState.recording,
      mode: RecordMode.intervals,
      spec: spec.toPigeon(),
      phase: Phase.work,
      repIndex: 1,
      stepIndex: 0,
      elapsedMs: 120000,
      gpsLost: true,
      gpsBadSinceMs: 60000,
    );
    expect(
      lost(engine.SessionSpec.goalDistance(21098, 'Half')).showEndRep,
      isFalse,
    );
    expect(lost(engine.SessionSpec.parkrun('x')).showEndRep, isFalse);
    // A distance-rep session still gets it.
    final reps = engine.SessionCatalogue.expand('400s');
    expect(lost(reps).showEndRep, isTrue);
  });

  group('record', () {
    double size(WidgetTester tester, String key) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey(key)),
                matching: find.byType(Text),
              )
              .first,
        )
        .style!
        .fontSize!;

    testWidgets('time goal: time to go primary, distance on pace second; the '
        'last minute swaps; after the goal the cool-down with the locked '
        'distance', (tester) async {
      final fake = FakeRecorderGateway(now: now)..liveSecPerKm = 240;
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.goalTime(1800, '30 min').toPigeon(),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      expect(find.text('GOAL · 30 MIN'), findsOneWidget);
      expect(find.text('30:00'), findsOneWidget);
      // 5 min at 240 s/km: 1.25 km, so 7.50 km at 30 min.
      for (var i = 0; i < 300; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 4);
      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('7.50 km'), findsOneWidget);
      expect(
        size(tester, 'event-to-go'),
        greaterThan(size(tester, 'event-finish')),
      );
      for (var i = 0; i < 1450; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 4);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('GOAL · LAST MINUTE'), findsOneWidget);
      expect(
        size(tester, 'event-finish'),
        greaterThan(size(tester, 'event-to-go')),
      );
      for (var i = 0; i < 70; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 6);
      expect(find.text('COOL-DOWN · 30 MIN DONE'), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-done')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('goal-result'))).data,
        '7.50 km',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('goal-cooldown')))
            .style!
            .fontSize!,
        greaterThan(
          tester
              .widget<Text>(find.byKey(const ValueKey('goal-result')))
              .style!
              .fontSize!,
        ),
      );
    });

    testWidgets('distance goal: to go and on pace, then the cool-down locks '
        'the goal time', (tester) async {
      final fake = FakeRecorderGateway(now: now)..liveSecPerKm = 240;
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.goalDistance(10000, '10K').toPigeon(),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      expect(find.text('GOAL · 10K'), findsOneWidget);
      expect(find.text('10.00 km'), findsOneWidget);
      for (var i = 0; i < 60; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 4);
      expect(find.text('9.75 km'), findsOneWidget);
      expect(find.text('40:00'), findsOneWidget);
      for (var i = 0; i < 2400; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 6);
      expect(find.text('COOL-DOWN · 10K DONE'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('goal-result'))).data,
        '40:00',
      );
    });
  });
}
