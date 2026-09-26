import 'dart:io';

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/perf_diagnostics.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/recording_controller.dart';
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
    await tester.tap(find.text('Max HR (entered)'));
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
    expect(find.text('NEEDED'), findsOneWidget, reason: 'page only opened');
    // The user grants it on the system page and comes back: refresh on resume.
    perms.snapshot = perms.snapshot.copyWith(batteryUnrestricted: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpTimes(tester, 4);
    expect(find.text('NEEDED'), findsNothing);
    expect(find.text('OK'), findsWidgets);
  });

  testWidgets('Android 14: volume-key toggle disabled with its reason', (
    tester,
  ) async {
    final services = fakeServices(
      permissions: FakePermissionsGateway(volumeKeyLaps: false),
    );
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Volume-key lap (Laps run)'));
    expect(find.text(kVolumeKeyToggleReason), findsOneWidget);
    final sw = tester.widget<Switch>(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Volume-key lap (Laps run)'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.byType(Switch),
      ),
    );
    expect(sw.onChanged, isNull);
    expect(sw.value, isFalse);
  });

  testWidgets('other Android versions: volume-key toggle works, no reason', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Volume-key lap (Laps run)'));
    expect(find.text(kVolumeKeyToggleReason), findsNothing);
    final sw = tester.widget<Switch>(
      find.descendant(
        of: find
            .ancestor(
              of: find.text('Volume-key lap (Laps run)'),
              matching: find.byType(Row),
            )
            .first,
        matching: find.byType(Switch),
      ),
    );
    expect(sw.onChanged, isNotNull);
    expect(sw.value, isTrue);
  });

  testWidgets('"Weather for each run" defaults on and switches off (§18.6)', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Weather for each run'));
    final toggle = find.descendant(
      of: find
          .ancestor(
            of: find.text('Weather for each run'),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await pumpTimes(tester, 3);
    expect(services.settings.settings.weatherPerRun, isFalse);
  });

  testWidgets('"Compare heat-adjusted paces" defaults off and switches on '
      '(W2)', (tester) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Compare heat-adjusted paces'));
    final toggle = find.descendant(
      of: find
          .ancestor(
            of: find.text('Compare heat-adjusted paces'),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.tap(toggle);
    await pumpTimes(tester, 3);
    expect(services.settings.settings.compareHeatAdjusted, isTrue);
    expect(
      AppSettings.fromJson(services.settings.settings.toJson())
          .compareHeatAdjusted,
      isTrue,
    );
  });

  testWidgets('Diagnostics shows the phone timings (not in play)', (
    tester,
  ) async {
    PerfDiagnostics.instance
      ..reset()
      ..recordPrepare(const Duration(milliseconds: 38), 212)
      ..recordHistoryOpen(const Duration(milliseconds: 640))
      ..recordHistoryOpen(const Duration(milliseconds: 90));
    await pumpApp(tester, fakeServices(), home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.byKey(const ValueKey('perf-diagnostics')));
    expect(find.text('Live compare prepare: 38 ms (212 runs)'), findsOneWidget);
    expect(find.text('Live compare at Start: not yet'), findsOneWidget);
    expect(
      find.text('History first open: 640 ms'),
      findsOneWidget,
      reason: 'the first open of the session, not a later one',
    );
    PerfDiagnostics.instance.recordBuild(const Duration(milliseconds: 3));
    await pumpTimes(tester, 2);
    expect(find.text('Live compare at Start: 3 ms'), findsOneWidget);
    PerfDiagnostics.instance.reset();
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
    await scrollTo(tester, find.text('Move runs to another Run Supreme'));
    // Real file I/O (temp dir) needs real async time. Wait for the share
    // itself, not a fixed delay: 300 ms flaked once on CI (#30, 2ca64d0:
    // "Expected: an object with length of <1>, Actual: []").
    await tester.runAsync(() async {
      final shared = transfer.nextShare();
      await tester.tap(find.text('Move runs to another Run Supreme'));
      await shared.timeout(const Duration(seconds: 20));
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
    final storage = FakeStorageGateway(archiveNext: ['old-1', 'old-2']);
    final services = fakeServices(
      files: [r1],
      transfer: transfer,
      storage: storage,
    );
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    await scrollTo(tester, find.text('Import runs'));
    await tester.tap(find.text('Import runs'));
    await pumpTimes(tester, 6);
    expect(storage.enforceCalls, 1, reason: 'budget enforced after import');
    expect(
      find.text(
        'Imported 1, 1 already here (edits not merged), 1 not Run Supreme files. '
        '2 older runs are past the backup budget: move runs to another Run '
        'Supreme to keep them safe.',
      ),
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
