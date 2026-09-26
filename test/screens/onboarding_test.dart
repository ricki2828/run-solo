import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/main.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/setup_row.dart';

import '../helpers.dart';

const _fresh = AppSettings();

void main() {
  testWidgets('first launch: the very first frame is onboarding, not Home', (
    tester,
  ) async {
    await loadRunSoloFonts();
    phoneViewport(tester);
    await tester.pumpWidget(
      RunSoloApp(
        services: fakeServices(settings: _fresh),
        now: now,
        onboarding: true,
      ),
    );
    // One frame, no post-frame work yet: this is what the phone shows first.
    expect(find.text('YOU AGAINST\nYOUR LAST RUN'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('intro, birth year, set up, then Home', (tester) async {
    final services = fakeServices(settings: _fresh);
    await pumpApp(tester, services, onboarding: true);
    expect(find.byType(HomeScreen), findsNothing);

    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    expect(find.text('YOUR BIRTH YEAR'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    await tester.tap(find.text('Skip'));
    await settleAnimations(tester);
    expect(find.byType(PermissionsScreen), findsOneWidget);

    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    expect(services.settings.settings.onboardingDone, isTrue);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('YOU AGAINST\nYOUR LAST RUN'), findsNothing);
  });

  testWidgets('back from set up lands on the intro, never Home', (
    tester,
  ) async {
    final services = fakeServices(settings: _fresh);
    await pumpApp(tester, services, onboarding: true);
    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    await tester.tap(find.text('Skip'));
    await settleAnimations(tester);

    await tester.binding.handlePopRoute();
    await settleAnimations(tester);
    expect(find.text('YOU AGAINST\nYOUR LAST RUN'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(services.settings.settings.onboardingDone, isFalse);
  });

  testWidgets('a live run skips onboarding and goes to the record screen', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake, settings: _fresh);
    await services.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(
      tester,
      services,
      onboarding: true,
      checkRecoveryOnOpen: true,
    );
    await pumpTimes(tester, 5);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.text('YOU AGAINST\nYOUR LAST RUN'), findsNothing);
    expect(services.settings.settings.onboardingDone, isFalse);
  });

  // The founder's emulator showed "BOTTOM OVERFLOWED BY 26 PIXELS" at
  // CONTINUE: every page must lay out on a short phone at a large text size
  // with the button on screen (an overflow fails the test on its own).
  for (final h in [640, 800]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('every page fits at 360 x $h, text x$scale', (tester) async {
        final services = fakeServices(settings: _fresh);
        await pumpApp(tester, services, onboarding: true);
        tester.view.physicalSize = Size(1080, h * 3.0);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await settleAnimations(tester);

        Future<void> continueOnScreen() async {
          final button = find.widgetWithText(FilledButton, 'CONTINUE');
          expect(button.hitTestable(), findsOneWidget);
          final box = tester.getRect(button);
          expect(box.bottom, lessThanOrEqualTo(h.toDouble()));
        }

        await continueOnScreen();
        await tester.tap(find.text('CONTINUE'));
        await settleAnimations(tester);
        await continueOnScreen();
        await tester.tap(find.text('Skip'));
        await settleAnimations(tester);
        await continueOnScreen();
      });
    }
  }

  // #30 review P2: on a short phone the set-up rows come before the privacy
  // text, so every row that can block a run is on screen above CONTINUE.
  testWidgets('set up at 360 x 640: every NEEDED row sits above CONTINUE', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(settings: _fresh), onboarding: true);
    tester.view.physicalSize = const Size(1080, 640 * 3.0);
    await settleAnimations(tester);
    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    await tester.tap(find.text('Skip'));
    await settleAnimations(tester);
    final top = tester
        .getRect(find.widgetWithText(FilledButton, 'CONTINUE'))
        .top;
    for (final title in [
      'Location while using',
      'Notifications',
      'Battery optimisation off',
    ]) {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(SetupRow),
      );
      expect(row, findsOneWidget, reason: title);
      // Clear of the 32 px fade too.
      expect(
        tester.getRect(row).bottom,
        lessThanOrEqualTo(top - 32),
        reason: title,
      );
    }
  });

  // #30 review P3: the fade means "more below" and nothing else.
  testWidgets('the fade shows only while there is more below', (tester) async {
    final fade = find.byKey(const ValueKey('more-below-fade'));
    await pumpApp(tester, fakeServices(settings: _fresh), onboarding: true);
    await settleAnimations(tester);
    expect(find.text('YOU AGAINST\nYOUR LAST RUN'), findsOneWidget);
    expect(fade, findsNothing, reason: 'the intro fits at 360 x 780');

    tester.view.physicalSize = const Size(1080, 640 * 3.0);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    await tester.tap(find.text('Skip'));
    await settleAnimations(tester);
    expect(fade, findsOneWidget, reason: 'set up overflows at 640 x1.3');

    await tester.drag(find.byType(ListView).last, const Offset(0, -3000));
    await settleAnimations(tester);
    expect(fade, findsNothing, reason: 'scrolled to the end');
  });
}
