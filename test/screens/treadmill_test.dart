import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/gps_bar.dart';

import '../helpers.dart';

void main() {
  testWidgets('treadmill Ready has no GPS probe, warning or fix gate', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
        countdownSeconds: 0,
      ),
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    expect(find.text('TREADMILL'), findsOneWidget);
    expect(fake.gpsProbeRunning, isFalse);
    expect(find.byKey(const ValueKey('ready-gps')), findsNothing);
    expect(find.byKey(const ValueKey('ready-gps-warning')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ready-start')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpTimes(tester, 8);
    expect((await fake.status()).mode, RecordMode.treadmill);
    await fake.discard();
  });

  testWidgets(
    'treadmill times and records HR, validates finish distance before saving',
    (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.treadmill,
        ),
      );
      await services.recording.start(RecordMode.treadmill, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      fake.advance(const Duration(minutes: 10));
      await pumpTimes(tester, 5);
      expect(find.byKey(const ValueKey('treadmill-time')), findsOneWidget);
      expect(find.byType(GpsBar), findsNothing);
      expect(services.recording.snapshot.gpsLost, isFalse);
      expect(services.recording.snapshot.hr, isNotNull);
      expect(services.recording.snapshot.totalDistanceM, 0);
      await tester.tap(find.byKey(const ValueKey('stop')));
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('finish-save')));
      await pumpTimes(tester, 4);
      await tester.enterText(
        find.byKey(const ValueKey('treadmill-distance')),
        'NaN',
      );
      await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
      await tester.pump();
      expect(fake.finalised, isEmpty);
      expect(
        find.textContaining('Enter a distance greater than zero'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('treadmill-distance')),
        '2.75',
      );
      await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
      await pumpTimes(tester, 6);
      expect(fake.finalised.single.mode, RecordMode.treadmill);
      expect(fake.finalised.single.distanceM, 2750);
    },
  );

  testWidgets('treadmill time freezes at STOP and SAVE ends the run there', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
      ),
    );
    await services.recording.start(RecordMode.treadmill, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    fake.advance(const Duration(minutes: 10));
    await pumpTimes(tester, 5);
    await tester.tap(find.byKey(const ValueKey('stop')));
    await pumpTimes(tester, 4);
    String finishTime() =>
        tester.widget<Text>(find.byKey(const ValueKey('finish-time'))).data!;
    expect(finishTime(), '10:00');
    fake.advance(const Duration(minutes: 5));
    await pumpTimes(tester, 4);
    expect(finishTime(), '10:00');
    await tester.tap(find.byKey(const ValueKey('finish-save')));
    await pumpTimes(tester, 4);
    fake.advance(const Duration(minutes: 5));
    await pumpTimes(tester, 2);
    await tester.enterText(
      find.byKey(const ValueKey('treadmill-distance')),
      '2.75',
    );
    await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
    await pumpTimes(tester, 6);
    expect(fake.finalised.single.durationMs, 600000);
  });

  testWidgets('finish time stays frozen when native confirms the pause late', (
    tester,
  ) async {
    final fake = _LateEventsGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
      ),
    );
    await services.recording.start(RecordMode.treadmill, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    fake.advance(const Duration(minutes: 10));
    await tester.pump(const Duration(milliseconds: 200));
    await pumpTimes(tester, 3);
    fake.lagMs = 300; // native answers pause() before its state event lands
    await tester.tap(find.byKey(const ValueKey('stop')));
    await tester.pump(const Duration(milliseconds: 20));
    fake.advance(const Duration(minutes: 5));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    final shown = tester
        .widget<Text>(find.byKey(const ValueKey('finish-time')))
        .data;
    expect(shown, '10:00');
  });

  group('distance markers', () {
    Future<FakeRecorderGateway> open(WidgetTester tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.treadmill,
        ),
      );
      await services.recording.start(RecordMode.treadmill, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = const Size(1080, 2400);
      await pumpTimes(tester, 3);
      return fake;
    }

    Future<void> doubleTap(WidgetTester tester, int chip) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 300)); // strip settles
      }
      final f = find.byKey(ValueKey('marker-chip-$chip'));
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 400));
      await pumpTimes(tester, 3);
    }

    bool speedsShown(WidgetTester tester) =>
        find.byKey(const ValueKey('treadmill-speeds')).evaluate().isNotEmpty;

    bool undoShown(WidgetTester tester) =>
        find.byKey(const ValueKey('treadmill-undo')).evaluate().isNotEmpty;

    /// The strip's centre line against the chip's: the next chip sits on it.
    void expectCentred(WidgetTester tester, int chip) {
      final strip = tester.getCenter(
        find.byKey(const ValueKey('treadmill-strip')),
      );
      final c = tester.getCenter(find.byKey(ValueKey('marker-chip-$chip')));
      expect((c.dx - strip.dx).abs(), lessThan(1), reason: 'chip $chip');
    }

    testWidgets(
      'the next chip is centred at the start, after a mark and after undo',
      (tester) async {
        final fake = await open(tester);
        expectCentred(tester, 0);
        fake.advance(const Duration(minutes: 3));
        await pumpTimes(tester, 3);
        await doubleTap(tester, 0);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expectCentred(tester, 1);
        await tester.tap(find.byKey(const ValueKey('treadmill-undo')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expectCentred(tester, 0);
      },
    );

    String text(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(ValueKey(key))).data!;

    testWidgets('hint first, then a double-tap marks and the speeds show', (
      tester,
    ) async {
      final fake = await open(tester);
      expect(
        text(tester, 'treadmill-hint'),
        'Double-tap a marker as you pass it',
      );
      expect(speedsShown(tester), isFalse);
      expect(undoShown(tester), isFalse);
      fake.advance(const Duration(minutes: 3)); // 0.5 km in 3:00 = 10 km/h
      await pumpTimes(tester, 3);
      await doubleTap(tester, 0);
      expect(
        text(tester, 'treadmill-hint'),
        'Double-tap the next marker · swipe if you missed one',
      );
      expect(speedsShown(tester), isTrue);
      expect(undoShown(tester), isTrue);
      expect(find.byKey(const ValueKey('marker-tick-0')), findsOneWidget);
      expect(text(tester, 'treadmill-chip-unit'), 'km');
      expect(text(tester, 'treadmill-current-speed'), '10.0');
      expect(text(tester, 'treadmill-avg-speed'), '10.0');
      fake.advance(const Duration(minutes: 2, seconds: 30));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 1); // next 0.5 km in 2:30 = 12 km/h
      expect(text(tester, 'treadmill-current-speed'), '12.0');
      expect(text(tester, 'treadmill-avg-speed'), '10.9');
    });

    testWidgets('swipe to a later marker skips the missed one', (tester) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 6));
      await pumpTimes(tester, 3);
      await tester.drag(
        find.byKey(const ValueKey('treadmill-strip')),
        const Offset(-300, 0),
      );
      await pumpTimes(tester, 6);
      await doubleTap(tester, 2); // 1.5 km in 6:00 = 15 km/h
      expect(text(tester, 'treadmill-current-speed'), '15.0');
      expect((await fake.status()).treadmillMarks, [360000.0, 1500.0]);
    });

    testWidgets('a mark not past the last one is ignored', (tester) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 0);
      await fake.addTreadmillMark(300); // behind the last mark
      await fake.addTreadmillMark(500); // the same distance again
      expect((await fake.status()).treadmillMarks, [180000.0, 500.0]);
    });

    testWidgets('UNDO takes the last mark back and the strip returns to it', (
      tester,
    ) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 0);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 1);
      expect(text(tester, 'treadmill-current-speed'), '10.0');
      await tester.tap(find.byKey(const ValueKey('treadmill-undo')));
      await pumpTimes(tester, 6);
      expect((await fake.status()).treadmillMarks, [180000.0, 500.0]);
      expect(text(tester, 'treadmill-avg-speed'), '10.0');
      await tester.tap(find.byKey(const ValueKey('treadmill-undo')));
      await pumpTimes(tester, 6);
      expect(
        text(tester, 'treadmill-hint'),
        'Double-tap a marker as you pass it',
      );
      expect(undoShown(tester), isFalse);
    });

    testWidgets('a pause is not a mark: the next speed uses moving time', (
      tester,
    ) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 0); // 0.5 km at 3:00 moving
      await tester.tap(find.text('PAUSE'));
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 1)); // a minute standing still
      await pumpTimes(tester, 3);
      // native refuses a mark while paused; the standing marks come back
      expect(await fake.addTreadmillMark(1000), [180000.0, 500.0]);
      await tester.tap(find.byKey(const ValueKey('resume')));
      await pumpTimes(tester, 4);
      fake.advance(const Duration(minutes: 2, seconds: 30));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 1); // 0.5 km in 2:30 moving = 12 km/h
      expect(text(tester, 'treadmill-current-speed'), '12.0');
      expect((await fake.status()).treadmillMarks, [
        180000.0,
        500.0,
        330000.0,
        1000.0,
      ]);
    });

    testWidgets('a double-tap while the strip is still gliding marks nothing', (
      tester,
    ) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      // The strip is still gliding to another chip: the double-tap handler
      // (called directly, so no gesture arena decides) must not mark.
      final controller = tester
          .widget<PageView>(
            find.descendant(
              of: find.byKey(const ValueKey('treadmill-strip')),
              matching: find.byType(PageView),
            ),
          )
          .controller!;
      unawaited(
        controller.animateToPage(
          3,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final chip = tester.widget<GestureDetector>(
        find.byKey(const ValueKey('marker-chip-1')),
      );
      chip.onDoubleTap!();
      await tester.pump(const Duration(milliseconds: 100));
      expect((await fake.status()).treadmillMarks, isNull);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
    });

    testWidgets(
      'a run started in miles keeps 0.25 mi chips and prefills miles',
      (tester) async {
        final fake = FakeRecorderGateway(now: now);
        final services = fakeServices(
          recorder: fake,
          // Settings say km: the run's own units must win.
          settings: const AppSettings(
            onboardingDone: true,
            lastMode: RecordMode.treadmill,
          ),
        );
        await services.recording.start(RecordMode.treadmill, null, Units.mi);
        await pumpApp(tester, services, pushRoute: Routes.recording);
        tester.view.physicalSize = const Size(1080, 2400);
        await pumpTimes(tester, 3);
        expect(find.text('0.25'), findsOneWidget);
        expect(text(tester, 'treadmill-chip-unit'), 'mi');
        fake.advance(const Duration(minutes: 2));
        await pumpTimes(tester, 3);
        await doubleTap(tester, 0);
        expect((await fake.status()).treadmillMarks, [120000.0, 402.336]);
        expect(find.text('mph'), findsNothing); // label reads "SPEED mph"
        await tester.tap(find.byKey(const ValueKey('stop')));
        await pumpTimes(tester, 4);
        await tester.tap(find.byKey(const ValueKey('finish-save')));
        await pumpTimes(tester, 4);
        final field = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('treadmill-distance')),
            matching: find.byType(TextField),
          ),
        );
        expect(field.controller!.text, '0.25');
        expect(find.text('Distance (mi)'), findsOneWidget);
      },
    );

    test('marks are refused outside a live treadmill run', () async {
      final fake = FakeRecorderGateway(now: now);
      await expectLater(fake.addTreadmillMark(500), throwsStateError);
      await fake.start(RecordMode.free, null, Units.km);
      await expectLater(fake.addTreadmillMark(500), throwsStateError);
      await expectLater(fake.undoTreadmillMark(), throwsStateError);
      await fake.discard();
      await fake.start(RecordMode.treadmill, null, Units.km);
      fake.advance(const Duration(minutes: 3));
      expect(await fake.addTreadmillMark(500), [180000.0, 500.0]);
      await fake.stop();
      await expectLater(fake.addTreadmillMark(1000), throwsStateError);
    });

    testWidgets('the finish distance is prefilled with the last mark', (
      tester,
    ) async {
      final fake = await open(tester);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 0);
      fake.advance(const Duration(minutes: 3));
      await pumpTimes(tester, 3);
      await doubleTap(tester, 1);
      await tester.tap(find.byKey(const ValueKey('stop')));
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('finish-save')));
      await pumpTimes(tester, 4);
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('treadmill-distance')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, '1.00');
      await tester.enterText(
        find.byKey(const ValueKey('treadmill-distance')),
        '1.05',
      );
      await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
      await pumpTimes(tester, 6);
      expect(fake.finalised.single.distanceM, 1050);
    });
  });
}

/// Events reach the controller [lagMs] after native emitted them, as on a
/// device where the pigeon call returns before the state event.
class _LateEventsGateway extends FakeRecorderGateway {
  _LateEventsGateway({required super.now});
  int lagMs = 0;

  @override
  Stream<RecorderEvent> get events => super.events.asyncMap((e) async {
    if (lagMs > 0) await Future<void>.delayed(Duration(milliseconds: lagMs));
    return e;
  });
}
