import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';

/// Brief-fidelity goldens (design brief §2.2 tokens, §4.4 record states).
/// PNGs are rendered on Linux CI (the "Render goldens" step in ci.yml,
/// `flutter test --update-goldens test/golden`) and committed; the aarch64
/// dev host cannot produce them. Until they exist the tests skip loudly.
/// A missing PNG fails: CI renders every golden into the `goldens` artifact
/// on the same run, so the fix is to commit that artifact, never to skip.
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens artifact',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  testWidgets('record: rep countdown', (tester) async {
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
    await pumpTimes(tester, 5);
    fake.advance(const Duration(seconds: 73));
    await pumpTimes(tester, 5);
    // Settled frame: no LAP ring or spring mid-flight over the controls.
    await settleAnimations(tester);
    await golden(tester, 'record_rep');
  });

  testWidgets('record: recovery ring', (tester) async {
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
    await pumpTimes(tester, 5);
    fake.advance(const Duration(seconds: 240));
    await pumpTimes(tester, 5);
    fake.advance(const Duration(seconds: 50));
    await pumpTimes(tester, 5);
    // Let the M3 invert flash play out (forward + reverse need frames).
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await golden(tester, 'record_recovery');
  });

  testWidgets('record: GPS lost + strap dropped + paused', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 5));
    await pumpTimes(tester, 5);
    fake.gpsLost = true;
    fake.strapDropped = true;
    fake.advance(const Duration(seconds: 1));
    await pumpTimes(tester, 5);
    await golden(tester, 'record_faults');
    await fake.pause();
    await pumpTimes(tester, 5);
    await golden(tester, 'record_paused');
  });

  testWidgets('record: LAP ring mid-flight (M2)', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    await tester.tap(find.byType(LapButton));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    await golden(tester, 'record_lap_ring');
  });

  testWidgets('home: empty and with a last run', (tester) async {
    await pumpApp(tester, fakeServices(), home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    await golden(tester, 'home_empty');
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          strap: SavedStrap(address: 'X', name: 'WHOOP 12'),
        ),
        runs: [
          summary(
            id: 'a',
            start: testNow.subtract(const Duration(days: 3)),
            distanceM: 6400,
          ),
        ],
      ),
      home: HomeScreen(now: now),
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'home_last_run');
  });

  testWidgets('start: preset editor', (tester) async {
    await pumpApp(tester, fakeServices(), pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await golden(tester, 'start_preset');
  });

  testWidgets('checklist: nothing granted', (tester) async {
    await pumpApp(
      tester,
      fakeServices(permissions: FakePermissionsGateway()),
      home: const PermissionsScreen(),
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'checklist_denied');
  });

  test('record-screen token pairs meet 7:1 (design brief §4)', () {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double ratio(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    const t = RunSoloTokens.dark;
    expect(ratio(t.inkPrimary, t.bgBase), greaterThan(7));
    expect(ratio(t.inkSecondary, t.bgBase), greaterThan(7));
    expect(ratio(t.bgBase, t.inkPrimary), greaterThan(7), reason: 'LAP');
    expect(ratio(t.inkPrimary, t.bgRaised), greaterThan(7), reason: 'banner');
    expect(ratio(t.accentArc, t.bgBase), greaterThan(7));
  });
}
