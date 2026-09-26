import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/compare_card.dart';
import 'package:run_solo/widgets/gps_bar.dart';

import '../helpers.dart';

/// LV2 (design brief A10.1 / A10.8 widget tests): the live compare card's
/// bounds, brightness, timing and when it must not show; the in-app Mute
/// tips; Settings → Voice.

CompareEvent km3({bool overlay = true, String kind = 'distance'}) =>
    CompareEvent(
      boardKey: 'be:5k',
      boardLabel: '5K',
      kind: kind,
      index: 3,
      rank: 2,
      of: 7,
      deltaMs: 6000,
      deltaSecPerKm: kind == 'intervals' ? 2.0 : null,
      deltaVo2: kind == 'cooper' ? -1.0 : null,
      value: kind == 'cooper' ? 50.2 : null,
      text: 'Number 2 of 7, 6 seconds off your best.',
      overlay: overlay,
    );

final LiveContext liveContext = LiveContext(
  boards: [],
  cooperHistory: [48, 50],
  coachingMuted: false,
  builtAtMs: 0,
  engineVersion: 1,
);

Future<(FakeRecorderGateway, AppServices)> openRun(
  WidgetTester tester, {
  RecordMode mode = RecordMode.free,
  SessionSpec? spec,
  AppSettings settings = const AppSettings(onboardingDone: true),
  LiveContext? context,
  int seconds = 0,
}) async {
  final fake = FakeRecorderGateway(now: now);
  final services = fakeServices(recorder: fake, settings: settings);
  await services.recording.start(mode, spec, Units.km, liveContext: context);
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  await step(tester, fake, seconds);
  return (fake, services);
}

Future<void> step(
  WidgetTester tester,
  FakeRecorderGateway fake,
  int seconds,
) async {
  for (var i = 0; i < seconds; i++) {
    fake.advance(const Duration(seconds: 1));
    await tester.pump();
  }
  await pumpTimes(tester, 5);
}

/// Emit and let the 150 ms fade in finish.
Future<void> show(
  WidgetTester tester,
  FakeRecorderGateway fake,
  CompareEvent e,
) async {
  fake.emitCompare(e);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 200));
  if (card.evaluate().isNotEmpty) expect(opacity(tester), 1);
}

final Finder card = find.byKey(const ValueKey('compare-card'));

void expectClear(WidgetTester tester, Finder primary) {
  expect(card, findsOneWidget);
  final c = tester.getRect(card);
  final p = tester.getRect(primary);
  expect(c.overlaps(p), isFalse, reason: 'card $c covers primary $p');
  final gps = tester.getRect(find.byType(GpsBar));
  expect(c.bottom, lessThanOrEqualTo(gps.top), reason: 'card over GPS bar');
  // Content width: the screen minus the 16 dp gutters.
  expect(c.width, closeTo(360 - 2 * Space.recordGutter, 0.5));
}

Finder timer() => find.byKey(const ValueKey('timer'));

void main() {
  group('bounds: never over the primary, always above the GPS bar', () {
    for (final h in [800, 640]) {
      testWidgets('Free run km split at 360 x $h', (tester) async {
        final (fake, _) = await openRun(tester, seconds: 900);
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 3);
        await show(tester, fake, km3());
        expectClear(tester, timer());
        expect(tester.getSize(card).height, h < 720 ? 92 : 104);
      });

      testWidgets('Laps run at 360 x $h', (tester) async {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.laps,
          seconds: 60,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        await fake.lap(LapSource.button);
        await step(tester, fake, 30);
        await show(tester, fake, km3());
        expectClear(tester, timer());
        expect(find.text('LAP 2'), findsOneWidget);
      });

      testWidgets('time rep to recovery at 360 x $h', (tester) async {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.intervals,
          spec: standardPreset(),
          seconds: 10,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        await fake.startReps();
        await step(tester, fake, 241);
        expect(find.textContaining('RECOVERY 1'), findsOneWidget);
        await show(tester, fake, km3(kind: 'intervals'));
        expectClear(tester, timer());
      });

      testWidgets('distance recovery at 360 x $h (WARN-9)', (tester) async {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.intervals,
          spec: presetSpec('400s'),
          seconds: 10,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        await fake.startReps();
        await step(tester, fake, 130);
        expect(find.textContaining('RECOVERY 1'), findsOneWidget);
        await show(tester, fake, km3(kind: 'intervals'));
        // Metres to go is the primary number here.
        expect(tester.widget<Text>(timer()).data, endsWith(' m'));
        expectClear(tester, timer());
      });

      testWidgets('12-minute test at 360 x $h', (tester) async {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.cooper,
          spec: engine.SessionSpec.cooper.toPigeon(),
          seconds: 300,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        // C1b: warm up, then START TEST; minute 6 of the test.
        await fake.startReps();
        await step(tester, fake, 360);
        await show(tester, fake, km3(kind: 'cooper'));
        // The countdown is primary; the card sits over the metres.
        expectClear(tester, timer());
        expect(
          tester
              .getRect(card)
              .overlaps(
                tester.getRect(
                  find.byKey(const ValueKey('cooper-distance-live')),
                ),
              ),
          isTrue,
        );
      });

      testWidgets('timed 5 km at 360 x $h', (tester) async {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.intervals,
          spec: engine.SessionSpec.parkrun(kEventNames.parkrun).toPigeon()
            ..warmupSeconds = 0,
          seconds: 600,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 3);
        await show(
          tester,
          fake,
          CompareEvent(
            boardKey: 'target',
            boardLabel: 'predicted',
            kind: 'target',
            index: 2,
            rank: 1,
            of: 1,
            deltaMs: -8000,
            value: 1470000,
            text: '8 seconds up on your predicted 24:30.',
            overlay: true,
          ),
        );
        expectClear(tester, find.byKey(const ValueKey('event-to-go')));
        expect(find.textContaining('(predicted)'), findsOneWidget);
      });
    }
  });

  for (final h in [800, 640]) {
    testWidgets('GOAL runs (G3): the card over the projected finish at $h', (
      tester,
    ) async {
      for (final spec in [
        engine.SessionSpec.goalDistance(21098, 'Half'),
        engine.SessionSpec.goalTime(1800, '30 min'),
      ]) {
        final (fake, _) = await openRun(
          tester,
          mode: RecordMode.intervals,
          spec: spec.toPigeon(),
          seconds: 600,
        );
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 3);
        await show(
          tester,
          fake,
          CompareEvent(
            boardKey: 'goal',
            boardLabel: spec.name,
            kind: 'distanceInTime',
            index: 10,
            rank: 1,
            of: 3,
            value: 6412,
            text: 'Best of 3 so far.',
            overlay: true,
          ),
        );
        expectClear(tester, find.byKey(const ValueKey('event-to-go')));
        await tester.pump(const Duration(seconds: 2));
      }
    });
  }

  test('card ink is dimmer than the primary and 7:1 on every zone', () {
    for (var z = 0; z <= HrZones.count; z++) {
      final ground = Color.alphaBlend(
        CompareCard.ground,
        HrZones.background(z),
      );
      final ink = Color.alphaBlend(CompareCard.ink, ground);
      final primary = NightSession.inkPrimary;
      expect(
        ink.computeLuminance(),
        lessThan(primary.computeLuminance()),
        reason: 'zone $z',
      );
      final l1 = ink.computeLuminance() + 0.05;
      final l2 = ground.computeLuminance() + 0.05;
      expect(l1 / l2, greaterThanOrEqualTo(7), reason: 'zone $z');
    }
  });

  testWidgets('2 s in all: fades in, holds, is gone', (tester) async {
    final (fake, _) = await openRun(tester, seconds: 900);
    fake.emitCompare(km3());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(opacity(tester), inExclusiveRange(0, 1)); // mid fade in
    await tester.pump(const Duration(milliseconds: 1000));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(card, findsNothing);
  });

  testWidgets('reduced motion: cuts in, no fade frames', (tester) async {
    final (fake, _) = await openRun(
      tester,
      seconds: 900,
      settings: const AppSettings(onboardingDone: true, reducedMotion: true),
    );
    fake.emitCompare(km3());
    await pumpTimes(tester, 2);
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1950));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 60));
    expect(card, findsNothing);
  });

  testWidgets('a new compare replaces the one showing, never queues', (
    tester,
  ) async {
    final (fake, _) = await openRun(tester, seconds: 900);
    await show(tester, fake, km3());
    await tester.pump(const Duration(milliseconds: 1000));
    await show(
      tester,
      fake,
      km3()
        ..index = 4
        ..rank = 1
        ..deltaMs = -9000,
    );
    expect(find.text('#1 OF 7'), findsOneWidget);
    expect(find.text('#2 OF 7'), findsNothing);
    // Its own full 2 s, then nothing left behind it.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(card, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing);
  });

  testWidgets('a compare older than 2 s is dropped', (tester) async {
    await loadRunSoloFonts();
    final events = ValueNotifier<CompareEvent?>(null);
    final at = DateTime(2026, 9, 26, 7);
    var clock = at;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompareCardHost(
            events: events,
            receivedAt: () => at,
            now: () => clock,
            enabled: true,
          ),
        ),
      ),
    );
    clock = at.add(const Duration(milliseconds: 2500));
    events.value = km3();
    await tester.pump();
    expect(card, findsNothing);
    clock = at.add(const Duration(milliseconds: 1500));
    events.value = km3()..index = 4;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(card, findsOneWidget);
    // Only what was left of its 2 s.
    await tester.pump(const Duration(milliseconds: 400));
    expect(card, findsNothing);
  });

  testWidgets('semantics: the full text, not a live region', (tester) async {
    final handle = tester.ensureSemantics();
    final (fake, _) = await openRun(tester, seconds: 900);
    await show(tester, fake, km3());
    final node = tester.getSemantics(card);
    expect(node.label, '#2 OF 7. ON PACE FOR · 5Ks. 6 s behind your best.');
    expect(tester.widget<Semantics>(card).properties.liveRegion, isNot(true));
    handle.dispose();
  });

  group('no card', () {
    testWidgets('with a recovery under 20 s (overlay false)', (tester) async {
      final (fake, _) = await openRun(tester, seconds: 900);
      await show(tester, fake, km3(overlay: false));
      expect(card, findsNothing);
    });

    testWidgets('while paused', (tester) async {
      final (fake, _) = await openRun(tester, seconds: 900);
      await fake.pause();
      await pumpTimes(tester, 5);
      await show(tester, fake, km3());
      expect(card, findsNothing);
    });

    testWidgets('pausing hides a card that is showing', (tester) async {
      final (fake, _) = await openRun(tester, seconds: 900);
      await show(tester, fake, km3());
      expect(card, findsOneWidget);
      await fake.pause();
      await pumpTimes(tester, 5);
      expect(card, findsNothing);
      // Its time ran out while paused: resuming never brings it back late.
      await tester.pump(const Duration(seconds: 2));
      await fake.resume();
      await pumpTimes(tester, 5);
      expect(card, findsNothing);
    });

    testWidgets('with Show while running off', (tester) async {
      final (fake, _) = await openRun(
        tester,
        seconds: 900,
        settings: const AppSettings(
          onboardingDone: true,
          showWhileRunning: false,
        ),
      );
      await show(tester, fake, km3());
      expect(card, findsNothing);
    });

    testWidgets('in the last 10 s of a recovery', (tester) async {
      final (fake, _) = await openRun(
        tester,
        mode: RecordMode.intervals,
        spec: standardPreset(),
        seconds: 10,
      );
      await fake.startReps();
      await step(tester, fake, 240 + 172);
      expect(find.textContaining('RECOVERY 1'), findsOneWidget);
      await show(tester, fake, km3(kind: 'intervals'));
      expect(card, findsNothing);
    });

    test('with END REP, in a rep, in warm-up, in the last 400 m', () {
      final spec = presetSpec('400s');
      RecordingSnapshot snap(Phase phase, {int? gpsBadSinceMs}) =>
          RecordingSnapshot(
            state: RecorderState.recording,
            mode: RecordMode.intervals,
            spec: spec,
            phase: phase,
            repIndex: 1,
            stepIndex: phase == Phase.recovery ? 1 : 0,
            elapsedMs: 100000,
            gpsBadSinceMs: gpsBadSinceMs,
          );
      expect(compareCardAllowed(snap(Phase.recovery), 60000), isTrue);
      expect(
        compareCardAllowed(snap(Phase.recovery, gpsBadSinceMs: 80000), 60000),
        isFalse,
      );
      expect(compareCardAllowed(snap(Phase.work), 60000), isFalse);
      expect(compareCardAllowed(snap(Phase.warmup), 60000), isFalse);
      final event = RecordingSnapshot(
        state: RecorderState.recording,
        mode: RecordMode.intervals,
        spec: engine.SessionSpec.parkrun(kEventNames.parkrun).toPigeon(),
        phase: Phase.work,
        repIndex: 1,
        stepIndex: 0,
        stepRemainingM: 380,
      );
      expect(compareCardAllowed(event, 0), isFalse);
      expect(
        compareCardAllowed(
          RecordingSnapshot(
            state: RecorderState.recording,
            mode: RecordMode.free,
            tipsMuted: true,
          ),
          0,
        ),
        isFalse,
      );
    });
  });

  group('Mute tips', () {
    testWidgets('only while this run has tips on', (tester) async {
      await openRun(tester, seconds: 60);
      expect(find.byKey(const ValueKey('mute-tips')), findsNothing);
    });

    testWidgets('not when Settings has Coaching tips off', (tester) async {
      await openRun(
        tester,
        seconds: 60,
        context: LiveContext(
          boards: [],
          cooperHistory: [48],
          coachingMuted: true,
          builtAtMs: 0,
          engineVersion: 1,
        ),
      );
      expect(find.byKey(const ValueKey('mute-tips')), findsNothing);
    });

    testWidgets('tap: native mutes, the button and the card go', (
      tester,
    ) async {
      final (fake, _) = await openRun(
        tester,
        seconds: 60,
        context: liveContext,
      );
      final button = find.byKey(const ValueKey('mute-tips'));
      expect(button, findsOneWidget);
      expect(find.byKey(const ValueKey('mute-tips')), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      // The control row keeps PAUSE and STOP readable beside it: not
      // scaled below 13 sp (natural 15 sp, so at least 13/15 of its height).
      for (final label in ['PAUSE', 'STOP']) {
        final hold = find.text(label);
        expect(
          tester.getRect(hold).height,
          greaterThanOrEqualTo(tester.getSize(hold).height * 13 / 15),
          reason: label,
        );
      }
      await show(tester, fake, km3());
      expect(card, findsOneWidget);
      await tester.tap(button);
      await pumpTimes(tester, 6);
      expect(fake.tipsMuted, isTrue);
      expect(button, findsNothing);
      expect(card, findsNothing);
      await show(tester, fake, km3()..index = 4);
      expect(card, findsNothing);
    });

    testWidgets('the notification action hides it too', (tester) async {
      final (fake, _) = await openRun(
        tester,
        seconds: 60,
        context: liveContext,
      );
      await fake.muteTips(); // as RecorderActionReceiver
      await pumpTimes(tester, 6);
      expect(find.byKey(const ValueKey('mute-tips')), findsNothing);
    });
  });
}

double opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.ancestor(of: card, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;
