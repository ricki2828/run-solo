import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../route_fixtures.dart';
import '../run_fixtures.dart';

const _row = ValueKey('follow-route-row');
const _toGo = ValueKey('route-to-go');
const _strip = ValueKey('route-turn');

/// Page 2 of the run screen holds the map and every route readout.
Future<void> toMapPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('page-dots')));
  await settleAnimations(tester);
}

Future<(FakeRecorderGateway, AppServices)> openStart(
  WidgetTester tester, {
  RecordMode mode = RecordMode.free,
  bool goal = false,
  List<engine.SavedRoute> routes = const [],
  List<engine.RunFile> files = const [],
  FakeTransferGateway? transfer,
}) async {
  final fake = FakeRecorderGateway(now: now);
  final services = fakeServices(
    recorder: fake,
    routes: routes,
    files: files,
    transfer: transfer,
    settings: AppSettings(
      onboardingDone: true,
      lastMode: mode,
      goalRun: goal,
      goalId: goal ? 'd10000' : GoalChoice.eventId,
    ),
  );
  await pumpApp(tester, services, pushRoute: Routes.start);
  await pumpTimes(tester, 4);
  return (fake, services);
}

Future<(FakeRecorderGateway, AppServices)> openLive(
  WidgetTester tester, {
  RecordMode mode = RecordMode.free,
  engine.SessionSpec? goalSpec,
  AppSettings? settings,
  bool withRoute = true,
  MapSurfaceFactory maps = const FakeMapSurfaceFactory(available: true),
}) async {
  final fake = FakeRecorderGateway(now: now)..emitRoute = true;
  final services = fakeServices(
    recorder: fake,
    maps: maps,
    settings: settings ?? const AppSettings(onboardingDone: true),
  );
  await services.recording.start(
    mode,
    goalSpec?.toPigeon(),
    Units.km,
    route: withRoute ? testRoute().toFollowRoute() : null,
  );
  await pumpApp(tester, services, pushRoute: Routes.recording);
  await pumpTimes(tester, 4);
  expect(find.byType(RecordingScreen), findsOneWidget);
  fake.advance(const Duration(seconds: 3));
  await pumpTimes(tester, 3);
  return (fake, services);
}

void main() {
  group('Start: Follow a route', () {
    testWidgets('offered for Free, Trail and a Goal; not for Laps or tests', (
      tester,
    ) async {
      for (final (mode, goal, offered) in [
        (RecordMode.free, false, true),
        (RecordMode.trail, false, true),
        (RecordMode.free, true, true),
        (RecordMode.laps, false, false),
        (RecordMode.cooper, false, false),
      ]) {
        await openStart(tester, mode: mode, goal: goal);
        expect(
          find.byKey(_row),
          offered ? findsOneWidget : findsNothing,
          reason: '$mode goal=$goal',
        );
      }
    });

    testWidgets('import a GPX file: the route is chosen and START sends it', (
      tester,
    ) async {
      final transfer = FakeTransferGateway(
        toPickRoute: [PickedFile(name: 'Hill loop.gpx', text: gpxText())],
      );
      final (fake, services) = await openStart(tester, transfer: transfer);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('follow-privacy')), findsOneWidget);
      expect(find.byKey(const ValueKey('follow-turn-hints')), findsOneWidget);
      expect(find.byKey(const ValueKey('follow-empty')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('follow-import')));
      await settleAnimations(tester);

      // Chosen and saved.
      expect(services.routes.routes, hasLength(1));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('follow-route-name')))
            .data,
        'Hill loop',
      );
      expect(
        find.byKey(const ValueKey('follow-route-preview')),
        findsOneWidget,
      );
      expect(find.textContaining('GPX file'), findsOneWidget);
      expect(
        find.text('Turn hints come from the route shape, not trail data.'),
        findsOneWidget,
      );

      await readyAndGo(tester);
      await settleAnimations(tester);
      final sent = fake.startCalls.single.route!;
      expect(sent.name, 'Hill loop');
      expect(sent.latLon.length, greaterThan(4));
      expect(sent.elevM!.length, sent.latLon.length ~/ 2);
    });

    testWidgets('a file that is not a route says so and keeps the sheet', (
      tester,
    ) async {
      final transfer = FakeTransferGateway(
        toPickRoute: [const PickedFile(name: 'notes.gpx', text: '<gpx/>')],
      );
      final (_, services) = await openStart(tester, transfer: transfer);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('follow-import')));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('follow-error')), findsOneWidget);
      expect(find.textContaining('not a route'), findsOneWidget);
      expect(services.routes.routes, isEmpty);
    });

    testWidgets('a file over 10 MB says it is too big', (tester) async {
      final transfer = FakeTransferGateway(
        toPickRoute: [
          PickedFile(name: 'huge.gpx', text: 'x' * (kMaxRouteFileBytes + 1)),
        ],
      );
      final (_, services) = await openStart(tester, transfer: transfer);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('follow-import')));
      await settleAnimations(tester);
      expect(
        find.text('That file is too big for a route, max 10 MB'),
        findsOneWidget,
      );
      expect(services.routes.routes, isEmpty);
    });

    testWidgets('cancelling the picker changes nothing', (tester) async {
      final (_, services) = await openStart(tester);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('follow-import')));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('follow-error')), findsNothing);
      expect(services.routes.routes, isEmpty);
    });

    testWidgets('pick a saved route; clear it; START sends none', (
      tester,
    ) async {
      final (fake, _) = await openStart(tester, routes: [testRoute()]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      expect(find.text('Hill loop'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('route-route-1')));
      await settleAnimations(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('follow-route-name')))
            .data,
        'Hill loop',
      );
      expect(
        find.byKey(const ValueKey('follow-route-preview')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('follow-route-clear')));
      await settleAnimations(tester);
      expect(find.text('Repeat a route'), findsOneWidget);
      await readyAndGo(tester);
      await settleAnimations(tester);
      expect(fake.startCalls.single.route, isNull);
    });

    testWidgets('saved routes: a Repeat a route card says how many', (
      tester,
    ) async {
      await openStart(
        tester,
        routes: [
          testRoute(),
          testRoute(id: 'route-2', name: 'River'),
        ],
      );
      expect(find.text('Repeat a route'), findsOneWidget);
      expect(find.text('Pick one of your 2 routes'), findsOneWidget);
      expect(find.byKey(const ValueKey('follow-route-preview')), findsNothing);
    });

    testWidgets('no saved routes: the quiet row, no card', (tester) async {
      await openStart(tester);
      expect(find.text('Follow a route'), findsOneWidget);
      expect(find.text('Repeat a route'), findsNothing);
    });

    testWidgets('a picked route shows its map, Change reopens the sheet', (
      tester,
    ) async {
      await openStart(tester, routes: [testRoute()]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-route-1')));
      await settleAnimations(tester);
      expect(
        find.byKey(const ValueKey('follow-route-preview')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('follow-route-sub')), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('follow-route-change')),
      );
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('follow-turn-hints')), findsOneWidget);
    });

    testWidgets('the Ready screen draws the route being followed', (
      tester,
    ) async {
      await openStart(tester, routes: [testRoute()]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-route-1')));
      await settleAnimations(tester);
      await tapVisible(tester, find.byKey(const ValueKey('start-ready-up')));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('ready-route-preview')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('ready-route-line')))
            .data,
        startsWith('Hill loop'),
      );
    });

    testWidgets('a route picked, then a type that cannot follow, sends none', (
      tester,
    ) async {
      final (fake, services) = await openStart(tester, routes: [testRoute()]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-route-1')));
      await settleAnimations(tester);
      await services.settings.update(
        (s) => s.copyWith(lastMode: RecordMode.laps),
      );
      await settleAnimations(tester);
      expect(find.byKey(_row), findsNothing);
      await readyAndGo(tester);
      await settleAnimations(tester);
      expect(fake.startCalls.single.route, isNull);
    });

    testWidgets('delete asks first, then removes the route', (tester) async {
      final (_, services) = await openStart(tester, routes: [testRoute()]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-delete-route-1')));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-delete-cancel')));
      await settleAnimations(tester);
      expect(services.routes.routes, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('route-delete-route-1')));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('route-delete-confirm')));
      await settleAnimations(tester);
      expect(services.routes.routes, isEmpty);
      expect(find.byKey(const ValueKey('follow-empty')), findsOneWidget);
    });

    testWidgets('Run this route again: a past run becomes the route', (
      tester,
    ) async {
      final run = freeRunFile(n: 1, start: DateTime.utc(2026, 9, 24, 6));
      final (fake, services) = await openStart(tester, files: [run]);
      await tapVisible(tester, find.byKey(_row));
      await settleAnimations(tester);
      await tester.tap(find.byKey(const ValueKey('follow-past-run')));
      await settleAnimations(tester);
      expect(find.byKey(ValueKey('past-run-${run.id}')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('past-run-${run.id}')));
      await settleAnimations(tester);
      expect(services.routes.routes.single.id, 'run-${run.id}');
      expect(services.routes.routes.single.source, engine.RouteSource.run);
      await readyAndGo(tester);
      await settleAnimations(tester);
      expect(fake.startCalls.single.route!.id, 'run-${run.id}');
    });
  });

  group('live: route readouts sit on the map page', () {
    testWidgets('a free run shows distance and climb to go on page 2', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester);
      // Page 1 is the numbers only.
      expect(find.byKey(_toGo), findsNothing);
      await toMapPage(tester);
      expect(find.byKey(_toGo), findsOneWidget);
      final route = testRoute();
      // Nothing run yet: the whole route is to go (about 3 km, no more than
      // the weave in the track makes it).
      final toGo = tester.widget<Text>(
        find.byKey(const ValueKey('route-to-go-distance')),
      );
      expect(toGo.data, contains('km'));
      expect(
        find.byKey(const ValueKey('route-to-go-climb')),
        findsOneWidget,
        reason: 'the route has elevation (${route.climbM})',
      );
      for (final k in ['route-to-go-distance', 'route-to-go-climb']) {
        final fig = tester.widget<Text>(find.byKey(ValueKey(k)));
        expect(fig.style!.fontSize, greaterThanOrEqualTo(36), reason: k);
      }
      expect(fake.state, RecorderState.recording);
    });

    testWidgets('it counts down as the run goes on, and shows the next turn', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester);
      fake.routeProgress = RouteProgress(
        toGoM: 1234,
        climbToGoM: 45,
        off: false,
        turnLabel: 'Left turn',
        turnInM: 120,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      await toMapPage(tester);
      expect(find.text('1.23 km'), findsOneWidget);
      expect(find.text('45 m'), findsOneWidget);
      expect(find.text('Left turn in 120 m'), findsOneWidget);
    });

    testWidgets('the end of the route puts a big TURN AROUND card up', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester);
      expect(find.byKey(const ValueKey('route-end-card')), findsNothing);
      fake.routeProgress = RouteProgress(
        toGoM: 5,
        off: false,
        endCue: RouteEndCue.turnAround,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(find.text('TURN AROUND'), findsOneWidget);
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('route-end-text')),
      );
      expect(text.style!.fontSize, greaterThanOrEqualTo(36));
      // Still there on the map page, then gone once the recorder clears it.
      await toMapPage(tester);
      expect(find.text('TURN AROUND'), findsOneWidget);
      fake.routeProgress = RouteProgress(toGoM: 5, off: false);
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(find.text('TURN AROUND'), findsNothing);
    });

    testWidgets('a loop that ends where it began says ROUTE DONE', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester);
      fake.routeProgress = RouteProgress(
        toGoM: 5,
        off: false,
        endCue: RouteEndCue.done,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(find.text('ROUTE DONE'), findsOneWidget);
      expect(find.text('TURN AROUND'), findsNothing);
    });

    testWidgets('miles users read yards for the next turn', (tester) async {
      final fake = FakeRecorderGateway(now: now)..emitRoute = true;
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(onboardingDone: true, units: Units.mi),
      );
      await services.recording.start(
        RecordMode.free,
        null,
        Units.mi,
        route: testRoute().toFollowRoute(),
      );
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      fake.routeProgress = RouteProgress(
        toGoM: 3000,
        off: false,
        turnLabel: 'Left turn',
        turnInM: 100,
      );
      fake.advance(const Duration(seconds: 3));
      await pumpTimes(tester, 3);
      await toMapPage(tester);
      // 100 m is 109 yd, shown as 110.
      expect(find.text('Left turn in 110 yd'), findsOneWidget);
      expect(find.textContaining('mi'), findsWidgets); // to go in miles
    });

    testWidgets('off route says OFF ROUTE in warn and drops the turn', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester);
      fake.routeProgress = RouteProgress(
        toGoM: 900,
        off: true,
        turnLabel: 'Left turn',
        turnInM: 50,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      await toMapPage(tester);
      expect(find.text('OFF ROUTE'), findsOneWidget);
      expect(find.byKey(const ValueKey('route-turn')), findsNothing);
      expect(
        find.byKey(const ValueKey('route-to-go-climb')),
        findsNothing,
        reason: 'no climb figure when the route has none',
      );
    });

    testWidgets('a run that follows nothing shows no to-go line', (
      tester,
    ) async {
      await openLive(tester, withRoute: false);
      expect(find.byKey(_toGo), findsNothing);
    });

    testWidgets(
      'a goal run: the to-go strip is on page 2, its hero on page 1',
      (tester) async {
        await openLive(
          tester,
          mode: RecordMode.intervals,
          goalSpec: engine.SessionSpec.goalDistance(10000, '10K'),
        );
        expect(find.byKey(const ValueKey('event-to-go')), findsOneWidget);
        expect(find.byKey(_toGo), findsNothing);
        await toMapPage(tester);
        expect(find.byKey(_toGo), findsOneWidget);
      },
    );
  });

  group('live: MAP', () {
    const mapOn = AppSettings(onboardingDone: true, liveMapTypes: {'free'});

    testWidgets('the to-go line and the map share page 2; no run hero', (
      tester,
    ) async {
      final (fake, _) = await openLive(tester, settings: mapOn);
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
      fake.routeProgress = RouteProgress(
        toGoM: 2500,
        climbToGoM: 80,
        off: false,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(find.byKey(const ValueKey('map-hero')), findsNothing);
      final dist = tester.widget<Text>(
        find.byKey(const ValueKey('route-to-go-distance')),
      );
      expect(dist.data, '2.50 km');
      expect(dist.style!.fontSize, greaterThanOrEqualTo(36));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('route-to-go-climb')))
            .data,
        '80 m',
      );
    });

    testWidgets('a close turn shows, off route overrides it', (tester) async {
      final (fake, _) = await openLive(tester, settings: mapOn);
      fake.routeProgress = RouteProgress(
        toGoM: 2500,
        off: false,
        turnLabel: 'Keep right',
        turnInM: 80,
      );
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(
        tester.widget<Text>(find.byKey(_strip)).data,
        'Keep right in 80 m',
      );
      fake.routeProgress = RouteProgress(toGoM: 2500, off: true);
      fake.advance(const Duration(seconds: 2));
      await pumpTimes(tester, 3);
      expect(find.text('OFF ROUTE'), findsOneWidget);
      expect(find.byKey(_strip), findsNothing);
    });

    testWidgets('no strip when the run follows nothing', (tester) async {
      await openLive(tester, settings: mapOn, withRoute: false);
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
      expect(find.byKey(_strip), findsNothing);
    });
  });

  group('terrain map', () {
    Future<void> map(WidgetTester tester, RecordMode mode, String type) async {
      await openLive(
        tester,
        mode: mode,
        withRoute: false,
        settings: AppSettings(onboardingDone: true, liveMapTypes: {type}),
      );
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
    }

    testWidgets('Free and Trail runs ask for terrain', (tester) async {
      await map(tester, RecordMode.free, 'free');
      expect(find.byKey(const ValueKey('fake-terrain')), findsOneWidget);
      await map(tester, RecordMode.trail, 'trail');
      expect(find.byKey(const ValueKey('fake-terrain')), findsOneWidget);
    });

    testWidgets('Laps keep the night style', (tester) async {
      await map(tester, RecordMode.laps, 'laps');
      expect(find.byKey(const ValueKey('fake-terrain')), findsNothing);
    });

    test('the rule', () {
      expect(usesTerrainMap(RecordMode.free), isTrue);
      expect(usesTerrainMap(RecordMode.trail), isTrue);
      for (final m in [
        RecordMode.laps,
        RecordMode.intervals,
        RecordMode.cooper,
      ]) {
        expect(usesTerrainMap(m), isFalse);
      }
    });
  });
}
