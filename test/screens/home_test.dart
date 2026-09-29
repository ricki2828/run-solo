import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/recent_activity.dart';

import '../helpers.dart';

void main() {
  testWidgets('Home shows five choices, not a second START launcher', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: HomeScreen(now: now));

    expect(find.text('NO BASELINE YET'), findsOneWidget);
    expect(find.text('Your first session sets it.'), findsOneWidget);
    expect(find.text('YOUR SCORES'), findsOneWidget);
    for (final card in ['AEROBIC', 'SPEED', 'MID', 'LONG']) {
      expect(find.text(card), findsOneWidget);
    }
    expect(find.text('Log a 15K+ run to unlock LONG'), findsOneWidget);
    expect(find.text('RECENT ACTIVITY'), findsOneWidget);
    expect(find.textContaining('Sessions of any kind'), findsOneWidget);
    expect(find.text('No strap, tap to pair'), findsNothing);
    expect(find.text('NEW RUN'), findsOneWidget);
    expect(find.text('Thu 24 Sep'), findsOneWidget);
    for (final choice in ['FREE', 'LAPS', 'GOAL', 'INTERVALS', 'TESTS']) {
      expect(find.text(choice), findsOneWidget);
    }
    expect(find.widgetWithText(FilledButton, 'START'), findsNothing);

    final ctx = tester.element(find.text('NO BASELINE YET'));
    expect(
      Theme.of(ctx).extension<RunSoloTokens>()!.bgBase,
      NightSession.bgBase,
    );
  });

  testWidgets('Home FREE choice starts recording with one pinned START', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.ensureVisible(find.text('FREE'));
    await tester.tap(find.text('FREE'));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
    expect(services.settings.settings.lastMode, RecordMode.free);
    expect(find.text('START FREE RUN'), findsOneWidget);
    expect(fake.startCalls, isEmpty);
    await tester.tap(find.text('START FREE RUN'));
    await pumpTimes(tester, 6);
    expect(fake.startCalls.single.mode, RecordMode.free);
    expect(find.byType(RecordingScreen), findsOneWidget);
  });

  testWidgets('Home TESTS choice opens the test setup selected', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.ensureVisible(find.text('TESTS'));
    await tester.tap(find.text('TESTS'));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
    expect(services.settings.settings.lastMode, RecordMode.cooper);
    expect(find.text('START TEST'), findsOneWidget);
    expect(find.text('12-MINUTE'), findsOneWidget);
    expect(find.text('BRONCO'), findsOneWidget);
  });

  testWidgets('Home GOAL choice opens goal setup, not an interval loop', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await tester.ensureVisible(find.text('GOAL'));
    await tester.tap(find.text('GOAL'));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
    expect(services.settings.settings.goalRun, isTrue);
    expect(find.text('START 5 KM'), findsOneWidget);
  });

  testWidgets('recent activity lists the last sessions of any kind', (
    tester,
  ) async {
    final services = fakeServices(
      runs: [
        summary(
          id: 'a',
          start: testNow.subtract(const Duration(days: 3)),
          durationMs: 32 * 60 * 1000,
          distanceM: 6400,
        ),
        summary(
          id: 'b',
          start: testNow.subtract(const Duration(days: 1)),
          fourByFour: false,
        ),
      ],
    );
    await pumpApp(
      tester,
      services,
      home: HomeScreen(now: now, onShowHistory: () {}),
    );

    expect(find.text('RECENT ACTIVITY'), findsOneWidget);
    expect(find.text('4X4  ·  3 days ago', findRichText: true), findsOneWidget);
    expect(find.text('5:00/km', findRichText: true), findsOneWidget);
    expect(find.textContaining('8 laps · 32:00'), findsOneWidget);
    expect(find.text('All activity ›'), findsOneWidget);
  });

  testWidgets('recent activity titles carry the run-type colours', (
    tester,
  ) async {
    final services = fakeServices(
      runs: [
        summary(id: 'interval', start: testNow, mode: RecordMode.intervals),
        summary(
          id: 'free',
          start: testNow.subtract(const Duration(days: 1)),
          mode: RecordMode.free,
        ),
        summary(
          id: 'laps',
          start: testNow.subtract(const Duration(days: 2)),
          mode: RecordMode.laps,
        ),
      ],
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    final expected = {
      '4X4': AuroraRunType.intervals,
      'FREE RUN': AuroraRunType.free,
      'LAPS RUN': AuroraRunType.laps,
    };
    for (final entry in expected.entries) {
      final titleText = tester.widget<Text>(
        find.descendant(
          of: find.byType(RecentActivity),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.textSpan is TextSpan &&
                (widget.textSpan as TextSpan).children?.first.toPlainText() ==
                    entry.key,
          ),
        ),
      );
      final title =
          (titleText.textSpan as TextSpan).children!.first as TextSpan;
      expect(title.style!.color, entry.value);
    }
  });

  testWidgets('saved strap stays off Home; Intervals opens selected setup', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
        reps: 5,
        recoverySeconds: 150,
        strap: SavedStrap(address: 'X', name: 'WHOOP 12'),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.text('Strap: Whoop'), findsNothing);
    expect(find.text('Norwegian 4x4'), findsOneWidget);

    await tester.ensureVisible(find.text('INTERVALS'));
    await tester.tap(find.text('INTERVALS'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.lastMode, RecordMode.intervals);
    expect(find.byType(StartScreen), findsOneWidget);
    expect(find.text('START WARM-UP'), findsOneWidget);
  });

  testWidgets('location not granted: choice opens the checklist first', (
    tester,
  ) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(
        snapshot: const PermissionSnapshot(fineLocation: false),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(
      find.text('Location permission needed before you can record.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('FREE'));
    await tester.tap(find.text('FREE'));
    await pumpTimes(tester, 4);
    expect(find.byType(PermissionsScreen), findsOneWidget);
    expect(find.byType(StartScreen), findsNothing);
  });

  testWidgets('approximate-only location is called out', (tester) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(
        snapshot: const PermissionSnapshot(
          fineLocation: false,
          coarseOnly: true,
        ),
      ),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    expect(find.textContaining('Location is approximate'), findsOneWidget);
  });
}
