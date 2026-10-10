/// Emulator harness for the Topo map surface (`flutter build apk -t
/// lib/topo_surface_main.dart`), never shipped. Downloads the Milos pack from
/// the live R2 hosting while the emulator still has a network, then walks
/// run detail, the live follow map, a Home card and a no-pack run, and prints
/// `TOPO_SURFACE ...` lines that tools/emulator_topo_surface.sh greps. The
/// script switches the emulator to airplane mode when it sees `pack_installed`,
/// so every map after that proves it needs no network.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'map/map_surface.dart';
import 'map/route_builder.dart';
import 'map/topo_map_surface.dart';
import 'map/topo_maplibre.dart';
import 'state/live_route.dart';
import 'state/settings.dart';
import 'theme/theme.dart';
import 'topo/pack_manager.dart';
import 'topo/topo_files.dart';

const String _r2 = 'https://pub-b1d26357d23144f8a9c96f35588be8fe.r2.dev';

void log(String m) => debugPrint('TOPO_SURFACE $m');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(theme: runSoloTheme(), home: const _Harness()));
}

enum _Stage {
  setup,
  detail,
  live,
  card,
  noPack,
  hill,
  hillLive,
  hillLiveDark,
  gap,
  done,
}

// A wiggle across the Milos box (24.30-24.55 E, 36.64-36.76 N), about 1.5 km.
final List<GeoPoint> _milosRoute = [
  for (var i = 0; i <= 30; i++)
    GeoPoint(
      36.7240 + 0.0045 * (i / 30) + 0.0012 * ((i % 6) / 6),
      24.4430 + 0.0140 * (i / 30),
      // Flat, a steep climb, then the way down: every gradient class shows.
      i < 8 ? 40.0 : (i < 18 ? 40.0 + (i - 8) * 4 : 80.0 - (i - 18) * 3),
    ),
];

// A real climb on Milos: from near Plaka up the east face of Profitis Ilias
// (36.6905N 24.4060E to 36.6815N 24.3730E), elevations from a public DEM.
// Steep terrain with index contours, so the tinted hillshade, the banded
// contours and the gradient colours can be judged on something real.
const List<double> _hillEle = [
  103,
  95,
  116,
  135,
  143,
  166,
  160,
  157,
  184,
  181,
  178,
  188,
  220,
  248,
  258,
  261,
  297,
  283,
  304,
  304,
  299,
  278,
  288,
  309,
  349,
  379,
  390,
  394,
  393,
  390,
  381,
  377,
  425,
  424,
  442,
  466,
  486,
  501,
  512,
  568,
  622,
];

final List<GeoPoint> _hillRoute = [
  for (var i = 0; i < _hillEle.length; i++)
    GeoPoint(
      36.6905 - 0.0090 * (i / 40) + 0.0008 * ((i % 8) / 8),
      24.4060 - 0.0330 * (i / 40),
      _hillEle[i],
    ),
];

RouteGeometry _geometry(List<GeoPoint> pts) => RouteGeometry(
  points: pts,
  markers: [
    RouteMarker(point: pts.first, kind: RouteMarkerKind.start),
    RouteMarker(point: pts.last, kind: RouteMarkerKind.finish),
  ],
  bounds: RouteBuilder.boundsOf(pts),
);

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  _Stage _stage = _Stage.setup;
  TopoMapSurfaceFactory? _factory;
  final LiveRouteTrack _track = LiveRouteTrack();
  Timer? _feed;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _feed?.cancel();
    super.dispose();
  }

  Future<void> _go(_Stage s, int seconds) async {
    if (!mounted) return;
    setState(() => _stage = s);
    log('stage_begin ${s.name}');
    await Future<void>.delayed(Duration(seconds: seconds));
    log('stage_end ${s.name}');
  }

  Future<void> _run() async {
    log(
      'start dpr=${WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio}',
    );
    final support = await getApplicationSupportDirectory();
    final packs = PackManager(
      root: Directory('${support.path}/topo'),
      baseUrl: Uri.parse(_r2),
    );
    await packs.load();
    if (packs.installed.isEmpty) {
      await packs.refreshRegions();
      final ok = await packs.download('milos');
      log('download milos ok=$ok error=${packs.statusOf('milos').error}');
      await packs.load();
    }
    if (packs.installed.isEmpty) {
      log('pack FAILED');
      log('DONE');
      return;
    }
    log('pack_installed ${packs.installed.map((p) => p.id).join(',')}');
    // The script goes offline now.
    await Future<void>.delayed(const Duration(seconds: 8));
    _factory = TopoMapSurfaceFactory(
      packs: packs,
      settings: SettingsController(MemorySettingsStore(const AppSettings())),
      fallback: const FakeMapSurfaceFactory(available: true),
      engine: MapLibreTopoEngine(TopoFiles(packsRoot: packs.root)),
    );
    await _go(_Stage.detail, 14);
    _feed = Timer.periodic(const Duration(seconds: 1), (t) {
      final i = t.tick - 1;
      if (i < _milosRoute.length) {
        final p = _milosRoute[i];
        _track.apply(i, [p.lat, p.lon]);
      }
    });
    await _go(_Stage.live, 16);
    _feed?.cancel();
    await _go(_Stage.card, 16);
    await _go(_Stage.noPack, 6);
    await _go(_Stage.hill, 9);
    await _hillRun(_Stage.hillLive);
    // A beat with no map, so the first live map is disposed before the next.
    await _go(_Stage.gap, 2);
    await _hillRun(_Stage.hillLiveDark);
    await _go(_Stage.done, 1);
    log('DONE');
  }

  /// Up the climb, then back down it: the way back is retraced, and every
  /// point carries its elevation like the recorder's live feed. The old
  /// track ahead is coloured in the direction being run.
  Future<void> _hillRun(_Stage stage) async {
    _feed?.cancel();
    _track.clear();
    _feed = Timer.periodic(const Duration(milliseconds: 200), (t) {
      final i = t.tick - 1;
      final n = _hillRoute.length;
      if (i < n + 38) {
        final p = _hillRoute[i < n ? i : 2 * (n - 1) - i];
        _track.apply(i, [p.lat + 0.0001, p.lon], [p.ele]);
      }
    });
    await _go(stage, 20);
    _feed?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final f = _factory;
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Scaffold(
      body: SafeArea(
        child: switch (_stage) {
          _Stage.setup ||
          _Stage.gap ||
          _Stage.done => Center(child: Text(_stage.name)),
          _Stage.detail => AspectRatio(
            aspectRatio: 4 / 3,
            child: f!.build(
              context,
              _geometry(_milosRoute),
              terrain: true,
              plan: [
                for (final p in _milosRoute)
                  GeoPoint(p.lat + 0.0008, p.lon, p.ele),
              ],
              routeColor: AuroraRunType.free,
            ),
          ),
          _Stage.live => f!.buildLive(
            context,
            track: _track,
            color: AuroraRunType.free,
            plan: [
              for (final p in _milosRoute)
                GeoPoint(p.lat + 0.0008, p.lon, p.ele),
            ],
            terrain: true,
          ),
          _Stage.card => Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 148,
              child: f!.buildCard(
                context,
                _geometry(_milosRoute),
                runId: 'harness-run',
                routeColor: AuroraRunType.free,
                terrain: true,
              ),
            ),
          ),
          _Stage.hill => AspectRatio(
            aspectRatio: 4 / 3,
            child: f!.build(
              context,
              _geometry(_hillRoute),
              terrain: true,
              routeColor: AuroraRunType.free,
            ),
          ),
          _Stage.hillLive || _Stage.hillLiveDark => Theme(
            data: runSoloTheme(
              brightness: _stage == _Stage.hillLiveDark
                  ? Brightness.dark
                  : Brightness.light,
            ),
            child: f!.buildLive(
              context,
              track: _track,
              color: AuroraRunType.free,
              terrain: true,
            ),
          ),
          _Stage.noPack => AspectRatio(
            aspectRatio: 4 / 3,
            child: ColoredBox(
              color: t.bgBase,
              child: f!.build(
                context,
                _geometry([
                  const GeoPoint(1.3090, 103.8140),
                  const GeoPoint(1.3125, 103.8148),
                ]),
                terrain: true,
              ),
            ),
          ),
        },
      ),
    );
  }
}
