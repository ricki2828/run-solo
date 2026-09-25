import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';

void main() {
  testWidgets('empty state: baseline copy, no strap, START goes to Start', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: HomeScreen(now: now));

    expect(find.text('NO 4x4 YET'), findsOneWidget);
    expect(find.text('BASELINE'), findsOneWidget);
    expect(find.text('No strap, tap to pair'), findsOneWidget);
    expect(find.text('Thu 24 Sep'), findsOneWidget);

    final ctx = tester.element(find.text('BASELINE'));
    expect(
      Theme.of(ctx).extension<RunSoloTokens>()!.bgBase,
      NightSession.bgBase,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'START'));
    await pumpTimes(tester, 4);
    expect(find.byType(StartScreen), findsOneWidget);
  });

  testWidgets('last 4x4 card shows pace, laps and days ago', (tester) async {
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
    await pumpApp(tester, services, home: HomeScreen(now: now));

    expect(find.text('LAST 4x4 · 3 DAYS AGO'), findsOneWidget);
    expect(find.text('5:00/km'), findsOneWidget);
    expect(find.textContaining('8 laps · 32:00'), findsOneWidget);
  });

  testWidgets('saved strap and chosen mode reflect settings', (tester) async {
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
    expect(find.text('Strap: Whoop'), findsOneWidget);
    expect(find.text('5 × 4:00\n2:30 rec'), findsOneWidget);

    await tester.tap(find.text('4x4'));
    await pumpTimes(tester);
    expect(services.settings.settings.lastMode, RecordMode.fourByFour);
  });

  testWidgets('location not granted: red row, START opens the checklist', (
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
    await tester.tap(find.widgetWithText(FilledButton, 'START'));
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
