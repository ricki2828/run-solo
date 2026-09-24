import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/hold_button.dart';

import '../helpers.dart';

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
