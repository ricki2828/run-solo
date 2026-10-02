import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/live_route.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/compare_card.dart';
import 'package:run_solo/widgets/gps_bar.dart';
import 'package:run_solo/widgets/lap_button.dart';

import '../helpers.dart';

const _toggle = ValueKey('live-view-toggle');
const _map = ValueKey('fake-live-map');
const _hero = ValueKey('map-hero');

Future<(FakeRecorderGateway, AppServices)> open(
  WidgetTester tester, {
  RecordMode mode = RecordMode.laps,
  MapSurfaceFactory maps = const FakeMapSurfaceFactory(available: true),
  AppSettings settings = const AppSettings(onboardingDone: true),
  bool intervals = false,
  bool emitRoute = true,
}) async {
  phoneViewport(tester);
  final fake = FakeRecorderGateway(now: now)..emitRoute = emitRoute;
  final services = fakeServices(recorder: fake, settings: settings, maps: maps);
  await services.recording.start(
    intervals ? RecordMode.intervals : mode,
    intervals ? standardPreset() : null,
    Units.km,
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  expect(find.byType(RecordingScreen), findsOneWidget);
  return (fake, services);
}

void main() {
  testWidgets('no map available: no toggle, NUMBERS only', (tester) async {
    await open(
      tester,
      maps: const FakeMapSurfaceFactory(),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byKey(_toggle), findsNothing);
    // A saved MAP choice cannot show a map that is not there.
    expect(find.byKey(_map), findsNothing);
    expect(find.byType(LapButton), findsOneWidget);
  });

  testWidgets('NUMBERS is the default; the toggle switches both ways', (
    tester,
  ) async {
    final (_, services) = await open(tester);
    expect(find.byKey(_toggle), findsOneWidget);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(_hero), findsNothing);

    await tester.tap(find.byKey(_toggle));
    await pumpTimes(tester, 3);
    expect(find.byKey(_map), findsOneWidget);
    expect(find.byKey(_hero), findsOneWidget);
    expect(services.settings.settings.liveMapTypes, {'laps'});

    await tester.tap(find.byKey(_toggle));
    await pumpTimes(tester, 3);
    expect(find.byKey(_map), findsNothing);
    expect(services.settings.settings.liveMapTypes, isEmpty);
  });

  testWidgets('the choice is remembered per run type', (tester) async {
    final (_, services) = await open(tester);
    await tester.tap(find.byKey(_toggle));
    await pumpTimes(tester, 3);
    expect(find.byKey(_map), findsOneWidget);

    // A new screen for the same type opens on MAP.
    await pumpApp(tester, services, home: const SizedBox());
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    expect(find.byKey(_map), findsOneWidget);

    // Other run types keep NUMBERS.
    final other = fakeServices(
      recorder: FakeRecorderGateway(now: now),
      settings: services.settings.settings,
      maps: const FakeMapSurfaceFactory(available: true),
    );
    await other.recording.start(RecordMode.free, null, Units.km);
    await pumpApp(tester, other, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    expect(find.byKey(_map), findsNothing);
  });

  testWidgets('settings round-trip the remembered types', (tester) async {
    final s = const AppSettings(liveMapTypes: {'free', 'goal'});
    final back = AppSettings.fromJson(s.toJson());
    expect(back.liveMapTypes, {'free', 'goal'});
    expect(AppSettings.fromJson(const {}).liveMapTypes, isEmpty);
  });

  testWidgets('MAP keeps the hero big and LAP and Pause / Stop reachable', (
    tester,
  ) async {
    await open(
      tester,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    final lapMap = tester.getSize(find.byType(LapButton));
    final pauseMap = tester.getSize(find.byKey(const ValueKey('stop')));
    expect(find.byKey(_hero), findsOneWidget);
    // At least the 36 sp floor, and brighter than the label under it.
    final hero = tester.widget<Text>(find.byKey(_hero));
    expect(hero.style!.fontSize, greaterThanOrEqualTo(36));
    expect(find.byKey(const ValueKey('map-hero-label')), findsOneWidget);
    expect(find.byKey(const ValueKey('vitals-total')), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await pumpTimes(tester, 3);
    expect(tester.getSize(find.byType(LapButton)), lapMap);
    expect(tester.getSize(find.byKey(const ValueKey('stop'))), pauseMap);
  });

  testWidgets('4x4 rep: the map hero is the rep average', (tester) async {
    final (fake, _) = await open(
      tester,
      intervals: true,
      settings: const AppSettings(
        onboardingDone: true,
        liveMapTypes: {'intervals'},
      ),
    );
    expect(find.byKey(_map), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-reps')));
    await pumpTimes(tester, 5);
    fake.advance(const Duration(seconds: 60));
    await pumpTimes(tester, 5);
    expect(find.byKey(_hero), findsOneWidget);
    expect(find.text('REP AVERAGE /km'), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-avg')), findsNothing);
  });

  testWidgets('a map that fails to load shows the route on our canvas', (
    tester,
  ) async {
    await open(
      tester,
      maps: const FakeMapSurfaceFactory(available: true, failLoad: true),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byType(MapFailedCard), findsOneWidget);
    // The run itself is untouched: hero, LAP, Pause / Stop all there.
    expect(find.byKey(_hero), findsOneWidget);
    expect(find.byType(LapButton), findsOneWidget);
    expect(find.byKey(const ValueKey('stop')), findsOneWidget);
  });

  testWidgets('replay lifecycle with MAP on: route grows, pause, background, '
      'save', (tester) async {
    final (fake, services) = await open(
      tester,
      mode: RecordMode.free,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'free'}),
    );
    final route = services.recording.liveRoute;
    expect(find.byKey(_map), findsOneWidget);
    expect(route.count, lessThanOrEqualTo(1)); // the start point

    fake.advance(const Duration(seconds: 90));
    await pumpTimes(tester, 5);
    expect(route.count, greaterThan(5));
    final grown = route.count;

    // Pause: the route stays, nothing is added.
    await tester.tap(find.text('PAUSE'));
    await pumpTimes(tester, 4);
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 4);
    expect(route.count, grown);
    await tester.tap(find.text('RESUME').first);
    await pumpTimes(tester, 4);

    // Screen off: no map is alive; back on, it returns with the same route.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await pumpTimes(tester, 2);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(const ValueKey('map-off')), findsOneWidget);
    fake.advance(const Duration(seconds: 20));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpTimes(tester, 4);
    expect(find.byKey(_map), findsOneWidget);
    expect(route.count, greaterThan(grown));

    // STOP then SAVE ends the run; the route is cleared.
    await tester.tap(find.byKey(const ValueKey('stop')));
    await pumpTimes(tester, 4);
    expect(find.byKey(_map), findsNothing);
    await tester.tap(find.byKey(const ValueKey('finish-save')));
    await pumpTimes(tester, 6);
    expect(route.count, 0);
  });

  testWidgets('MAP view: AUTO-PAUSED shows over the map, the route stays, '
      'moving again clears it', (tester) async {
    final (fake, services) = await open(
      tester,
      mode: RecordMode.free,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'free'}),
    );
    fake.advance(const Duration(seconds: 60));
    await pumpTimes(tester, 5);
    final grown = services.recording.liveRoute.count;
    fake.simulateAutoPause();
    await pumpTimes(tester, 5);
    expect(find.text('AUTO-PAUSED'), findsOneWidget);
    expect(find.text('PAUSED'), findsNothing);
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 4);
    expect(services.recording.liveRoute.count, grown);
    fake.simulateAutoResume();
    await pumpTimes(tester, 5);
    expect(find.text('AUTO-PAUSED'), findsNothing);
    expect(find.byKey(_map), findsOneWidget);
  });

  testWidgets('a missed route event is caught up from native', (tester) async {
    final (fake, services) = await open(tester, emitRoute: false);
    fake.emitRoute = true;
    fake.advance(const Duration(seconds: 40));
    await pumpTimes(tester, 5);
    final route = services.recording.liveRoute;
    final have = route.count;
    expect(have, greaterThan(0));
    // Drop the track as if the screen had been recreated, then sync.
    route.clear();
    await services.recording.syncRoute();
    expect(route.count, have);
  });

  // The MAP hero is the NUMBERS layout's dominant figure for every mode and
  // phase: same text, read from the numbers screen, then from MAP.
  Future<void> heroMatches(
    WidgetTester tester, {
    required RecordMode mode,
    SessionSpec? spec,
    required Future<void> Function(FakeRecorderGateway fake) script,
    required Finder numbers,
    Finder? inside,
  }) async {
    phoneViewport(tester);
    final fake = FakeRecorderGateway(now: now)..liveSecPerKm = 300;
    final services = fakeServices(
      recorder: fake,
      maps: const FakeMapSurfaceFactory(available: true),
    );
    await services.recording.start(mode, spec, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    await script(fake);
    await pumpTimes(tester, 5);
    final f = inside ?? numbers;
    final text = tester
        .widget<Text>(
          inside == null
              ? numbers
              : find.descendant(of: numbers, matching: find.byType(Text)).first,
        )
        .data;
    expect(f, findsWidgets);
    await tester.tap(find.byKey(_toggle));
    await pumpTimes(tester, 3);
    expect(find.byKey(_map), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(_hero)).data, text);
    expect(tester.widget<Text>(find.byKey(_hero)).data, isNot('--:--'));
  }

  Future<void> run(FakeRecorderGateway f, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      f.advance(const Duration(seconds: 1));
    }
  }

  testWidgets('hero = numbers: free run average', (tester) async {
    await heroMatches(
      tester,
      mode: RecordMode.free,
      script: (f) => run(f, 120),
      numbers: find.byKey(const ValueKey('run-average')),
    );
  });

  testWidgets('hero = numbers: laps clock', (tester) async {
    await heroMatches(
      tester,
      mode: RecordMode.laps,
      script: (f) => run(f, 75),
      numbers: find.byKey(const ValueKey('timer')),
    );
  });

  testWidgets('hero = numbers: 4x4 rep average and recovery countdown', (
    tester,
  ) async {
    await heroMatches(
      tester,
      mode: RecordMode.intervals,
      spec: standardPreset(),
      script: (f) async {
        await f.startReps();
        await run(f, 60);
      },
      numbers: find.byKey(const ValueKey('segment-avg')),
    );
    await heroMatches(
      tester,
      mode: RecordMode.intervals,
      spec: standardPreset(),
      script: (f) async {
        await f.startReps();
        await run(f, 255);
      },
      numbers: find.byKey(const ValueKey('timer')),
    );
  });

  testWidgets('hero = numbers: 12-minute test clock', (tester) async {
    await heroMatches(
      tester,
      mode: RecordMode.cooper,
      spec: engine.SessionSpec.cooper.toPigeon(),
      script: (f) async {
        await run(f, 5);
        await f.startReps();
        await run(f, 100);
      },
      numbers: find.byKey(const ValueKey('timer')),
    );
  });

  testWidgets('hero = numbers: goal cool-down clock', (tester) async {
    await heroMatches(
      tester,
      mode: RecordMode.intervals,
      spec: engine.SessionSpec.goalTime(1800, '30 min').toPigeon(),
      script: (f) => run(f, 1870),
      numbers: find.byKey(const ValueKey('goal-cooldown')),
    );
  });

  testWidgets('hero = numbers: event to go', (tester) async {
    await heroMatches(
      tester,
      mode: RecordMode.intervals,
      spec: engine.SessionSpec.parkrun('parkrun').toPigeon()..warmupSeconds = 0,
      script: (f) => run(f, 60),
      numbers: find.byKey(const ValueKey('event-to-go')),
      inside: find.byKey(const ValueKey('event-to-go')),
    );
  });

  testWidgets('a compare card slides over the map top; hero and GPS bar stay', (
    tester,
  ) async {
    final (fake, _) = await open(
      tester,
      mode: RecordMode.free,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'free'}),
    );
    await run(fake, 200);
    await pumpTimes(tester, 5);
    fake.emitCompare(
      CompareEvent(
        boardKey: 'be:5k',
        boardLabel: '5K',
        kind: 'distance',
        index: 3,
        rank: 2,
        of: 7,
        deltaMs: 6000,
        text: 'Number 2 of 7, 6 seconds off your best.',
        overlay: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    final card = find.byKey(const ValueKey('compare-card'));
    expect(card, findsOneWidget);
    final hero = tester.getRect(find.byKey(_hero));
    expect(tester.getRect(card).top, greaterThanOrEqualTo(hero.bottom));
    expect(find.byType(GpsBar), findsOneWidget);
    expect(find.byType(CompareCard), findsOneWidget);
  });

  test('display simplification keeps the ends and caps the points', () {
    final pts = [
      for (var i = 0; i < 6000; i++)
        GeoPoint(-33.0 + i * 0.00004, 151.0 + (i.isEven ? 0.00001 : 0)),
    ];
    final out = simplifyForDisplay(pts, 1000);
    expect(out.length, lessThanOrEqualTo(1000));
    expect(out.first, pts.first);
    expect(out.last, pts.last);
    expect(simplifyForDisplay(pts.sublist(0, 50), 1000).length, 50);
  });

  testWidgets('syncRoute recovers after a synchronous gateway failure', (
    tester,
  ) async {
    final (fake, services) = await open(tester);
    final ctl = services.recording;
    fake.routeThrows = true;
    await ctl.syncRoute();
    fake.routeThrows = false;
    fake.emitRoute = true;
    for (var i = 0; i < 30; i++) {
      fake.advance(const Duration(seconds: 1));
    }
    ctl.liveRoute.clear();
    await ctl.syncRoute();
    expect(ctl.liveRoute.count, greaterThan(0));
  });
}
