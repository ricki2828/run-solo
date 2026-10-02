import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';
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
}
