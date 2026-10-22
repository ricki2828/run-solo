import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _toggle = ValueKey('page-dots');
const _map = ValueKey('fake-live-map');
const _pages = ValueKey('run-pages');

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
  testWidgets('no map available: no page dots, numbers only', (tester) async {
    await open(
      tester,
      maps: const FakeMapSurfaceFactory(),
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byKey(_toggle), findsNothing);
    // A saved MAP page cannot show a map that is not there.
    expect(find.byKey(_map), findsNothing);
    expect(find.byType(LapButton), findsOneWidget);
  });

  testWidgets('page 1 is the default; dots and a swipe go to the map', (
    tester,
  ) async {
    final (_, services) = await open(tester);
    expect(find.byKey(_toggle), findsOneWidget);
    expect(find.byKey(_map), findsNothing);

    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);
    expect(services.settings.settings.liveMapTypes, {'laps'});

    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    expect(services.settings.settings.liveMapTypes, isEmpty);

    // A swipe anywhere on the numbers page goes to the map.
    await tester.fling(find.byKey(_pages), const Offset(-300, 0), 1500);
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);
  });

  testWidgets('on the map page a swipe right ON the map goes back to the '
      'numbers', (tester) async {
    await open(
      tester,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byKey(_map), findsOneWidget);
    // The map ignores touches, so the pager gets the drag.
    expect(find.byKey(const ValueKey('map-ignore-touches')), findsOneWidget);
    await tester.fling(find.byKey(_map), const Offset(300, 0), 1500);
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);
  });

  testWidgets('a slow drag right from anywhere on page 2 goes back', (
    tester,
  ) async {
    await open(
      tester,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byKey(_map), findsOneWidget);
    // Start mid-screen, move slowly past half a page: no flick velocity.
    final g = await tester.startGesture(tester.getCenter(find.byKey(_map)));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);
  });

  testWidgets('system back on the map page goes to the numbers and never '
      'leaves the run', (tester) async {
    // Android gesture navigation sends a left-edge swipe as a system pop, so
    // it never reaches the edge strip (14-Oct). Simulates that pop.
    await open(
      tester,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    expect(find.byKey(_map), findsOneWidget);
    final handled = await tester.binding.handlePopRoute();
    expect(handled, isTrue);
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);
    expect(find.byType(RecordingScreen), findsOneWidget);

    // On the numbers a second back does nothing: the run stays open.
    await tester.binding.handlePopRoute();
    await settleAnimations(tester);
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);
  });

  testWidgets('the big NUMBERS button is on the map page only, 48 dp or more, '
      'and goes back', (tester) async {
    await open(tester);
    const button = ValueKey('page-numbers-button');
    expect(find.byKey(button), findsNothing);
    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);
    expect(find.byKey(button), findsOneWidget);
    final box = tester.getRect(find.byKey(button));
    expect(box.height, greaterThanOrEqualTo(48));
    expect(box.width, greaterThanOrEqualTo(48));
    expect(find.text('NUMBERS'), findsOneWidget);
    await tester.tap(find.byKey(button));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    expect(find.byKey(button), findsNothing);
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);
  });

  testWidgets(
    'page 1 has a MAP button matching NUMBERS, and it opens the map',
    (tester) async {
      await open(tester);
      const mapButton = ValueKey('page-map-button');
      const numbersButton = ValueKey('page-numbers-button');
      expect(find.byKey(mapButton), findsOneWidget);
      expect(find.text('MAP'), findsOneWidget);
      final onOne = tester.getRect(find.byKey(mapButton));
      expect(onOne.height, 56);
      await tester.tap(find.byKey(mapButton));
      await settleAnimations(tester);
      expect(find.byKey(_map), findsOneWidget);
      expect(find.byKey(mapButton), findsNothing);
      final onTwo = tester.getRect(find.byKey(numbersButton));
      // Same size and the same left/right edges; page 1 has no map to shrink,
      // so only the size and width are compared.
      expect(onTwo.size, onOne.size);
    },
  );

  testWidgets('no MAP button when there is no map', (tester) async {
    await open(tester, maps: const FakeMapSurfaceFactory());
    expect(find.byKey(const ValueKey('page-map-button')), findsNothing);
  });

  testWidgets(
    'swipes change page both ways, over the numbers, the map and the button',
    (tester) async {
      await open(tester);
      // 1 -> 2 over the numbers.
      await tester.fling(
        find.byKey(const ValueKey('timer')),
        const Offset(-300, 0),
        1500,
      );
      await settleAnimations(tester);
      expect(find.byKey(_map), findsOneWidget);
      // 2 -> 1 over the map.
      await tester.fling(find.byKey(_map), const Offset(300, 0), 1500);
      await settleAnimations(tester);
      expect(find.byKey(_map), findsNothing);
      await tester.fling(
        find.byKey(const ValueKey('timer')),
        const Offset(-300, 0),
        1500,
      );
      await settleAnimations(tester);
      // 2 -> 1 over the button row.
      await tester.fling(
        find.byKey(const ValueKey('page-numbers-button')),
        const Offset(200, 0),
        1500,
      );
      await settleAnimations(tester);
      expect(find.byKey(_map), findsNothing);
      expect(find.byKey(const ValueKey('timer')), findsOneWidget);
    },
  );

  testWidgets('map page: big run numbers, map capped at 40% of the room', (
    tester,
  ) async {
    await open(tester, mode: RecordMode.free);
    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    final map = tester.getSize(find.byKey(_map));
    final pages = tester.getSize(find.byKey(_pages));
    expect(map.height, lessThanOrEqualTo(pages.height * 0.4 + 1));
    for (final k in ['map-page-distance', 'map-page-time', 'map-page-pace']) {
      // Painted height: getRect goes through the FittedBox's transform, so a
      // figure it shrank shows up (getSize is the unscaled layout size).
      final h = tester.getRect(find.byKey(ValueKey(k))).height;
      expect(h, greaterThanOrEqualTo(36), reason: k);
    }
    // The numbers sit above the map.
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('map-page-pace'))).dy,
      lessThan(tester.getTopLeft(find.byKey(_map)).dy),
    );
  });

  testWidgets('short phone, laps: no map on page 2, the numbers take the '
      'room', (tester) async {
    // Opens on the map page (remembered) so page 1 is never built.
    await open(
      tester,
      settings: const AppSettings(onboardingDone: true, liveMapTypes: {'laps'}),
    );
    // pumpApp resets the viewport, so shrink it after opening.
    tester.view.physicalSize = const Size(1080, 1920); // 360 x 640
    await pumpTimes(tester, 4);
    await settleAnimations(tester);
    expect(find.byKey(_map), findsNothing);
    for (final k in ['map-page-distance', 'map-page-time', 'map-page-pace']) {
      final h = tester.getRect(find.byKey(ValueKey(k))).height;
      expect(h, greaterThanOrEqualTo(36), reason: k);
    }
  });

  testWidgets('the page is remembered per run type', (tester) async {
    final (_, services) = await open(tester);
    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);

    // A new screen for the same type opens on the map page.
    await pumpApp(tester, services, home: const SizedBox());
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    expect(find.byKey(_map), findsOneWidget);

    // Other run types keep the numbers.
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

  testWidgets('LAP and Pause / Stop are the same on both pages; the map page '
      'has no page-1 hero', (tester) async {
    await open(tester);
    final lap = tester.getSize(find.byType(LapButton));
    final stop = tester.getSize(find.byKey(const ValueKey('stop')));
    expect(find.byKey(const ValueKey('timer')), findsOneWidget);

    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);
    expect(tester.getSize(find.byType(LapButton)), lap);
    expect(tester.getSize(find.byKey(const ValueKey('stop'))), stop);
    // Numbers live on page 1 only.
    expect(find.byKey(const ValueKey('timer')), findsNothing);
    expect(find.byKey(const ValueKey('map-hero')), findsNothing);
  });

  testWidgets('4x4 rep: the rep average is page 1, the map page has no hero', (
    tester,
  ) async {
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
    expect(find.byKey(const ValueKey('segment-avg')), findsNothing);
    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('segment-avg')), findsOneWidget);
    expect(find.text('REP AVERAGE /km'), findsOneWidget);
  });

  testWidgets('free run page 1: no TRUE pace and no route readouts; they sit '
      'on the map page', (tester) async {
    final (fake, _) = await open(tester, mode: RecordMode.free);
    fake.elevGainM = 124;
    fake.advance(const Duration(seconds: 120));
    await pumpTimes(tester, 5);
    expect(find.textContaining('TRUE'), findsNothing);
    expect(find.byKey(const ValueKey('live-climb')), findsNothing);
    expect(find.byKey(_map), findsNothing);
    Text fig(String k) => tester.widget<Text>(find.byKey(ValueKey(k)));
    final size = fig('free-distance').style!.fontSize!;
    expect(size, greaterThanOrEqualTo(64));
    expect(fig('timer').style!.fontSize, lessThan(size));
    // 21-Oct review: average pace is demoted; the current-pace dial is the
    // second-largest number.
    expect(fig('run-average').style!.fontSize, lessThan(size));
    final dial = fig('dial-pace').style!.fontSize!;
    expect(dial, greaterThanOrEqualTo(56));
    expect(dial, lessThan(size));
    expect(dial, greaterThan(fig('run-average').style!.fontSize!));

    await tester.tap(find.byKey(_toggle));
    await settleAnimations(tester);
    expect(find.byKey(_map), findsOneWidget);
    expect(find.byKey(const ValueKey('live-climb')), findsOneWidget);
    expect(find.textContaining('TRUE'), findsNothing);
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

  Future<void> run(FakeRecorderGateway f, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      f.advance(const Duration(seconds: 1));
    }
  }

  testWidgets('a compare card slides over the map top; the GPS bar stays', (
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
