import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/followed_route_line.dart';

import '../helpers.dart';
import '../route_fixtures.dart';
import '../run_fixtures.dart';

/// Save the followed route with the run: run detail (planned vs actual,
/// the summary line), History's badge, and "Run this route again".
void main() {
  final start = DateTime(2026, 9, 24, 6).toUtc();
  final plain = freeRunFile(n: 1, start: start);
  final followed = withFollowedRoute(freeRunFile(n: 2, start: start));

  Future<void> openDetail(WidgetTester tester, engine.RunFile run) async {
    await pumpApp(
      tester,
      fakeServices(
        files: [run],
        maps: const FakeMapSurfaceFactory(available: true),
      ),
      home: RunDetailScreen(runId: run.id),
    );
    await pumpTimes(tester, 8);
  }

  group('summary line', () {
    test('off route Nx for m:ss, or stayed on route', () {
      expect(
        followedRouteSummary(followed.route!),
        'Followed: Hill loop, off route 2x for 1:40',
      );
      expect(
        followedRouteSummary(withFollowedRoute(plain, off: const []).route!),
        'Followed: Hill loop, stayed on route',
      );
      expect(
        followedRouteSummary(
          withFollowedRoute(plain, off: const [(0, 37000)]).route!,
        ),
        'Followed: Hill loop, off route 1x for 0:37',
      );
    });
  });

  group('run detail', () {
    testWidgets('planned under actual on the map, and the summary', (
      tester,
    ) async {
      await openDetail(tester, followed);
      expect(
        find.text('Followed: Hill loop, off route 2x for 1:40'),
        findsOneWidget,
      );
      final shape = tester.widget<RouteShape>(
        find.byKey(const ValueKey('fake-map')),
      );
      expect(shape.plan, isNotNull);
      expect(shape.plan!.length, followed.route!.points.length);
      expect(shape.color, isNotNull, reason: 'the run keeps its type colour');
    });

    testWidgets('a run that followed nothing has neither', (tester) async {
      await openDetail(tester, plain);
      expect(find.byKey(const ValueKey('followed-route-line')), findsNothing);
      final shape = tester.widget<RouteShape>(
        find.byKey(const ValueKey('fake-map')),
      );
      expect(shape.plan, isNull);
    });
  });

  group('store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runsolo-route-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the file store keeps the route through a write and a read', () async {
      final store = FileRunStore(Directory('${dir.path}/runs'));
      await store.importBundles([engine.RunBundle(run: followed)]);
      final back = (await store.load(followed.id))!.run;
      expect(back.route!.name, 'Hill loop');
      expect(back.route!.points.length, followed.route!.points.length);
      expect(back.route!.offRouteCount, 2);
      await store.derivedIdle;
    });

    test('the index row carries the route for History', () {
      final row = IndexRow.of(followed, null, null);
      expect(row.routeName, 'Hill loop');
      expect(row.routeOffCount, 2);
      expect(row.routeOffMs, 100000);
      final back = IndexRow.fromJson(row.toJson())!;
      expect(back.routeName, 'Hill loop');
      expect(back.routeOffCount, 2);
      expect(IndexRow.of(plain, null, null).routeName, isNull);
      // A row from before the route keys has none and reads fine.
      final old = row.toJson()
        ..remove('route_name')
        ..remove('route_off_n')
        ..remove('route_off_ms');
      expect(IndexRow.fromJson(old)!.routeName, isNull);
    });

    testWidgets('History shows the badge only on the run that followed one', (
      tester,
    ) async {
      final store = FileRunStore(Directory('${dir.path}/runs'));
      await tester.runAsync(() async {
        await store.importBundles([
          engine.RunBundle(run: plain),
          engine.RunBundle(run: followed),
        ]);
        await store.list();
        await store.derivedIdle;
      });
      await pumpApp(
        tester,
        fakeServices(history: store),
        home: const HistoryScreen(),
      );
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester);
      expect(find.byType(HistoryRow), findsNWidgets(2));
      expect(
        find.byKey(ValueKey('route-badge-${followed.id}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('route-badge-${plain.id}')), findsNothing);
      await tester.runAsync(() => store.derivedIdle);
    });
  });

  testWidgets('Run this route again prefers the stored planned route', (
    tester,
  ) async {
    final services = fakeServices(
      files: [followed],
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await tapVisible(tester, find.byKey(const ValueKey('follow-route-row')));
    await settleAnimations(tester);
    await tester.tap(find.byKey(const ValueKey('follow-past-run')));
    await settleAnimations(tester);
    await tester.tap(find.byKey(ValueKey('past-run-${followed.id}')));
    await settleAnimations(tester);
    final saved = services.routes.routes.single;
    expect(saved.id, 'route-1', reason: 'the route it followed, not run-<id>');
    expect(saved.name, 'Hill loop');
    expect(saved.source, engine.RouteSource.run);
    expect(saved.climbM, isNotNull);
  });
}
