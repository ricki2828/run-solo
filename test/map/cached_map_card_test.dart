@Timeout(Duration(seconds: 30))
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/cached_map_card.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/map/render_queue.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/map/snapshot_cache.dart';
import 'package:run_solo/theme/theme.dart';

// 1x1 transparent PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const _route = RouteGeometry(
  points: [GeoPoint(-33.0, 151.0), GeoPoint(-33.01, 151.01)],
  markers: [],
  bounds: GeoBounds(south: -33.01, west: 151.0, north: -33.0, east: 151.01),
);

/// In-memory store: no real file I/O, so everything completes under pump.
class _MemStore implements MapCardStore {
  final files = <String, Uint8List>{};
  final failed = <String>{};

  @override
  Future<Uint8List?> read(String key) async => files[key];
  @override
  Future<void> write(String key, Uint8List png) async => files[key] = png;
  @override
  Future<bool> mayRender(String key) async =>
      !failed.contains(MapSnapshotCache.failureKey(key));
  @override
  Future<void> recordFailure(String key, MapFailure kind) async =>
      failed.add(MapSnapshotCache.failureKey(key));
  @override
  Future<void> clearFailures(String key) async =>
      failed.remove(MapSnapshotCache.failureKey(key));
}

void main() {
  late _MemStore cache;
  late RenderQueue queue;
  final emit = <String, void Function(Uint8List)>{};
  final fail = <String, ValueChanged<MapFailure>>{};
  final renders = <String>[];

  setUp(() {
    cache = _MemStore();
    queue = RenderQueue();
    emit.clear();
    fail.clear();
    renders.clear();
  });

  String keyFor(String id, {String hash = 'h1'}) => MapSnapshotCache.keyFor(
    runId: id,
    styleVersion: kMapStyleVersion,
    routeHash: hash,
    width: 300,
    height: 148,
    pixelRatio: 3.0, // flutter_test default
  );

  Widget card(String id, {String hash = 'h1'}) => SizedBox(
    width: 300,
    height: 148,
    child: CachedMapCard(
      key: ValueKey('card-$id'),
      route: _route,
      routeColor: Colors.orange,
      cache: cache,
      queue: queue,
      cacheKey: (s, dpr) => MapSnapshotCache.keyFor(
        runId: id,
        styleVersion: kMapStyleVersion,
        routeHash: hash,
        width: s.width,
        height: s.height,
        pixelRatio: dpr,
      ),
      renderer: (size, onSnapshot, onFailed) {
        if (!renders.contains(id)) renders.add(id);
        emit[id] = onSnapshot;
        fail[id] = onFailed;
        return SizedBox.expand(key: ValueKey('live-$id'));
      },
    ),
  );

  Widget host(List<Widget> cards) => MaterialApp(
    theme: runSoloTheme(),
    home: Column(children: cards),
  );

  // Store futures are microtask-only; a few pumps flush each await.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  testWidgets('miss: shape at once, render once, then image + overlay', (
    tester,
  ) async {
    await tester.pumpWidget(host([card('r1')]));
    expect(find.byType(RouteShape), findsOneWidget);
    await settle(tester);
    expect(renders, ['r1']);
    expect(find.byKey(const ValueKey('live-r1')), findsOneWidget);

    emit['r1']!(_png);
    await settle(tester);
    expect(find.byKey(const ValueKey('card-map-image')), findsOneWidget);
    // Route is drawn over the image, in the given colour, transparent bg.
    final shape = tester.widget<RouteShape>(find.byType(RouteShape));
    expect(shape.overlay, isTrue);
    expect(shape.color, Colors.orange);
    expect(find.byKey(const ValueKey('live-r1')), findsNothing);
    expect(cache.files[keyFor('r1')], _png);
    expect(queue.pending, 0);
  });

  testWidgets('hit: image straight away, no live map', (tester) async {
    cache.files[keyFor('r1')] = _png;
    await tester.pumpWidget(host([card('r1')]));
    await settle(tester);
    expect(find.byKey(const ValueKey('card-map-image')), findsOneWidget);
    expect(renders, isEmpty);
  });

  testWidgets('route change invalidates the cached image', (tester) async {
    cache.files[keyFor('r1')] = _png;
    await tester.pumpWidget(host([card('r1', hash: 'h2')]));
    await settle(tester);
    expect(find.byKey(const ValueKey('card-map-image')), findsNothing);
    expect(renders, ['r1']);
  });

  testWidgets('concurrency: one live map at a time, others wait', (
    tester,
  ) async {
    await tester.pumpWidget(host([card('a'), card('b'), card('c')]));
    await settle(tester);
    expect(renders, ['a']);
    expect(find.byKey(const ValueKey('live-b')), findsNothing);
    emit['a']!(_png);
    await settle(tester);
    expect(renders, ['a', 'b']);
    expect(find.byKey(const ValueKey('live-c')), findsNothing);
  });

  testWidgets('a queued card that goes away gives up its turn', (tester) async {
    await tester.pumpWidget(host([card('a'), card('b'), card('c')]));
    await settle(tester);
    // b leaves while queued.
    await tester.pumpWidget(host([card('a'), card('c')]));
    await settle(tester);
    emit['a']!(_png);
    await settle(tester);
    expect(renders, ['a', 'c']);
  });

  testWidgets('failure: shape stays, no caption, no retry this session', (
    tester,
  ) async {
    await tester.pumpWidget(host([card('r1')]));
    await settle(tester);
    expect(renders, ['r1']);
    fail['r1']!(MapFailure.transient);
    await settle(tester);
    expect(find.byType(RouteShape), findsOneWidget);
    expect(find.text('Map failed to load'), findsNothing);
    expect(find.byKey(const ValueKey('live-r1')), findsNothing);
    expect(queue.pending, 0);
    // Remount in the same session: not retried.
    await tester.pumpWidget(host([]));
    renders.clear();
    await tester.pumpWidget(host([card('r1')]));
    await settle(tester);
    expect(renders, isEmpty);
  });

  testWidgets('zero-size layout defers until sized, no render', (tester) async {
    await tester.pumpWidget(
      host([
        SizedBox(
          width: 0,
          height: 0,
          child: CachedMapCard(
            route: _route,
            cache: cache,
            queue: queue,
            cacheKey: (s, d) => 'x',
            renderer: (a, b, c) {
              renders.add('zero');
              return const SizedBox();
            },
          ),
        ),
      ]),
    );
    await settle(tester);
    expect(renders, isEmpty);
    expect(queue.pending, 0);
  });

  testWidgets('fake factory card is the route shape', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Builder(
          builder: (c) =>
              const FakeMapSurfaceFactory(available: true)
                  .buildCard(c, _route, runId: 'r1', routeColor: Colors.orange),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('fake-card-map')), findsOneWidget);
  });
}
