import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/screens/shell_screen.dart';
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

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

  testWidgets('record: 4x4 warm-up with the big START 4x4', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.fourByFour,
      standardPreset(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 95));
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    expect(find.text('START 4x4'), findsOneWidget);
    await golden(tester, 'record_warmup');
  });

  // Founder (tester 0.2): the segment average is the primary number; check
  // the balance on a standard (360 x 800) and a short (360 x 640) phone.
  Future<void> stepSeconds(
    WidgetTester tester,
    FakeRecorderGateway fake,
    int seconds,
  ) async {
    for (var i = 0; i < seconds; i++) {
      fake.advance(const Duration(seconds: 1));
      await tester.pump();
    }
    await pumpTimes(tester, 5);
  }

  for (final h in [800, 640]) {
    testWidgets('record: 4x4 phases at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.fourByFour,
        standardPreset(),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      // 1 s steps: the zone tracker's dwell sees every tick, so the zone
      // label matches the HR on screen (reviewer P3).
      await stepSeconds(tester, fake, 95);
      await settleAnimations(tester);
      await golden(tester, 'record_warmup_360x$h');
      await fake.startReps();
      await pumpTimes(tester, 5);
      await stepSeconds(tester, fake, 73);
      await settleAnimations(tester);
      await golden(tester, 'record_rep_360x$h');
      await stepSeconds(tester, fake, 167 + 50);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      await golden(tester, 'record_recovery_360x$h');
    });
  }

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
    await services.recording.start(RecordMode.laps, null, Units.km);
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
    await services.recording.start(RecordMode.laps, null, Units.km);
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

  // ---- Phase 2 (plan §18, addendum A1/A2/A4, brief §4.6–4.9) ----

  Future<void> recordWithHr(
    WidgetTester tester,
    RecordMode mode,
    int? hr,
    String name, {
    int? height,
  }) async {
    final fake = FakeRecorderGateway(now: now)..scriptedHr = hr;
    if (hr == null) fake.hrPaired = false;
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      mode,
      mode == RecordMode.fourByFour ? standardPreset() : null,
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    if (height != null) {
      tester.view.physicalSize = Size(1080, height * 3.0);
    }
    await pumpTimes(tester, 4);
    if (mode == RecordMode.fourByFour) await fake.lap(LapSource.button);
    fake.advance(const Duration(seconds: 73));
    await pumpTimes(tester, 5);
    if (mode != RecordMode.free) {
      await fake.lap(LapSource.button);
      fake.advance(const Duration(seconds: 40));
      await pumpTimes(tester, 5);
    }
    await settleAnimations(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await golden(tester, name);
  }

  testWidgets('record: zone 0 / 3 / 5 backgrounds (A1)', (tester) async {
    await recordWithHr(tester, RecordMode.fourByFour, null, 'record_zone0');
    await recordWithHr(tester, RecordMode.fourByFour, 140, 'record_zone3');
    await recordWithHr(tester, RecordMode.fourByFour, 178, 'record_zone5');
  });

  testWidgets('record: laps run and free run layouts (A2)', (tester) async {
    await recordWithHr(tester, RecordMode.laps, 150, 'record_laps');
    await recordWithHr(tester, RecordMode.free, 138, 'record_free');
  });

  // Founder (tester 0.2): heart rate and total time readable on Laps and
  // Free too, on standard and short phones.
  for (final h in [800, 640]) {
    testWidgets('record: laps and free at 360 x $h', (tester) async {
      await recordWithHr(
        tester,
        RecordMode.laps,
        150,
        'record_laps_360x$h',
        height: h,
      );
      await recordWithHr(
        tester,
        RecordMode.free,
        138,
        'record_free_360x$h',
        height: h,
      );
    });
  }

  final d1 = DateTime.utc(2026, 9, 10, 6);
  final d2 = DateTime.utc(2026, 9, 14, 6);

  Future<void> verdictGolden(
    WidgetTester tester,
    List<dynamic> files,
    String id,
    String name,
  ) async {
    await pumpApp(
      tester,
      fakeServices(files: files.cast()),
      pushRoute: Routes.verdict,
      pushArguments: id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 200));
    await golden(tester, name);
  }

  testWidgets('verdict: baseline, faster, slower, noise, flagged', (
    tester,
  ) async {
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
    await verdictGolden(tester, [r1], r1.id, 'verdict_baseline');
    final faster = fourByFourFile(n: 2, start: d2, workSecPerKm: 262);
    await verdictGolden(tester, [r1, faster], faster.id, 'verdict_faster');
    final slower = fourByFourFile(n: 3, start: d2, workSecPerKm: 305);
    await verdictGolden(tester, [r1, slower], slower.id, 'verdict_slower');
    final same = fourByFourFile(n: 4, start: d2, workSecPerKm: 281);
    await verdictGolden(tester, [r1, same], same.id, 'verdict_noise');
    final flagged = fourByFourFile(n: 5, start: d1, missedPress: true);
    await verdictGolden(tester, [flagged], flagged.id, 'verdict_flagged');
  });

  testWidgets('verdict: mid-reveal frame (M4 word wipe)', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
    final faster = fourByFourFile(n: 2, start: d2, workSecPerKm: 262);
    await pumpApp(
      tester,
      fakeServices(files: [r1, faster]),
      pushRoute: Routes.verdict,
      pushArguments: faster.id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 820));
    await golden(tester, 'verdict_reveal_mid');
  });

  testWidgets('run detail: 4x4 with map, laps run, free run', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r1]),
      home: RunDetailScreen(runId: r1.id),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'detail_4x4');
    final laps = lapsRunFile(n: 2, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [laps]),
      home: RunDetailScreen(runId: laps.id),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'detail_laps');
    final free = freeRunFile(n: 3, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [free]),
      home: RunDetailScreen(runId: free.id),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'detail_free');
  });

  testWidgets('verdict: indoor run', (tester) async {
    final indoor = fourByFourFile(n: 6, start: d1, indoor: true);
    await verdictGolden(tester, [indoor], indoor.id, 'verdict_indoor');
  });

  testWidgets('run detail: map failed to load, no Play services', (
    tester,
  ) async {
    final free = freeRunFile(n: 3, start: d1);
    await pumpApp(
      tester,
      fakeServices(
        files: [free],
        maps: const FakeMapSurfaceFactory(available: true, failLoad: true),
      ),
      home: RunDetailScreen(runId: free.id),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'detail_map_failed');
    await pumpApp(
      tester,
      fakeServices(
        files: [free],
        maps: const FakeMapSurfaceFactory(available: true),
        permissions: FakePermissionsGateway(
          snapshot: const PermissionSnapshot(
            fineLocation: true,
            gmsAvailable: false,
          ),
        ),
      ),
      home: RunDetailScreen(runId: free.id),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'detail_no_gms');
  });

  testWidgets('fix laps: flagged run', (tester) async {
    final flagged = fourByFourFile(n: 5, start: d1, missedPress: true);
    await pumpApp(
      tester,
      fakeServices(files: [flagged]),
      pushRoute: Routes.fixLaps,
      pushArguments: flagged.id,
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'fix_laps');
  });

  testWidgets('trend: 4x4 with five sessions', (tester) async {
    final files = [
      for (var i = 0; i < 5; i++)
        fourByFourFile(
          n: i + 1,
          start: d1.add(Duration(days: 3 * i)),
          workSecPerKm: 292 - 5 * i,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: const TrendScreen(),
    );
    await pumpTimes(tester, 6);
    await golden(tester, 'trend_4x4');
  });

  testWidgets('history: verdict arrows and three types', (tester) async {
    final files = [
      fourByFourFile(n: 1, start: d1, workSecPerKm: 284),
      fourByFourFile(n: 2, start: d2, workSecPerKm: 262),
      lapsRunFile(n: 3, start: d2.add(const Duration(days: 1))),
      freeRunFile(n: 4, start: d2.add(const Duration(days: 2))),
    ];
    await pumpApp(
      tester,
      fakeServices(files: files),
      home: ShellScreen(now: now, checkRecoveryOnOpen: false),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.text('HISTORY'));
    await pumpTimes(tester, 6);
    await golden(tester, 'history_verdicts');
  });

  testWidgets('settings: heart rate section with strap source', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: AppSettings(
          onboardingDone: true,
          typedMaxHr: 185,
          observedMaxHr: 192,
          observedMaxHrAt: DateTime(2026, 9, 3),
          pendingObservedMaxHr: 205,
        ),
      ),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'settings');
  });

  testWidgets('start: three run types', (tester) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.laps,
        ),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'start_laps');
  });

  testWidgets('start: laps run on Android 14 (volume-key toggle off)', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        permissions: FakePermissionsGateway(volumeKeyLaps: false),
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.laps,
        ),
      ),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 4);
    await golden(tester, 'start_laps_android14');
  });

  test(
    'zone backgrounds keep Bone ≥ 7:1 and warn ≥ 4.5:1 (A1, A7 checklist)',
    () {
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
      for (var z = 0; z <= HrZones.count; z++) {
        final bg = HrZones.background(z);
        expect(ratio(t.inkPrimary, bg), greaterThan(7), reason: 'Bone on Z$z');
        expect(ratio(t.semWarn, bg), greaterThan(4.5), reason: 'warn on Z$z');
        expect(ratio(t.accentArc, bg), greaterThan(7), reason: 'Arc on Z$z');
        // Bone 80 % composited over the zone background (see HrZones).
        final bone70 = Color.alphaBlend(HrZones.secondaryOnZone, bg);
        expect(ratio(bone70, bg), greaterThan(7), reason: 'Bone 70% on Z$z');
        expect(lum(bg), lessThanOrEqualTo(0.034), reason: 'OLED budget Z$z');
      }
    },
  );

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
