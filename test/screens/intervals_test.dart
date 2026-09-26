import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/custom_builder_screen.dart';
import 'package:run_solo/screens/intervals_sheet.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/sessions.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/value_stepper.dart';

import '../helpers.dart';

Finder stepperButton(String label, IconData icon) => find.descendant(
  of: find.widgetWithText(ValueStepper, label.toUpperCase()),
  matching: find.byIcon(icon),
);

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.text('INTERVALS'));
  await pumpTimes(tester, 6);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.descendant(
      of: find.byType(IntervalsSheet),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'INTERVALS opens the sheet: last used, the eight, fartlek, build',
    (tester) async {
      final services = fakeServices();
      await pumpApp(tester, services, pushRoute: Routes.start);
      await pumpTimes(tester, 4);
      await openSheet(tester);

      expect(find.byType(IntervalsSheet), findsOneWidget);
      expect(find.text('LAST USED'), findsOneWidget);
      // Last used is the 4x4, so Popular lists the other seven.
      expect(find.byKey(const ValueKey('sheet-norwegian-4x4')), findsOneWidget);
      for (final p in engine.SessionCatalogue.presets) {
        await scrollTo(tester, find.byKey(ValueKey('sheet-${p.id}')));
        expect(find.byKey(ValueKey('sheet-${p.id}')), findsOneWidget);
      }
      await scrollTo(tester, find.byKey(const ValueKey('sheet-fartlek')));
      await scrollTo(tester, find.byKey(const ValueKey('sheet-build')));
      expect(find.text('+ BUILD YOUR OWN'), findsOneWidget);
    },
  );

  testWidgets(
    'picking 8 × 400 m: card with reps 4–12, recovery by metres or time, GPS note',
    (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(recorder: fake);
      await pumpApp(tester, services, pushRoute: Routes.start);
      await pumpTimes(tester, 4);
      await openSheet(tester);
      await scrollTo(tester, find.byKey(const ValueKey('sheet-400s')));
      await tester.tap(find.byKey(const ValueKey('sheet-400s')));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 400));

      expect(services.settings.settings.sessionId, '400s');
      expect(find.text('8 × 400 M'), findsOneWidget);
      expect(find.text('8 × 400 m · 200 m jog'), findsOneWidget);
      expect(find.byKey(const ValueKey('session-gps-note')), findsOneWidget);

      // C1b's TESTS chip makes Start taller: bring the steppers on stage.
      await tester.ensureVisible(stepperButton('Reps', Icons.add));
      await tester.pump();
      await tester.tap(stepperButton('Reps', Icons.add));
      await pumpTimes(tester);
      expect(find.text('9 × 400 M'), findsOneWidget);
      await tester.ensureVisible(stepperButton('Recovery', Icons.add));
      await tester.pump();
      await tester.tap(stepperButton('Recovery', Icons.add));
      await pumpTimes(tester);
      expect(find.text('250 m'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('choice-Time')));
      await pumpTimes(tester);
      expect(find.text('1:30'), findsOneWidget);
      expect(services.settings.settings.presetEdits['400s']!.reps, 9);

      await tester.ensureVisible(find.text('START WARM-UP'));
      await tester.tap(find.text('START WARM-UP'));
      await pumpTimes(tester, 6);
      final sent = fake.startCalls.single;
      expect(sent.mode, RecordMode.intervals);
      expect(sent.spec!.templateId, '400s');
      expect(
        sent.spec!.steps.where((s) => s.kind == StepKind.work),
        hasLength(9),
      );
      expect(sent.spec!.steps[1].target, TargetKind.time);
      expect(sent.spec!.steps[1].value, 90);
      expect(find.byType(RecordingScreen), findsOneWidget);
    },
  );

  testWidgets('fartlek starts a Laps run carrying the fartlek session', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(onboardingDone: true, sessionId: 'fartlek'),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    expect(find.byType(ValueStepper), findsNothing);
    await tester.tap(find.text('START FARTLEK'));
    await pumpTimes(tester, 6);
    final sent = fake.startCalls.single;
    expect(sent.mode, RecordMode.laps);
    expect(sent.spec!.templateId, 'fartlek');
    expect(find.text('EASY · LAP TO SURGE'), findsOneWidget);
    await fake.lap(LapSource.button);
    await pumpTimes(tester, 4);
    expect(find.text('SURGE 1'), findsOneWidget);
    await fake.lap(LapSource.button);
    await pumpTimes(tester, 4);
    expect(find.text('EASY 1'), findsOneWidget);
  });

  testWidgets('Save as custom: builder pre-filled, saved, picked, listed', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(onboardingDone: true, reps: 5),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tester.ensureVisible(
      find.byKey(const ValueKey('session-save-custom')),
    );
    await tester.pump(); // lay out the scroll before hit-testing the tap
    await tester.tap(find.byKey(const ValueKey('session-save-custom')));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CustomBuilderScreen), findsOneWidget);
    expect(find.text('5 × 4:00 · 3:00 JOG'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('builder-save')));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    final saved = services.sessions.sessions.single;
    expect(services.settings.settings.sessionId, saved.templateId);
    expect(saved.expand().comparisonKey, 't240x*');
    expect(find.byType(CustomBuilderScreen), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('session-name'))).data,
      '5 × 4:00 · 3:00 JOG',
    );
  });

  testWidgets('builder: walk and stand recoveries are timed only', (
    tester,
  ) async {
    BuilderResult? result;
    await pumpApp(
      tester,
      fakeServices(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await Navigator.of(context).push<BuilderResult>(
              MaterialPageRoute(
                builder: (_) => const CustomBuilderScreen(
                  initial: CustomSession(
                    id: 'n',
                    name: '',
                    recoveryTarget: RecoveryTarget.distance,
                    recoveryValue: 200,
                  ),
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(
      find.byKey(const ValueKey('seg-Recovery style-Stand')),
    );
    await tester.tap(find.byKey(const ValueKey('seg-Recovery style-Stand')));
    await pumpTimes(tester);
    expect(find.text('Walk and stand recoveries are timed.'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('builder-save-start')),
    );
    await tester.tap(find.byKey(const ValueKey('builder-save-start')));
    await pumpTimes(tester, 6);
    expect(result!.start, isTrue);
    expect(result!.session.recoveryTarget, RecoveryTarget.time);
    expect(result!.session.recoveryStyle, engine.RecoveryStyle.stand);
    expect(result!.session.validate(), isEmpty);
  });

  testWidgets('my sessions: long-press delete removes the template', (
    tester,
  ) async {
    final services = fakeServices(
      customSessions: [
        CustomSession(
          id: 'aa',
          name: 'Hills',
          createdAt: DateTime.utc(2026, 9, 20),
        ),
      ],
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await openSheet(tester);
    await scrollTo(tester, find.byKey(const ValueKey('sheet-custom:aa')));
    await tester.longPress(find.byKey(const ValueKey('sheet-custom:aa')));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('custom-delete')));
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 400));
    expect(services.sessions.sessions, isEmpty);
    expect(find.byKey(const ValueKey('sheet-custom:aa')), findsNothing);
  });

  group('record screen, distance session', () {
    Future<FakeRecorderGateway> startFourHundreds(
      WidgetTester tester, {
      bool gpsLost = false,
    }) async {
      final fake = FakeRecorderGateway(now: now)..gpsLost = gpsLost;
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.intervals,
        presetSpec('400s'),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      return fake;
    }

    testWidgets('START REPS waits for a GPS fix (W3)', (tester) async {
      final fake = await startFourHundreds(tester, gpsLost: true);
      expect(find.byKey(const ValueKey('start-reps-waiting')), findsOneWidget);
      expect(
        find.text('Distance reps need GPS. Wait for a fix to start reps.'),
        findsOneWidget,
      );
      fake.gpsLost = false;
      fake.advance(const Duration(seconds: 1));
      await pumpTimes(tester, 4);
      expect(find.byKey(const ValueKey('start-reps')), findsOneWidget);
    });

    testWidgets(
      'rep: metres to go under the rep average; recovery: metres to the next rep',
      (tester) async {
        final fake = await startFourHundreds(tester);
        await fake.startReps();
        await pumpTimes(tester, 4);
        expect(find.text('REP 1 OF 8 · 400 M'), findsOneWidget);
        // 285 s/km: 60 s covers 210.5 m, so 189.5 m left → "180 m".
        for (var i = 0; i < 60; i++) {
          fake.advance(const Duration(seconds: 1));
          await tester.pump();
        }
        await pumpTimes(tester, 4);
        expect(find.text('180 m'), findsOneWidget);
        expect(find.text('to go'), findsOneWidget);
        // The rest of the 400 m (114 s in all), then ~26 s into the 200 m
        // recovery (57 s at this pace).
        for (var i = 0; i < 80; i++) {
          fake.advance(const Duration(seconds: 1));
          await tester.pump();
        }
        await pumpTimes(tester, 4);
        expect(find.text('RECOVERY 1 OF 7 · 200 M'), findsOneWidget);
        expect(find.text('to rep 2'), findsOneWidget);
      },
    );

    testWidgets('END REP after GPS is lost for > 10 s ends the step', (
      tester,
    ) async {
      final fake = await startFourHundreds(tester);
      await fake.startReps();
      await pumpTimes(tester, 4);
      fake.gpsLost = true;
      for (var i = 0; i < 12; i++) {
        fake.advance(const Duration(seconds: 1));
        await tester.pump();
      }
      await pumpTimes(tester, 4);
      expect(find.byKey(const ValueKey('end-rep')), findsOneWidget);
      expect(
        find.text('GPS lost. Tap END REP at the end of the rep.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('end-rep')));
      await pumpTimes(tester, 6);
      expect(fake.phase, Phase.recovery);
    });
  });

  testWidgets(
    'short reps: the rep average waits for 20 m, HR shows the rep max',
    (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.intervals,
        presetSpec('30-30s'),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      await fake.startReps();
      await pumpTimes(tester, 4);
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 4);
      expect(find.text('REP 1 OF 20 · 0:30'), findsOneWidget);
      expect(find.text('REP MAX HR'), findsOneWidget);
    },
  );
}
