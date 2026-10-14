@Timeout(Duration(seconds: 30))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/map/cached_map_card.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/map/snapshot_cache.dart';
import 'package:run_solo/map/render_queue.dart';
import 'package:run_solo/map/retrace_tracker.dart';
import 'package:run_solo/map/topo_map_surface.dart';
import 'package:run_solo/state/live_route.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/topo/pack_manager.dart';
import 'package:run_solo/topo/pack_models.dart';

/// A pack manager whose installed set is whatever the test says.
class _Packs extends PackManager {
  _Packs(this.packs) : super(root: Directory.systemTemp);
  List<InstalledPack> packs;

  @override
  List<InstalledPack> get installed => packs;

  @override
  InstalledPack? packCovering(double lat, double lon) {
    InstalledPack? best;
    for (final p in packs) {
      if (!p.region.contains(lat, lon)) continue;
      if (best == null || p.region.area < best.region.area) best = p;
    }
    return best;
  }

  void set(List<InstalledPack> next) {
    packs = next;
    notifyListeners();
  }
}

InstalledPack _pack(
  String id,
  List<double> bbox, {
  String text = 'OSM | Protomaps',
}) => InstalledPack(
  region: PackRegion(
    id: id,
    name: id,
    bbox: bbox,
    version: '1',
    files: const [PackFileSpec(name: 'basemap.pmtiles', size: 1, sha256: 'a')],
    mapText: text,
    credits: const [
      PackCredit(text: '© OpenStreetMap contributors', license: 'ODbL 1.0'),
    ],
  ),
  directory: '/x/$id',
);

/// Boxes for tests: lon 24.3-24.55, lat 36.64-36.76 (Milos).
final _milos = _pack('milos', const [24.3, 36.64, 24.55, 36.76]);

class _FakeEngine implements TopoEngine {
  final List<String> built = [];

  @override
  Widget detail(
    InstalledPack pack, {
    required RouteGeometry route,
    List<GeoPoint>? plan,
    Color? routeColor,
    bool interactive = false,
  }) {
    built.add('detail:${pack.id}');
    return SizedBox.expand(key: ValueKey('topo-detail-${pack.id}'));
  }

  @override
  Widget live(
    InstalledPack pack, {
    required LiveRouteTrack track,
    required Color color,
    List<GeoPoint>? plan,
    RetraceInput? retrace,
  }) {
    built.add('live:${pack.id}');
    return SizedBox.expand(key: ValueKey('topo-live-${pack.id}'));
  }

  @override
  Widget card(
    InstalledPack pack,
    RouteGeometry route, {
    required Color routeColor,
    required ValueChanged<Uint8List> onSnapshot,
    required ValueChanged<MapFailure> onFailed,
  }) {
    built.add('card:${pack.id}');
    return SizedBox.expand(key: ValueKey('topo-card-${pack.id}'));
  }
}

class _MemStore implements MapCardStore {
  final reads = <String>[];
  @override
  Future<Uint8List?> read(String key) async {
    reads.add(key);
    return null;
  }

  @override
  Future<void> write(String key, Uint8List png) async {}
  @override
  Future<bool> mayRender(String key) async => true;
  @override
  Future<void> recordFailure(String key, MapFailure kind) async {}
  @override
  Future<void> clearFailures(String key) async {}
}

RouteGeometry _route(double lat, double lon) => RouteGeometry(
  points: [GeoPoint(lat, lon), GeoPoint(lat + 0.01, lon + 0.01)],
  markers: const [],
  bounds: GeoBounds(south: lat, west: lon, north: lat + 0.01, east: lon + 0.01),
);

final _inMilos = _route(36.7, 24.4);
final _inSingapore = _route(1.3, 103.8);

void main() {
  late _Packs packs;
  late SettingsController settings;
  late _FakeEngine engine;
  late _MemStore store;
  late TopoMapSurfaceFactory factory;
  final pushed = <String?>[];

  setUp(() {
    packs = _Packs([_milos]);
    settings = SettingsController(MemorySettingsStore(const AppSettings()));
    engine = _FakeEngine();
    store = _MemStore();
    pushed.clear();
    factory = TopoMapSurfaceFactory(
      packs: packs,
      settings: settings,
      fallback: const FakeMapSurfaceFactory(available: true),
      engine: engine,
      cache: store,
      queue: RenderQueue(),
    );
  });

  Widget host(Widget Function(BuildContext) body) => MaterialApp(
    theme: runSoloTheme(),
    onGenerateRoute: (s) {
      pushed.add(s.name);
      if (s.name == '/') {
        return MaterialPageRoute<void>(
          settings: s,
          builder: (c) =>
              Scaffold(body: SizedBox(width: 360, height: 270, child: body(c))),
        );
      }
      return MaterialPageRoute<void>(
        settings: s,
        builder: (_) => const Scaffold(body: Text('offline maps page')),
      );
    },
  );

  Widget detail(BuildContext c, RouteGeometry r, {bool terrain = true}) =>
      factory.build(c, r, terrain: terrain, routeColor: Colors.orange);

  testWidgets('Free/Trail run inside a pack: Topo, attribution, toggle', (
    tester,
  ) async {
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    expect(find.byKey(const ValueKey('topo-detail-milos')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-map')), findsNothing);
    expect(find.byKey(const ValueKey('map-style-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('topo-attribution')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('topo-attribution'))).data,
      '© OSM · Protomaps',
    );
  });

  testWidgets('the credit line opens the full credits', (tester) async {
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    await tester.tap(find.byKey(const ValueKey('topo-credits-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topo-credits-sheet')), findsOneWidget);
    expect(find.text('Map data'), findsOneWidget);
    expect(find.textContaining('ODbL'), findsOneWidget);
  });

  testWidgets('toggle: Google then back, remembered in settings', (
    tester,
  ) async {
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    await tester.tap(find.byKey(const ValueKey('map-style-google')));
    await tester.pump();
    expect(settings.settings.topoMap, isFalse);
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('topo-detail-milos')), findsNothing);
    expect(find.byKey(const ValueKey('topo-attribution')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('map-style-topo')));
    await tester.pump();
    expect(settings.settings.topoMap, isTrue);
    expect(find.byKey(const ValueKey('topo-detail-milos')), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-map')), findsNothing);
  });

  testWidgets('remembered Google choice starts on Google', (tester) async {
    await settings.update((s) => s.copyWith(topoMap: false));
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(engine.built, isEmpty);
    expect(find.byKey(const ValueKey('map-download-prompt')), findsNothing);
  });

  testWidgets('no pack covers: Google stays and a prompt opens Offline maps', (
    tester,
  ) async {
    await tester.pumpWidget(host((c) => detail(c, _inSingapore)));
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(engine.built, isEmpty);
    expect(find.text(kDownloadMapPrompt), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-download-prompt')));
    await tester.pumpAndSettle();
    expect(pushed, contains(Routes.offlineMaps));
    expect(find.text('offline maps page'), findsOneWidget);
  });

  testWidgets('a pack that holds only part of the route does not count', (
    tester,
  ) async {
    // Starts in Milos, runs off the east edge.
    final wide = RouteGeometry(
      points: const [GeoPoint(36.7, 24.4), GeoPoint(36.7, 24.7)],
      markers: const [],
      bounds: const GeoBounds(south: 36.7, west: 24.4, north: 36.7, east: 24.7),
    );
    await tester.pumpWidget(host((c) => detail(c, wide)));
    expect(engine.built, isEmpty);
    expect(find.text(kDownloadMapPrompt), findsOneWidget);
  });

  testWidgets('installing a pack while the map is open switches to Topo', (
    tester,
  ) async {
    packs.packs = [];
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    expect(find.text(kDownloadMapPrompt), findsOneWidget);
    packs.set([_milos]);
    await tester.pump();
    expect(find.byKey(const ValueKey('topo-detail-milos')), findsOneWidget);
    expect(find.text(kDownloadMapPrompt), findsNothing);
  });

  testWidgets('other run types never see Topo or the toggle', (tester) async {
    await tester.pumpWidget(host((c) => detail(c, _inMilos, terrain: false)));
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-style-toggle')), findsNothing);
    expect(find.text(kDownloadMapPrompt), findsNothing);
  });

  testWidgets('tightest pack wins where two cover', (tester) async {
    final big = _pack('region', const [20, 30, 30, 40]);
    packs.set([big, _milos]);
    await tester.pumpWidget(host((c) => detail(c, _inMilos)));
    expect(find.byKey(const ValueKey('topo-detail-milos')), findsOneWidget);
  });

  group('live', () {
    setUp(() async {
      await settings.update((s) => s.copyWith(liveTopoMap: true));
    });

    testWidgets('waits for a fix, then follows in Topo', (tester) async {
      final track = LiveRouteTrack();
      await tester.pumpWidget(
        host(
          (c) => factory.buildLive(
            c,
            track: track,
            color: Colors.orange,
            terrain: true,
          ),
        ),
      );
      // No fix yet: the Google side's (fake) map, nothing from Topo.
      expect(engine.built, isEmpty);
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
      track.apply(0, [36.7, 24.4]);
      await tester.pump();
      expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-live-map')), findsNothing);
    });

    testWidgets('one engine at a time across a toggle', (tester) async {
      final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
      await tester.pumpWidget(
        host(
          (c) => factory.buildLive(
            c,
            track: track,
            color: Colors.orange,
            terrain: true,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('map-style-google')));
      await tester.pump();
      expect(find.byKey(const ValueKey('topo-live-milos')), findsNothing);
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
    });

    testWidgets(
      'a fix just over the edge keeps Topo; leaving for real does not',
      (tester) async {
        final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
        await tester.pumpWidget(
          host(
            (c) => factory.buildLive(
              c,
              track: track,
              color: Colors.orange,
              terrain: true,
            ),
          ),
        );
        expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
        // Still inside: stays.
        track.apply(1, [36.71, 24.45]);
        await tester.pump();
        expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
        // Out of the box with no other pack: Google.
        track.apply(2, [36.7, 24.9]);
        await tester.pump();
        expect(find.byKey(const ValueKey('topo-live-milos')), findsNothing);
        expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
        expect(find.text(kDownloadMapPrompt), findsOneWidget);
      },
    );

    testWidgets('not a Free/Trail run: straight to the fallback', (
      tester,
    ) async {
      final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
      await tester.pumpWidget(
        host((c) => factory.buildLive(c, track: track, color: Colors.orange)),
      );
      expect(engine.built, isEmpty);
      expect(find.byKey(const ValueKey('map-style-toggle')), findsNothing);
    });
  });

  group('cards', () {
    testWidgets(
      'Free/Trail card in a pack renders from Topo, key has the engine',
      (tester) async {
        await tester.pumpWidget(
          host(
            (c) => factory.buildCard(
              c,
              _inMilos,
              runId: 'run-1',
              routeColor: Colors.orange,
              terrain: true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(store.reads, hasLength(1));
        expect(store.reads.single, contains('-topo-milos-1-'));
        expect(store.reads.single, startsWith('run-1_v$kMapStyleVersion-topo'));
        expect(find.byKey(const ValueKey('topo-card-milos')), findsOneWidget);
        // The credit line sits on the card; the route is baked into the image.
        expect(find.byKey(const ValueKey('topo-attribution')), findsOneWidget);
        expect(
          tester.widget<CachedMapCard>(find.byType(CachedMapCard)).bakedRoute,
          isTrue,
        );
      },
    );

    testWidgets('card outside any pack, or not terrain, is the Google card', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          (c) => Column(
            children: [
              SizedBox(
                height: 100,
                child: factory.buildCard(
                  c,
                  _inSingapore,
                  runId: 'a',
                  terrain: true,
                ),
              ),
              SizedBox(
                height: 100,
                child: factory.buildCard(c, _inMilos, runId: 'b'),
              ),
            ],
          ),
        ),
      );
      expect(find.byKey(const ValueKey('fake-card-map')), findsNWidgets(2));
      expect(engine.built, isEmpty);
    });

    testWidgets('card with Google chosen stays Google', (tester) async {
      await settings.update((s) => s.copyWith(topoMap: false));
      await tester.pumpWidget(
        host((c) => factory.buildCard(c, _inMilos, runId: 'a', terrain: true)),
      );
      expect(find.byKey(const ValueKey('fake-card-map')), findsOneWidget);
    });
  });

  test('engine is part of the snapshot key, Google keys are unchanged', () {
    String key(String engine) => MapSnapshotCache.keyFor(
      runId: 'r',
      styleVersion: 4,
      routeHash: 'h',
      width: 300,
      height: 148,
      pixelRatio: 3,
      engine: engine,
    );
    expect(key(''), 'r_v4_h_300x148@3.00');
    expect(key('topo-milos-1'), 'r_v4-topo-milos-1_h_300x148@3.00');
    expect(MapSnapshotCache.runPrefix(key('topo-milos-1')), 'r');
    expect(
      MapSnapshotCache.failureKey(key('topo-milos-1')),
      isNot(MapSnapshotCache.failureKey(key(''))),
    );
  });

  test('needsGoogle and available follow the pack and the choice', () async {
    expect(factory.needsGoogle(_inMilos, terrain: true), isFalse);
    expect(factory.needsGoogle(_inMilos), isTrue);
    expect(factory.needsGoogle(_inSingapore, terrain: true), isTrue);
    await settings.update((s) => s.copyWith(topoMap: false));
    expect(factory.needsGoogle(_inMilos, terrain: true), isTrue);

    // No Maps key, but a pack: maps are available.
    final packOnly = TopoMapSurfaceFactory(
      packs: packs,
      settings: settings,
      fallback: const FakeMapSurfaceFactory(),
      engine: engine,
    );
    expect(packOnly.available, isTrue);
    packs.packs = [];
    expect(packOnly.available, isFalse);
  });

  group('credit line', () {
    test('short whole names from the pack text', () {
      expect(
        creditNames(
          '© OpenStreetMap contributors | Protomaps | © Mapterhorn | Copernicus DEM',
        ),
        ['OSM', 'Protomaps', 'Mapterhorn', 'Copernicus'],
      );
      expect(creditNames(''), isEmpty);
    });

    test('drops whole names, never cuts one, always one line', () {
      const style = TextStyle(fontSize: 11);
      const names = ['OSM', 'Protomaps', 'Mapterhorn', 'Copernicus'];
      String line(double w) => creditLine(names, w, style, TextDirection.ltr);
      expect(line(1000), '© OSM · Protomaps · Mapterhorn · Copernicus');
      final narrow = line(150);
      expect(narrow, endsWith(' …'));
      expect(narrow, isNot(contains('\n')));
      for (final part
          in narrow.replaceAll('© ', '').replaceAll(' …', '').split(' · ')) {
        expect(names, contains(part));
      }
      expect(line(1), '©');
    });
  });

  group('live map: Google first', () {
    final climb = [
      for (var i = 0; i < 12; i++) GeoPoint(36.7 + i * 1e-4, 24.4, 50.0 + i),
    ];

    Widget live(BuildContext c, LiveRouteTrack t, {List<GeoPoint>? plan}) =>
        factory.buildLive(
          c,
          track: t,
          color: Colors.orange,
          plan: plan,
          terrain: true,
        );

    testWidgets('inside a pack the default is still Google', (tester) async {
      final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
      await tester.pumpWidget(host((c) => live(c, track)));
      expect(find.byKey(const ValueKey('fake-live-map')), findsOneWidget);
      expect(engine.built, isEmpty);
      expect(find.text(kDownloadMapPrompt), findsNothing);
    });

    testWidgets('the toggle picks Topo for the live map only', (tester) async {
      final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
      await tester.pumpWidget(host((c) => live(c, track)));
      await tester.tap(find.byKey(const ValueKey('map-style-topo')));
      await tester.pump();
      expect(settings.settings.liveTopoMap, isTrue);
      expect(settings.settings.topoMap, isTrue);
      expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('map-style-google')));
      await tester.pump();
      expect(settings.settings.liveTopoMap, isFalse);
      // Run detail's own choice is untouched.
      expect(settings.settings.topoMap, isTrue);
    });

    testWidgets('no Google map on the phone: Topo where a pack covers', (
      tester,
    ) async {
      factory = TopoMapSurfaceFactory(
        packs: packs,
        settings: settings,
        fallback: const FakeMapSurfaceFactory(),
        engine: engine,
        cache: store,
        queue: RenderQueue(),
      );
      final track = LiveRouteTrack()..apply(0, [36.7, 24.4]);
      await tester.pumpWidget(host((c) => live(c, track)));
      expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
    });

    testWidgets('no gradient key on the live map, with or without elevation', (
      tester,
    ) async {
      await settings.update((s) => s.copyWith(liveTopoMap: true));
      final track = LiveRouteTrack()
        ..apply(0, [36.7, 24.4, 36.7001, 24.4], [50, 51]);
      await tester.pumpWidget(host((c) => live(c, track, plan: climb)));
      expect(find.byKey(const ValueKey('topo-live-milos')), findsOneWidget);
      expect(find.byKey(const ValueKey('gradient-legend')), findsNothing);
    });
  });
}
