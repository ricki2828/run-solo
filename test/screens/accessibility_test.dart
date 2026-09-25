import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/hold_button.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Outdoor rules (design brief §4): 56 dp targets, labelled targets, and
/// contrast. `textContrastGuideline` is WCAG AA (4.5:1); the 7:1 record
/// screen rule is covered by the token audit in the golden tests.
void main() {
  Future<void> expectGuidelines(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  testWidgets('record screen meets tap-target, label and contrast rules', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.fourByFour,
      standardPreset(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    await fake.lap(LapSource.button);
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 5);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('start screen meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, fakeServices(), pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('checklist meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(
      tester,
      fakeServices(permissions: FakePermissionsGateway()),
      home: const PermissionsScreen(),
    );
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('home meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, fakeServices(), home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('free run and laps run record layouts meet the rules', (
    tester,
  ) async {
    for (final mode in [RecordMode.free, RecordMode.laps]) {
      final handle = tester.ensureSemantics();
      final fake = FakeRecorderGateway(now: now)..scriptedHr = 140;
      final services = fakeServices(recorder: fake);
      await services.recording.start(mode, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      fake.advance(const Duration(seconds: 30));
      await pumpTimes(tester, 5);
      await tester.pump(const Duration(milliseconds: 700));
      await expectGuidelines(tester);
      handle.dispose();
    }
  });

  testWidgets('verdict, detail, trend and settings meet the rules', (
    tester,
  ) async {
    final d1 = DateTime.utc(2026, 9, 10, 6);
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
    final r2 = fourByFourFile(
      n: 2,
      start: d1.add(const Duration(days: 4)),
      workSecPerKm: 262,
    );
    final services = fakeServices(files: [r1, r2]);

    var handle = tester.ensureSemantics();
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.verdict,
      pushArguments: r2.id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 1800));
    await expectGuidelines(tester);
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(tester, services, home: RunDetailScreen(runId: r2.id));
    await pumpTimes(tester, 6);
    await expectGuidelines(tester);
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(tester, services, home: const TrendScreen());
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    await expectGuidelines(tester);
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('HOLD TO STOP exposes a long-press action for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var held = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(
          body: Center(
            child: HoldButton(label: 'HOLD TO STOP', onHeld: () => held++),
          ),
        ),
      ),
    );
    final stop = find.semantics.byAction(SemanticsAction.longPress);
    expect(stop, findsOneWidget);
    tester.semantics.performAction(stop, SemanticsAction.longPress);
    await tester.pump();
    expect(held, 1);
    handle.dispose();
  });
}
