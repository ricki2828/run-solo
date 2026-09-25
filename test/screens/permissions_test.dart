import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

Finder row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first;

void main() {
  testWidgets('nothing granted: every row explains why, DONE disabled', (
    tester,
  ) async {
    final perms = FakePermissionsGateway();
    final services = fakeServices(permissions: perms);
    await pumpApp(tester, services, home: const PermissionsScreen());
    await pumpTimes(tester);

    expect(find.text('Location while using'), findsOneWidget);
    expect(find.textContaining('GPS is the pace'), findsOneWidget);
    expect(find.text('NEEDED'), findsNWidgets(2), reason: 'location, battery');
    expect(find.text('DENIED'), findsOneWidget, reason: 'notifications');
    expect(find.text('OPTIONAL'), findsOneWidget, reason: 'bluetooth');
    expect(
      find.textContaining('Recording needs precise location'),
      findsOneWidget,
    );
    final done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'DONE'),
    );
    expect(done.onPressed, isNull);
  });

  testWidgets('granting location enables DONE; denial stays honest', (
    tester,
  ) async {
    final perms = FakePermissionsGateway(denyLocation: true);
    final services = fakeServices(permissions: perms);
    await pumpApp(tester, services, home: const PermissionsScreen());
    await pumpTimes(tester);

    await tester.tap(row('Location while using'));
    await pumpTimes(tester);
    expect(find.text('NEEDED'), findsNWidgets(2), reason: 'still denied');

    perms.denyLocation = false;
    await tester.tap(row('Location while using'));
    await pumpTimes(tester);
    expect(find.text('OK'), findsOneWidget);
    final done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'DONE'),
    );
    expect(done.onPressed, isNotNull);
  });

  testWidgets('approximate-only is red with the Precise hint', (tester) async {
    final perms = FakePermissionsGateway(grantCoarseOnly: true);
    final services = fakeServices(permissions: perms);
    await pumpApp(tester, services, home: const PermissionsScreen());
    await pumpTimes(tester);
    await tester.tap(row('Location while using'));
    await pumpTimes(tester);
    expect(find.text('DENIED'), findsNWidgets(2));
    expect(find.textContaining('Approximate only'), findsOneWidget);
    await scrollTo(tester, find.text('DONE'));
    final done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'DONE'),
    );
    expect(done.onPressed, isNull);
  });

  testWidgets('battery row opens the system page and re-reads status', (
    tester,
  ) async {
    final perms = FakePermissionsGateway(
      snapshot: const PermissionSnapshot(
        fineLocation: true,
        notifications: true,
      ),
    );
    final services = fakeServices(permissions: perms);
    await pumpApp(tester, services, home: const PermissionsScreen());
    await pumpTimes(tester);
    await tester.tap(row('Battery optimisation off'));
    await pumpTimes(tester);
    expect(perms.batteryExemptionRequests, 1);
    expect(find.text('NEEDED'), findsOneWidget, reason: 'page only opened');
    perms.snapshot = perms.snapshot.copyWith(batteryUnrestricted: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpTimes(tester);
    expect(find.text('NEEDED'), findsNothing);
  });

  testWidgets('onboarding variant marks onboarding done on Continue or Skip', (
    tester,
  ) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(),
      settings: const AppSettings(),
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.permissions,
      pushArguments: true,
    );
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('CONTINUE'));
    expect(find.text('CONTINUE'), findsOneWidget);
    await scrollTo(tester, find.text('Skip for now'));
    await tester.tap(find.text('Skip for now'));
    await pumpTimes(tester);
    expect(services.settings.settings.onboardingDone, isTrue);
  });
}
