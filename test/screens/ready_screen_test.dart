import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/ready_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

Future<void> openReady(
  WidgetTester tester,
  AppServices services, {
  AppSettings Function(AppSettings)? preset,
}) async {
  await pumpApp(
    tester,
    services,
    pushRoute: Routes.start,
    pushArguments: StartArgs(preset: preset, readyFirst: true),
  );
  await pumpTimes(tester, 4);
  await settleAnimations(tester);
}

void main() {
  testWidgets('Ready names the run, the plan and the checks', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    expect(find.byType(ReadyScreen), findsOneWidget);
    expect(find.text('FREE RUN'), findsOneWidget);
    expect(find.text('Just run'), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-gps')), findsOneWidget);
    expect(find.text('SEARCHING'), findsOneWidget);
    // The warm-up starts when Ready opens.
    final fake = services.recorder as FakeRecorderGateway;
    expect(fake.gpsProbeRunning, isTrue);
    // Without a good fix START still works, with a warning.
    expect(find.text('Starting without a good GPS fix'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ready-start')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('NONE'), findsOneWidget);
  });

  testWidgets('a good fix clears the warning and says GOOD', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        strap: SavedStrap(address: 'X', name: 'Polar H10'),
      ),
      ble: FakeBleGateway()
        ..connected = true
        ..lastHr = 61,
    );
    await openReady(tester, services);
    (services.recorder as FakeRecorderGateway).emitGpsProbe(
      GpsProbeEvent(fix: true, lat: -41.3, lon: 174.8, accuracyM: 6),
    );
    await pumpTimes(tester, 3);
    expect(find.text('GOOD'), findsOneWidget);
    expect(find.text('Starting without a good GPS fix'), findsNothing);
    expect(find.text('CONNECTED · 61 BPM'), findsOneWidget);
  });

  testWidgets('a weak fix says WEAK and still warns', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    (services.recorder as FakeRecorderGateway).emitGpsProbe(
      GpsProbeEvent(fix: true, accuracyM: 48),
    );
    await pumpTimes(tester, 3);
    expect(find.text('WEAK'), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-gps-warning')), findsOneWidget);
  });

  testWidgets('START counts 3-2-1-GO with a haptic a beat and starts at GO', (
    tester,
  ) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('countdown-word')), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(fake.startCalls, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    expect(fake.startCalls, isEmpty, reason: 'nothing records before GO');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('GO'), findsOneWidget);
    await pumpTimes(tester, 4);
    expect(fake.startCalls, hasLength(1));
    // 3, 2, 1 and GO: four beats.
    expect(haptics, hasLength(4));
    expect(haptics.last, 'HapticFeedbackType.heavyImpact');
    await tester.pump(const Duration(seconds: 1));
    await pumpTimes(tester, 4);
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets('tapping the countdown cancels back to Ready, no recording', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('countdown')));
    await pumpTimes(tester, 3);
    expect(find.byKey(const ValueKey('ready-start')), findsOneWidget);
    // The timer is gone: nothing starts later.
    await tester.pump(const Duration(seconds: 5));
    expect(fake.startCalls, isEmpty);
    expect(find.byType(ReadyScreen), findsOneWidget);
  });

  testWidgets('countdown Off starts on the tap', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        countdownSeconds: 0,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await pumpTimes(tester, 4);
    expect(fake.startCalls, hasLength(1));
    await settleAnimations(tester);
  });

  testWidgets('a 5 s countdown starts at 5', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        countdownSeconds: 5,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('5'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('1'), findsOneWidget);
    expect(fake.startCalls, isEmpty);
  });

  testWidgets('reduced motion: numbers only, no scale animation', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        reducedMotion: true,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('countdown')),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsNothing,
    );
  });

  testWidgets('a goal run waits for a good fix before START', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(onboardingDone: true, goalRun: true),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    (services.recorder as FakeRecorderGateway).emitGpsProbe(
      GpsProbeEvent(fix: true, lat: -41.3, lon: 174.8, accuracyM: 8),
    );
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('start-ready-up')));
    await pumpTimes(tester, 3);
    await settleAnimations(tester);
    expect(find.byType(ReadyScreen), findsOneWidget);
    expect(find.text('GOOD'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ready-start')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('CHANGE on Ready opens the picker', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    await tester.tap(find.byKey(const ValueKey('ready-change')));
    await pumpTimes(tester, 3);
    await settleAnimations(tester);
    expect(find.byType(ReadyScreen), findsNothing);
    expect(find.byKey(const ValueKey('start-ready-up')), findsOneWidget);
  });

  testWidgets('intervals: the session shape and its words fill the middle', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.intervals,
      ),
    );
    await openReady(tester, services);
    expect(find.byKey(const ValueKey('ready-structure')), findsOneWidget);
    expect(find.byKey(const ValueKey('ready-structure-line')), findsOneWidget);
  });

  testWidgets('free: the last free run, when there is one', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
      runs: [
        summary(
          id: 'f1',
          start: testNow.subtract(const Duration(days: 3)),
          fourByFour: false,
          durationMs: 37 * 60 * 1000,
          distanceM: 7200,
        ),
      ],
    );
    await openReady(tester, services);
    await pumpTimes(tester, 4);
    final line = tester.widget<Text>(
      find.byKey(const ValueKey('ready-last-run')),
    );
    expect(line.data, startsWith('Last free run: 7.20 km'));
    expect(line.data, endsWith('3 days ago'));
  });

  testWidgets('free with no history shows no last-run line', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await openReady(tester, services);
    expect(find.byKey(const ValueKey('ready-last-run')), findsNothing);
  });

  testWidgets('what is on: chips say so and open Settings', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        autoPause: false,
      ),
    );
    await openReady(tester, services);
    expect(find.text('VOICE CUES ON'), findsOneWidget);
    expect(find.text('COUNTDOWN 3 S'), findsOneWidget);
    expect(find.text('AUTO-PAUSE OFF'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ready-on-countdown')));
    await pumpTimes(tester, 3);
    await settleAnimations(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  test('Ready text keeps 4.5:1 on every run type colour', () {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double ratio(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    final grounds = {
      'free': AuroraRunType.free,
      'trail': AuroraRunType.trail,
      'laps': AuroraRunType.laps,
      'goal': AuroraRunType.goal,
      'intervals': AuroraRunType.intervals,
      'tests': AuroraRunType.tests,
    };
    for (final e in grounds.entries) {
      expect(
        ratio(ReadyScreen.ink, e.value),
        greaterThanOrEqualTo(4.5),
        reason: '${e.key}: ink on ground',
      );
      // The READY? label is ink at 70 % over the ground.
      final soft = Color.alphaBlend(
        ReadyScreen.ink.withValues(alpha: 0.7),
        e.value,
      );
      expect(
        ratio(soft, e.value),
        greaterThanOrEqualTo(4.5),
        reason: '${e.key}: READY? label',
      );
    }
    // The chips and START: Bone on Night ink.
    expect(
      ratio(NightSession.inkPrimary, ReadyScreen.ink),
      greaterThanOrEqualTo(4.5),
    );
  });
}
