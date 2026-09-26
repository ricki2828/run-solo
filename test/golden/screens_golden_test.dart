import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/course_board_screen.dart';
import 'package:run_solo/screens/custom_builder_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/screens/shell_screen.dart';
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/splash/intro_gate.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/sessions.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/lap_button.dart';
import 'package:run_solo/widgets/weather_chip.dart';

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
      RecordMode.intervals,
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

  testWidgets('record: 4x4 warm-up with the big START REPS', (tester) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.intervals,
      standardPreset(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 95));
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    expect(find.text('START REPS'), findsOneWidget);
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
        RecordMode.intervals,
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
      RecordMode.intervals,
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

  testWidgets('home: ESTIMATED TIMES, closed and with the band (PD2)', (
    tester,
  ) async {
    final e = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: 1470000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    final services = fakeServices(
      live: LiveContextSource.prepared([
        engine.LiveCandidate(
          engine.BoardInput(
            runId: 'a',
            date: DateTime(2026, 9, 12, 12).toUtc(),
            mode: engine.RunMode.free,
            efforts: e.efforts,
            heatFraction: 0,
          ),
          engine.RunDerived(bestEfforts: e),
        ),
      ], now: now),
    );
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    await golden(tester, 'home_estimates');
    await tester.tap(find.text('ESTIMATED TIMES'));
    await pumpTimes(tester, 4);
    await settleAnimations(tester);
    await golden(tester, 'home_estimates_band');
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
      mode == RecordMode.intervals ? standardPreset() : null,
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    if (height != null) {
      tester.view.physicalSize = Size(1080, height * 3.0);
    }
    await pumpTimes(tester, 4);
    if (mode == RecordMode.intervals) await fake.lap(LapSource.button);
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
    await recordWithHr(tester, RecordMode.intervals, null, 'record_zone0');
    await recordWithHr(tester, RecordMode.intervals, 140, 'record_zone3');
    await recordWithHr(tester, RecordMode.intervals, 178, 'record_zone5');
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

  // A6 weather chip: every state on one page, and run detail with the
  // adjusted chip under the header, before the map.
  engine.WeatherRecord weatherOk(double temp, double dew) =>
      engine.WeatherRecord(
        status: engine.WeatherStatus.ok,
        fetchedAt: d1,
        latR: -33.9,
        lonR: 151.2,
        tempC: temp,
        rh: 62,
        dewPointC: dew,
        adj: engine.HeatModel.of(tempC: temp, dewPointC: dew).fraction,
      );

  testWidgets('weather chip: pending, unavailable, cool, too hot, adjusted', (
    tester,
  ) async {
    final run = fourByFourFile(n: 1, start: d1);
    WeatherChipView v(engine.WeatherRecord? w) => weatherChipView(
      analysis: const engine.RunEngine().analyze(
        run,
        sidecar: engine.RunSidecar(runId: run.id, weather: w?.toJson()),
        now: now(),
      ),
      units: Units.km,
      fetchEnabled: true,
    )!;
    final views = [
      v(null),
      v(const engine.WeatherRecord(status: engine.WeatherStatus.failed)),
      v(weatherOk(12, 5)),
      v(weatherOk(38, 28)),
      v(weatherOk(28, 21)),
    ];
    await pumpApp(
      tester,
      fakeServices(),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(Space.screenGutter),
          children: [
            for (final view in views) ...[
              WeatherChip(view: view),
              const SizedBox(height: Space.x12),
            ],
          ],
        ),
      ),
    );
    await pumpTimes(tester, 3);
    await golden(tester, 'weather_chip_states');
  });

  testWidgets('run detail: weather chip before the map', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    await pumpApp(
      tester,
      fakeServices(
        files: [r1],
        sidecars: {
          r1.id: engine.RunSidecar(
            runId: r1.id,
            weather: weatherOk(28, 21).toJson(),
          ),
        },
      ),
      home: RunDetailScreen(runId: r1.id),
    );
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('weather-chip')), findsOneWidget);
    await golden(tester, 'detail_weather');
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

  // Onboarding on a standard and a short phone: the body scrolls, CONTINUE
  // stays pinned (the emulator showed a 26 px overflow at 360 x 640).
  for (final h in [800, 640]) {
    testWidgets('onboarding: every page at 360 x $h', (tester) async {
      await pumpApp(
        tester,
        fakeServices(settings: const AppSettings()),
        onboarding: true,
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await settleAnimations(tester);
      await golden(tester, 'onboarding_intro_360x$h');
      await tester.tap(find.text('CONTINUE'));
      await settleAnimations(tester);
      await golden(tester, 'onboarding_birth_year_360x$h');
      await tester.tap(find.text('Skip'));
      await settleAnimations(tester);
      await golden(tester, 'onboarding_setup_360x$h');
    });
  }

  // Lead P2 on #30: CONTINUE with the battery step undone scrolls to it and
  // marks it, and the footer says a step is left.
  testWidgets('set up: CONTINUE points at the undone battery step, 360 x 640', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(
        settings: const AppSettings(),
        permissions: FakePermissionsGateway(
          snapshot: const PermissionSnapshot(
            fineLocation: true,
            notifications: true,
            bluetooth: true,
          ),
        ),
      ),
      pushRoute: Routes.permissions,
      pushArguments: true,
    );
    tester.view.physicalSize = const Size(1080, 640 * 3.0);
    await settleAnimations(tester);
    await tester.tap(find.text('CONTINUE'));
    await settleAnimations(tester);
    await golden(tester, 'setup_needed_step_360x640');
  });

  // B3 / brief A9: the Lap Draw intro over Home. The ticker starts on the
  // first frame after pumpApp, so frame times are from there.
  Future<void> introAt(
    WidgetTester tester,
    IntroKind kind,
    int ms,
    String name,
  ) async {
    await pumpApp(tester, fakeServices(), intro: kind);
    await tester.pump(Duration(milliseconds: ms));
    await golden(tester, name);
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('intro: full, line drawing through the R', (tester) async {
    await introAt(tester, IntroKind.full, 450, 'intro_full_draw');
  });

  testWidgets('intro: full, final composition', (tester) async {
    await introAt(tester, IntroKind.full, 1120, 'intro_full_final');
  });

  testWidgets('intro: 0.6 s, final frame', (tester) async {
    await introAt(tester, IntroKind.short, 400, 'intro_short_final');
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

  // Phase 3 I4 (design brief A8): Intervals sheet, session card, builder
  // and the step layouts, on a standard and a short phone.
  for (final h in [800, 640]) {
    testWidgets('intervals: sheet, 400s card, builder at 360 x $h', (
      tester,
    ) async {
      final services = fakeServices(
        settings: const AppSettings(onboardingDone: true, sessionId: '400s'),
        customSessions: [
          CustomSession(
            id: 'g1',
            name: 'Hill sixes',
            reps: 6,
            workValue: 90,
            createdAt: DateTime.utc(2026, 9, 20),
          ),
        ],
      );
      await pumpApp(tester, services, pushRoute: Routes.start);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await golden(tester, 'start_session_400s_360x$h');
      await tester.tap(find.text('INTERVALS'));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 600));
      await golden(tester, 'intervals_sheet_360x$h');
      await tester.pageBack();
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 600));
      await pumpApp(
        tester,
        services,
        home: const CustomBuilderScreen(
          initial: CustomSession(
            id: 'b1',
            name: '',
            reps: 6,
            workTarget: engine.TargetKind.distance,
            workValue: 800,
            recoveryValue: 120,
          ),
        ),
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await golden(tester, 'custom_builder_360x$h');
    });

    testWidgets(
      'record: distance rep, distance recovery, END REP at 360 x $h',
      (tester) async {
        final fake = FakeRecorderGateway(now: now);
        final services = fakeServices(recorder: fake);
        await services.recording.start(
          RecordMode.intervals,
          presetSpec('400s'),
          Units.km,
        );
        await pumpApp(tester, services, pushRoute: Routes.recording);
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 4);
        await stepSeconds(tester, fake, 60);
        await fake.startReps();
        await pumpTimes(tester, 5);
        await stepSeconds(tester, fake, 55);
        await settleAnimations(tester);
        await golden(tester, 'record_distance_rep_360x$h');
        await stepSeconds(tester, fake, 59 + 20);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        await golden(tester, 'record_distance_recovery_360x$h');
        await stepSeconds(tester, fake, 40);
        fake.gpsLost = true;
        await stepSeconds(tester, fake, 12);
        await settleAnimations(tester);
        await golden(tester, 'record_end_rep_360x$h');
      },
    );

    testWidgets('record: 30/30s short rep at 360 x $h', (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(recorder: fake);
      await services.recording.start(
        RecordMode.intervals,
        presetSpec('30-30s'),
        Units.km,
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 4);
      await stepSeconds(tester, fake, 30);
      await fake.startReps();
      await pumpTimes(tester, 5);
      await stepSeconds(tester, fake, 3);
      await settleAnimations(tester);
      await golden(tester, 'record_short_rep_start_360x$h');
      await stepSeconds(tester, fake, 15);
      await settleAnimations(tester);
      await golden(tester, 'record_short_rep_360x$h');
    });
  }

  // K1 app half (design brief A10.2 board detail, A10.3 slot): the event
  // panel on the verdict, the official-time refusal and the course board.
  for (final h in [800, 640]) {
    testWidgets('event: verdict panel, official time refused, board at '
        '360 x $h', (tester) async {
      final day0 = DateTime.utc(2026, 8, 1, 22);
      final files = [
        for (var i = 1; i <= 5; i++)
          eventRunFile(
            n: i,
            start: day0.add(Duration(days: 7 * i)),
            eventName: kEventNames.parkrun,
            mps: 3.3 + 0.05 * i,
          ),
      ];
      final course = engine.ParkrunCourses.newCourseId(files.first);
      final services = fakeServices(
        files: files,
        courseNames: {course: 'Albert Park'},
      );
      await pumpApp(
        tester,
        services,
        pushRoute: Routes.verdict,
        pushArguments: files[4].id, // the course best: NEW BEST and #1 of 5
      );
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 1800));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('event-rank')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(VerdictScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await golden(tester, 'event_verdict_360x$h');
      await tester.tap(find.byKey(const ValueKey('event-official')));
      await pumpTimes(tester, 2);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.enterText(
        find.byKey(const ValueKey('official-time')),
        '40:00',
      );
      await tester.tap(find.byKey(const ValueKey('official-save')));
      await pumpTimes(tester, 4);
      expect(
        find.textContaining('long way from your GPS time'),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 300)); // error fades in
      await golden(tester, 'event_official_refused_360x$h');
      await pumpApp(
        tester,
        services,
        home: CourseBoardScreen(courseId: course),
      );
      // pumpApp resets the surface (review P2): size it again.
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await golden(tester, 'course_board_360x$h');
    });
  }

  // GOAL (plan §G) with the event picked, and its record screen
  // (distance to go primary; the last 400 m swap).
  for (final h in [800, 640]) {
    testWidgets('event: Start and the timed 5 km at 360 x $h', (tester) async {
      final services = fakeServices(
        settings: const AppSettings(onboardingDone: true, goalRun: true),
      );
      await pumpApp(tester, services, pushRoute: Routes.start);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await golden(tester, 'start_event_nofix_360x$h');
      (services.recorder as FakeRecorderGateway).emitGpsProbe(
        GpsProbeEvent(fix: true, accuracyM: 6),
      );
      await pumpTimes(tester, 4);
      await tester.pump(const Duration(milliseconds: 400)); // button enables
      await golden(tester, 'start_event_360x$h');

      final fake = FakeRecorderGateway(now: now)
        ..liveSecPerKm = 285
        ..scriptedHr = 171;
      final run = fakeServices(recorder: fake);
      await run.recording.start(
        RecordMode.intervals,
        engine.SessionSpec.parkrun(kEventNames.parkrun).toPigeon()
          ..warmupSeconds = 0,
        Units.km,
      );
      for (var i = 0; i < 700; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpApp(tester, run, pushRoute: Routes.recording);
      // pumpApp resets the surface (#51/#53 review P2): size it again so
      // the 640 golden really is the short phone.
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await golden(tester, 'record_event_360x$h');
      for (var i = 0; i < 660; i++) {
        fake.advance(const Duration(seconds: 1));
      }
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 400));
      await golden(tester, 'record_event_last400_360x$h');
    });
  }

  // G3 (plan §G, A8): a standard goal on Start (GPS reason pinned above
  // START), Custom, and the goal record screens: time goal before the goal
  // and in the cool-down, the Half's long numbers.
  for (final h in [800, 640]) {
    testWidgets('goal: Start, custom, and the record screens at 360 x $h', (
      tester,
    ) async {
      final services = fakeServices(
        settings: const AppSettings(
          onboardingDone: true,
          goalRun: true,
          goalId: 'd10000',
        ),
      );
      await pumpApp(tester, services, pushRoute: Routes.start);
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 6);
      await settleAnimations(tester);
      await golden(tester, 'start_goal_nofix_360x$h');
      await services.settings.update(
        (x) => x.copyWith(goalId: 'dcustom', goalCustomMetres: 12300),
      );
      (services.recorder as FakeRecorderGateway).emitGpsProbe(
        GpsProbeEvent(fix: true, accuracyM: 6),
      );
      await pumpTimes(tester, 4);
      await tester.pump(const Duration(milliseconds: 400));
      await golden(tester, 'start_goal_custom_360x$h');

      Future<(FakeRecorderGateway, AppServices)> record(
        engine.SessionSpec spec,
      ) async {
        final fake = FakeRecorderGateway(now: now)
          ..liveSecPerKm = 285
          ..scriptedHr = 165;
        final run = fakeServices(recorder: fake);
        await run.recording.start(
          RecordMode.intervals,
          spec.toPigeon(),
          Units.km,
        );
        return (fake, run);
      }

      Future<void> show(
        (FakeRecorderGateway, AppServices) r,
        int seconds,
      ) async {
        final (fake, run) = r;
        for (var i = 0; i < seconds; i++) {
          fake.advance(const Duration(seconds: 1));
        }
        await pumpApp(tester, run, pushRoute: Routes.recording);
        tester.view.physicalSize = Size(1080, h * 3.0);
        await pumpTimes(tester, 6);
        await tester.pump(const Duration(milliseconds: 400));
      }

      final time = await record(engine.SessionSpec.goalTime(1800, '30 min'));
      await show(time, 600);
      await golden(tester, 'record_goal_time_360x$h');
      await show(time, 1260);
      await golden(tester, 'record_goal_cooldown_360x$h');
      final half = await record(engine.SessionSpec.goalDistance(21098, 'Half'));
      await show(half, 3000);
      await golden(tester, 'record_goal_half_360x$h');
    });
  }

  // PD2 on Start (A10.10, #84 review): the goal card's target line.
  testWidgets('goal: Start with a target line at 360 x 640', (tester) async {
    final efforts = engine.RunBestEfforts(
      efforts: {
        engine.BestEffortDistance.k5: engine.BestEffort(
          distance: engine.BestEffortDistance.k5,
          elapsedMs: 1470000,
          startMs: 0,
          startOffsetM: 0,
          splitsMs: const [],
        ),
      },
      fromStartSplitsMs: const [],
    );
    final services = fakeServices(
      live: LiveContextSource.prepared([
        engine.LiveCandidate(
          engine.BoardInput(
            runId: 'a',
            date: DateTime(2026, 9, 12, 12).toUtc(),
            mode: engine.RunMode.free,
            efforts: efforts.efforts,
          ),
          engine.RunDerived(bestEfforts: efforts),
        ),
      ], now: now),
      settings: const AppSettings(
        onboardingDone: true,
        goalRun: true,
        goalId: 'd10000',
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    tester.view.physicalSize = const Size(1080, 1920);
    await pumpTimes(tester, 6);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('start-target')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpTimes(tester, 2);
    await golden(tester, 'start_goal_target_360x640');
  });
}
