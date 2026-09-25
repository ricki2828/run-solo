import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/hold_button.dart';
import 'package:run_solo/widgets/lap_button.dart';
import 'package:run_solo/widgets/pace_dial.dart';

import '../helpers.dart';

/// Start a run on the fake and open the record screen.
Future<(FakeRecorderGateway, AppServices)> openRecording(
  WidgetTester tester, {
  RecordMode mode = RecordMode.fourByFour,
  AppSettings settings = const AppSettings(onboardingDone: true),
  void Function(FakeRecorderGateway fake)? before,
}) async {
  final fake = FakeRecorderGateway(now: now);
  before?.call(fake);
  final services = fakeServices(recorder: fake, settings: settings);
  await services.recording.start(
    mode,
    mode == RecordMode.fourByFour ? standardPreset() : null,
    Units.km,
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  expect(find.byType(RecordingScreen), findsOneWidget);
  return (fake, services);
}

/// Let stream events and the follow-up status() land.
Future<void> settle(WidgetTester tester) => pumpTimes(tester, 5);

Finder ringPainter() => find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter.runtimeType.toString() == '_RingPainter',
);

Finder timerText() => find.byKey(const ValueKey('timer'));

String timer(WidgetTester tester) => tester.widget<Text>(timerText()).data!;

void main() {
  testWidgets('4x4: warm-up counts up, START 4x4 begins rep 1, no big LAP', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester);
    expect(find.text('WARM-UP'), findsOneWidget);
    expect(find.text('warm up, then tap START 4x4'), findsOneWidget);
    expect(find.text('warm-up pace'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-reps')), findsOneWidget);
    expect(find.text('START 4x4'), findsOneWidget);

    fake.advance(const Duration(seconds: 65));
    await settle(tester);
    expect(timer(tester), '1:05');

    await tester.tap(find.byKey(const ValueKey('start-reps')));
    await settle(tester);
    expect(fake.startRepsCalls, 1);
    expect(find.text('REP 1 OF 4'), findsOneWidget);
    expect(find.text('remaining in rep'), findsOneWidget);
    expect(timer(tester), '4:00');
    // Founder field test: the phases run on their own, no big LAP button.
    expect(find.byType(LapButton), findsNothing);

    fake.advance(const Duration(seconds: 73));
    await settle(tester);
    expect(timer(tester), '2:47');
    expect(find.byKey(const ValueKey('segment-avg')), findsOneWidget);
    expect(find.byKey(const ValueKey('dial-pace')), findsOneWidget);
    // Founder (tester 0.2): the rep average is the primary number, at least
    // as tall as the countdown; the dial's pace is secondary.
    final avgH = tester
        .getSize(find.byKey(const ValueKey('segment-avg')))
        .height;
    expect(avgH, greaterThanOrEqualTo(tester.getSize(timerText()).height));
    expect(
      avgH,
      greaterThan(
        tester.getSize(find.byKey(const ValueKey('dial-pace'))).height,
      ),
    );
    expect(find.textContaining('4:4'), findsWidgets, reason: 'live pace');
    expect(find.text('0.26 km'), findsOneWidget);
  });

  testWidgets('rep end: M3 invert, recovery view, ghost line vs last rep', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester);
    await tester.tap(find.byKey(const ValueKey('start-reps')));
    await settle(tester);
    fake.advance(const Duration(seconds: 240));
    await settle(tester);

    expect(find.text('RECOVERY 1 OF 3'), findsOneWidget);
    expect(find.text('remaining in recovery'), findsOneWidget);
    expect(timer(tester), '3:00');
    final t = Theme.of(tester.element(timerText())).extension<RunSoloTokens>()!;
    expect(
      tester.widget<Text>(timerText()).style!.color,
      // Fake carries HR, so a zone background is active: Bone 70 % (A1).
      anyOf(t.inkSecondary, HrZones.secondaryOnZone),
      reason: 'recovery digits are grey',
    );

    // M3: the Bone flash is mid-fade right after the transition (one frame
    // to start the ticker, then 60 ms in).
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find.byWidgetPredicate(
        (w) => w is FadeTransition && w.child is ColoredBox,
      ),
    );
    expect(fade.opacity.value, greaterThan(0));

    // Rep 2: the last rep's pace is the dial's reference; a faster current
    // pace swings the needle right (position > 0).
    fake.advance(const Duration(seconds: 180));
    await settle(tester);
    expect(find.text('REP 2 OF 4'), findsOneWidget);
    expect(find.textContaining('last rep 4:45'), findsOneWidget);
    fake.liveSecPerKm = 275;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    final dial = tester.widget<PaceDial>(find.byType(PaceDial));
    expect(dial.referenceSecPerKm, closeTo(285, 3));
    expect(dial.position!, greaterThan(0.1), reason: 'faster than last rep');
  });

  testWidgets('reduced motion: no invert flash and no LAP ring', (
    tester,
  ) async {
    final (fake, _) = await openRecording(
      tester,
      settings: const AppSettings(onboardingDone: true, reducedMotion: true),
    );
    await tester.tap(find.byType(LapButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(ringPainter(), findsNothing);
    await settle(tester);
    fake.advance(const Duration(seconds: 240));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 60));
    final fade = tester.widget<FadeTransition>(
      find.byWidgetPredicate(
        (w) => w is FadeTransition && w.child is ColoredBox,
      ),
    );
    expect(fade.opacity.value, 0);
    expect(find.text('RECOVERY 1 OF 3'), findsOneWidget);
  });

  testWidgets('M2: LAP ring plays for a tap and for a notification lap', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    await tester.tap(find.byType(LapButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(ringPainter(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ringPainter(), findsNothing);

    await fake.lap(LapSource.notification);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ringPainter(), findsOneWidget);
    expect(find.text('LAP 3'), findsOneWidget);
  });

  testWidgets('GPS lost: banner, pace "--", bar says dropped', (tester) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    fake.advance(const Duration(seconds: 5));
    await settle(tester);
    expect(find.text('GPS 8 m'), findsOneWidget);

    fake.gpsLost = true;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    // Free run, outside a rep: neutral copy (banner + bar both say it).
    expect(find.text('GPS dropped'), findsNWidgets(2));
    expect(find.text('GPS dropped, this rep is flagged'), findsNothing);
    expect(find.text('--'), findsOneWidget);

    fake.gpsLost = false;
    fake.gpsAccuracyM = 24;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('GPS dropped'), findsNothing);
    expect(find.text('GPS 24 m'), findsOneWidget);
  });

  testWidgets('GPS lost inside a rep flags the rep; before first fix waits', (
    tester,
  ) async {
    final (fake, _) = await openRecording(
      tester,
      before: (f) => f.gpsLost = true,
    );
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Waiting for GPS'), findsOneWidget);
    fake.gpsLost = false;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    await tester.tap(find.byType(LapButton));
    await settle(tester);
    fake.gpsLost = true;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('GPS dropped, this rep is flagged'), findsOneWidget);
  });

  testWidgets('strap dropped shows "--" and reconnecting, never 0', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    fake.advance(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('reconnecting'), findsNothing);
    expect(find.textContaining('%'), findsWidgets);

    fake.strapDropped = true;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('reconnecting'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('heart rate and total time are large figures (tester 0.2)', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    fake.advance(const Duration(seconds: 65));
    await settle(tester);
    for (final key in ['vitals-hr', 'vitals-total']) {
      final text = tester.widget<Text>(find.byKey(ValueKey(key)));
      expect(text.style!.fontSize, greaterThanOrEqualTo(32), reason: key);
    }
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('vitals-total'))).data,
      '1:05',
    );
  });

  testWidgets('pause dims and offers RESUME; resume continues', (tester) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    await tester.tap(find.text('PAUSE'));
    await settle(tester);
    expect(find.text('PAUSED'), findsOneWidget);
    expect(fake.state, RecorderState.paused);
    // The phase timer hides under the PAUSED card (no digits peeking out);
    // the large TOTAL stays readable.
    expect(timerText().hitTestable(), findsNothing);
    expect(find.byKey(const ValueKey('vitals-total')), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'RESUME'));
    await settle(tester);
    expect(find.text('PAUSED'), findsNothing);
    expect(fake.state, RecorderState.recording);
  });

  testWidgets('Android 14 volume-key note: one amber line, run keeps going', (
    tester,
  ) async {
    final (fake, services) = await openRecording(tester, mode: RecordMode.laps);
    fake.emitFault(FaultKind.volumeKeyUnavailable, 'volume keys taken');
    await settle(tester);
    expect(
      find.text(
        "On Android 14, volume-key laps aren't available. "
        'Use the lock-screen LAP.',
      ),
      findsOneWidget,
    );
    expect(services.recording.snapshot.recording, isTrue);
    expect(find.byType(LapButton), findsOneWidget);
    // A GPS drop outranks the note; the note returns once GPS is back.
    fake.gpsLost = true;
    fake.advance(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('GPS dropped'), findsWidgets);
    expect(find.textContaining('Android 14'), findsNothing);
  });

  testWidgets('finalise enforces the backup budget (plan §4)', (tester) async {
    final storage = FakeStorageGateway();
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake, storage: storage);
    await services.recording.start(RecordMode.laps, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldButton)),
    );
    await settleAnimations(tester, const Duration(seconds: 2));
    await gesture.up();
    await pumpTimes(tester, 5);
    expect(fake.finalised, hasLength(1));
    expect(storage.enforceCalls, 1);
  });

  testWidgets('hold-to-stop: a short press does nothing, 2 s finalises', (
    tester,
  ) async {
    final (fake, _) = await openRecording(tester, mode: RecordMode.laps);
    final stop = find.byType(HoldButton);

    final short = await tester.startGesture(tester.getCenter(stop));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 500));
    await short.up();
    await settleAnimations(tester);
    expect(fake.finalised, isEmpty);
    expect(find.byType(RecordingScreen), findsOneWidget);

    final long = await tester.startGesture(tester.getCenter(stop));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 2100));
    await settle(tester);
    await long.up();
    expect(fake.finalised, hasLength(1));
    expect(fake.state, RecorderState.idle);
    await settleAnimations(tester);
    expect(find.byType(RecordingScreen), findsNothing);
  });

  testWidgets('keeps the screen on while recording, releases on stop', (
    tester,
  ) async {
    final (fake, services) = await openRecording(tester, mode: RecordMode.laps);
    final perms = services.permissions as FakePermissionsGateway;
    expect(perms.keepScreenOn, isTrue);
    final stop = find.byType(HoldButton);
    final long = await tester.startGesture(tester.getCenter(stop));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 2100));
    await settle(tester);
    await long.up();
    await settleAnimations(tester);
    expect(fake.state, RecorderState.idle);
    expect(perms.keepScreenOn, isFalse);
  });

  testWidgets('back button cannot leave a live run', (tester) async {
    await openRecording(tester, mode: RecordMode.laps);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    // maybePop reports true when PopScope vetoes; the screen must stay.
    await navigator.maybePop();
    await settleAnimations(tester);
    expect(find.byType(RecordingScreen), findsOneWidget);
  });
}
