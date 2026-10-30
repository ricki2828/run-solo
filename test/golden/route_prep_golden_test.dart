import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../route_fixtures.dart';

/// Route on the prep screens (30-Oct): Start's "Repeat a route" card, Start
/// with a route picked (its map), and Ready with the route drawn. Rendered on
/// CI; a missing PNG fails, commit it from the `goldens-pr-<N>` release.
Future<void> golden(WidgetTester tester, String name) async {
  expect(
    File('test/golden/goldens/$name.png').existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens release',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

AppServices services(RecordMode mode, List<engine.SavedRoute> routes) =>
    fakeServices(
      routes: routes,
      settings: AppSettings(onboardingDone: true, lastMode: mode),
    );

Future<void> pickRoute2(WidgetTester tester) async {
  await pumpApp(
    tester,
    services(RecordMode.trail, _routes),
    pushRoute: Routes.start,
  );
  await pumpTimes(tester, 4);
  await tapVisible(tester, find.byKey(const ValueKey('follow-route-row')));
  await settleAnimations(tester);
  await tester.tap(find.byKey(const ValueKey('route-route-2')));
  await settleAnimations(tester);
}

/// A loop with a spur, so the picture shows a shape rather than a line.
engine.SavedRoute loopRoute() => engine.RouteBuilder.build(
  id: 'route-2',
  name: 'River path',
  raw: [
    for (var i = 0; i <= 200; i++)
      engine.RoutePoint(
        routeLat0 +
            0.012 * math.sin(i / 200 * 2 * math.pi) +
            0.004 * math.sin(i / 200 * 6 * math.pi),
        routeLon0 + 0.018 * (1 - math.cos(i / 200 * 2 * math.pi)),
        30 + 25 * math.sin(i / 200 * 4 * math.pi),
      ),
  ],
  source: engine.RouteSource.gpx,
  createdAt: DateTime.utc(2026, 10, 2, 8),
);

final _routes = [
  testRoute(),
  loopRoute(),
  testRoute(id: 'route-3', name: 'Ridge', lengthM: 2400),
];

void main() {
  for (final (mode, tag) in [
    (RecordMode.free, 'free'),
    (RecordMode.trail, 'trail'),
  ]) {
    testWidgets('start: $tag run, routes saved, none picked', (tester) async {
      await pumpApp(tester, services(mode, _routes), pushRoute: Routes.start);
      await pumpTimes(tester, 4);
      await settleAnimations(tester);
      expect(find.text('Pick one of your 3 routes'), findsOneWidget);
      await golden(tester, 'start_route_none_${tag}_360x640');
    });
  }

  testWidgets('start: trail run, route picked, map preview', (tester) async {
    await pickRoute2(tester);
    await golden(tester, 'start_route_picked_trail_360x640');
  });

  testWidgets('ready: trail run following a route', (tester) async {
    await pickRoute2(tester);
    final up = find.byKey(const ValueKey('start-ready-up'));
    await tester.ensureVisible(up);
    await tester.tap(up);
    await pumpTimes(tester, 3);
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('ready-route-preview')), findsOneWidget);
    await golden(tester, 'ready_route_trail_360x640');
  });
}
