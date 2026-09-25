import 'dart:io';

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Settings (brief §4.11, plan D3, §18.6 copy, Phase 2 battery row).
void main() {
  String sourceLine(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('max-hr-source'))).data!;

  testWidgets('max HR source line per D3: default, entered, age, strap', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    expect(sourceLine(tester), 'Max HR 190, default until you enter one');

    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(onboardingDone: true, typedMaxHr: 185),
      ),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    expect(sourceLine(tester), 'Max HR 185, entered');

    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(onboardingDone: true, birthYear: 1986),
      ),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    expect(sourceLine(tester), 'Max HR 180, from your age');

    await pumpApp(
      tester,
      fakeServices(
        settings: AppSettings(
          onboardingDone: true,
          typedMaxHr: 185,
          observedMaxHr: 192,
          observedMaxHrAt: DateTime(2026, 9, 3),
        ),
      ),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    expect(sourceLine(tester), 'Max HR 192, seen on your strap Thu 3 Sep');
  });

  testWidgets('reset observed max clears it and the line falls back', (
    tester,
  ) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        typedMaxHr: 185,
        observedMaxHr: 192,
      ),
    );
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await tester.tap(find.text('Reset observed max'));
    await pumpTimes(tester, 3);
    expect(services.settings.settings.observedMaxHr, isNull);
    expect(sourceLine(tester), 'Max HR 185, entered');
  });

  testWidgets('pending max: confirm sheet applies or ignores', (tester) async {
    final services = fakeServices(
      settings: const AppSettings(
        onboardingDone: true,
        typedMaxHr: 185,
        pendingObservedMaxHr: 205,
      ),
    );
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await tester.tap(find.text('Strap saw 205 bpm'));
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('pending-max-sheet')), findsOneWidget);
    await tester.tap(find.text('IGNORE'));
    await settleAnimations(tester);
    expect(services.settings.settings.pendingObservedMaxHr, isNull);
    expect(services.settings.settings.observedMaxHr, isNull);

    await services.settings.update(
      (s) => s.copyWith(pendingObservedMaxHr: 205),
    );
    await pumpTimes(tester, 3);
    await tester.tap(find.text('Strap saw 205 bpm'));
    await settleAnimations(tester);
    await tester.tap(find.text('USE 205'));
    await settleAnimations(tester);
    expect(services.settings.settings.observedMaxHr, 205);
    expect(services.settings.settings.pendingObservedMaxHr, isNull);
    expect(sourceLine(tester), startsWith('Max HR 205, seen on your strap'));
  });

  testWidgets('typed max HR sheet validates the range', (tester) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await tester.tap(find.text('Max HR'));
    await settleAnimations(tester);
    await tester.enterText(find.byType(TextField), '300');
    await tester.tap(find.text('SAVE'));
    await pumpTimes(tester, 3);
    expect(find.text('Outside the allowed range.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '186');
    await tester.tap(find.text('SAVE'));
    await settleAnimations(tester);
    expect(services.settings.settings.typedMaxHr, 186);
  });

  testWidgets('battery row asks for the exemption through the gateway', (
    tester,
  ) async {
    final perms = FakePermissionsGateway(
      snapshot: const PermissionSnapshot(
        fineLocation: true,
        batteryUnrestricted: false,
      ),
    );
    await pumpApp(
      tester,
      fakeServices(permissions: perms),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Battery optimisation'));
    expect(find.text('NEEDED'), findsOneWidget);
    await tester.tap(find.text('Battery optimisation'));
    await pumpTimes(tester, 4);
    expect(perms.batteryExemptionRequests, 1);
    expect(find.text('OK'), findsWidgets);
  });

  testWidgets('About carries the §18.6 paragraph and attribution', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.byKey(const ValueKey('privacy-paragraph')));
    expect(find.text(kPrivacyParagraph), findsOneWidget);
    expect(find.text(kNoAnalyticsLine), findsOneWidget);
    expect(find.text(kOpenMeteoAttribution), findsOneWidget);
    expect(find.textContaining('never leave your phone'), findsNothing);
  });

  testWidgets('Move runs shares one bundle file per run', (tester) async {
    final r1 = fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 10, 6));
    final r2 = freeRunFile(n: 2, start: DateTime.utc(2026, 9, 12, 6));
    final transfer = FakeTransferGateway();
    await pumpApp(
      tester,
      fakeServices(files: [r1, r2], transfer: transfer),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Move runs to another Run Solo'));
    // Real file I/O (temp dir) needs real async time.
    await tester.runAsync(() async {
      await tester.tap(find.text('Move runs to another Run Solo'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await pumpTimes(tester, 3);
    expect(transfer.shared, hasLength(1));
    expect(transfer.shared.single, hasLength(2));
    final ids = {
      for (final p in transfer.shared.single)
        engine.RunBundleCodec.decode(File(p).readAsStringSync()).run.id,
    };
    expect(ids, {r1.id, r2.id});
  });

  testWidgets('Import runs: dedupes, reports, rejects junk', (tester) async {
    final r1 = fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 10, 6));
    final r2 = freeRunFile(n: 2, start: DateTime.utc(2026, 9, 12, 6));
    final transfer = FakeTransferGateway(
      toPick: [
        PickedFile(
          name: 'a.json',
          text: engine.RunBundleCodec.encode(engine.RunBundle(run: r1)),
        ),
        PickedFile(
          name: 'b.json',
          text: engine.RunBundleCodec.encode(engine.RunBundle(run: r2)),
        ),
        const PickedFile(name: 'junk.json', text: '{"hello": 1}'),
      ],
    );
    final services = fakeServices(files: [r1], transfer: transfer);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Import runs'));
    await tester.tap(find.text('Import runs'));
    await pumpTimes(tester, 6);
    expect(
      find.text('Imported 1, 1 already here, 1 not Run Solo files.'),
      findsOneWidget,
    );
    final listed = await services.history.list();
    expect(listed.map((r) => r.id).toSet(), {r1.id, r2.id});
  });

  test('withdrawn privacy lines appear nowhere in the copy (A7 grep)', () {
    for (final line in [
      kPrivacyParagraph,
      kNoAnalyticsLine,
      kOnboardingInternetLine,
    ]) {
      expect(line.contains('never leave your phone'), isFalse);
      expect(line.contains('neither gets your route'), isFalse);
    }
  });
}
