/// The MapLibre side of Topo: run detail, the live follow map and the Home
/// card's one-shot snapshot, all over an installed pack's style file.
///
/// Rules carried over from the T0 spike (~/ai/state/run-supreme-topo-t0.md):
/// the style is handed over by file path, the route is a GeoJSON source and
/// line layers inside the style (an annotation line does not show in a
/// snapshot), and a snapshot needs a few seconds after the style loads.
/// Not covered by flutter_test (a platform view draws nothing there); the
/// choice logic around it is, through [TopoEngine].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../state/live_route.dart';
import '../theme/theme.dart';
import '../topo/pack_models.dart';
import '../topo/topo_files.dart';
import '../topo/topo_style.dart';
import 'blank_snapshot.dart';
import 'map_surface.dart';
import 'route_builder.dart';
import 'snapshot_cache.dart';
import 'topo_map_surface.dart';

/// How long after the last pan the live camera goes back to the runner.
const Duration kTopoRecentre = Duration(seconds: 8);

/// Nothing settles under this: show the route on our own canvas instead.
const Duration _loadTimeout = Duration(seconds: 10);

/// A snapshot taken sooner than this after the style loads is mostly empty
/// (T0: about 3-4 s on the emulator).
const Duration _snapshotSettle = Duration(seconds: 4);

class MapLibreTopoEngine implements TopoEngine {
  const MapLibreTopoEngine(this.files);
  final TopoFiles files;

  @override
  Widget detail(
    InstalledPack pack, {
    required RouteGeometry route,
    List<GeoPoint>? plan,
    Color? routeColor,
    bool interactive = false,
  }) => _TopoStaticMap(
    key: ValueKey('topo-detail-${pack.id}-$interactive'),
    pack: pack,
    files: files,
    route: route,
    plan: plan,
    routeColor: routeColor,
    interactive: interactive,
  );

  @override
  Widget live(
    InstalledPack pack, {
    required LiveRouteTrack track,
    required Color color,
    List<GeoPoint>? plan,
  }) => _TopoLiveMap(
    key: ValueKey('topo-live-${pack.id}'),
    pack: pack,
    files: files,
    track: track,
    color: color,
    plan: plan,
  );

  @override
  Widget card(
    InstalledPack pack,
    RouteGeometry route, {
    required ValueChanged<Uint8List> onSnapshot,
    required ValueChanged<MapFailure> onFailed,
  }) => _TopoStaticMap(
    pack: pack,
    files: files,
    route: route,
    mapOnly: true,
    onSnapshot: onSnapshot,
    onFailed: onFailed,
  );
}

ml.LatLng _ll(GeoPoint p) => ml.LatLng(p.lat, p.lon);

Iterable<(double, double)> _pairs(Iterable<GeoPoint> pts) sync* {
  for (final p in pts) {
    yield (p.lat, p.lon);
  }
}

/// Fills the route sources, tolerating a map that went away mid-call.
Future<void> _setSource(
  ml.MapLibreMapController c,
  String id,
  Map<String, Object?> data,
) async {
  try {
    await c.setGeoJsonSource(id, data.cast<String, dynamic>());
  } on Object catch (e) {
    debugPrint('topo map: set $id failed ($e)');
  }
}

/// A MapLibre view of [style] with the shared knobs. [onStyle] fires once the
/// style (tiles, glyphs, route layers) is in.
Widget _mapView({
  required String style,
  required ml.CameraPosition camera,
  required ml.MapCreatedCallback onCreated,
  required VoidCallback onStyle,
  bool gestures = false,
  bool trackCamera = false,
  ValueChanged<ml.CameraPosition>? onCameraMove,
  ml.LatLngBounds? limit,
}) => ml.MapLibreMap(
  styleString: style,
  initialCameraPosition: camera,
  onMapCreated: onCreated,
  onStyleLoadedCallback: onStyle,
  onCameraMove: onCameraMove,
  trackCameraPosition: trackCamera,
  scrollGesturesEnabled: gestures,
  zoomGesturesEnabled: gestures,
  doubleClickZoomEnabled: gestures,
  rotateGesturesEnabled: false,
  tiltGesturesEnabled: false,
  compassEnabled: false,
  logoEnabled: false,
  myLocationEnabled: false,
  minMaxZoomPreference: const ml.MinMaxZoomPreference(3, 17.5),
  cameraTargetBounds: limit == null
      ? ml.CameraTargetBounds.unbounded
      : ml.CameraTargetBounds(limit),
);

/// Run detail (card or full screen) and the Home card's snapshot source.
class _TopoStaticMap extends StatefulWidget {
  const _TopoStaticMap({
    super.key,
    required this.pack,
    required this.files,
    required this.route,
    this.plan,
    this.routeColor,
    this.interactive = false,
    this.mapOnly = false,
    this.onSnapshot,
    this.onFailed,
  });
  final InstalledPack pack;
  final TopoFiles files;
  final RouteGeometry route;
  final List<GeoPoint>? plan;
  final Color? routeColor;
  final bool interactive;

  /// Card mode: no route layers, take a snapshot and report it.
  final bool mapOnly;
  final ValueChanged<Uint8List>? onSnapshot;
  final ValueChanged<MapFailure>? onFailed;

  @override
  State<_TopoStaticMap> createState() => _TopoStaticMapState();
}

class _TopoStaticMapState extends State<_TopoStaticMap> {
  late final Future<String> _style = widget.files.styleFor(widget.pack);
  ml.MapLibreMapController? _ctl;
  bool _failed = false;
  bool _done = false;
  Timer? _watch;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _watch = Timer(
      _loadTimeout,
      () => _fail(MapFailure.transient, 'no style in 10 s'),
    );
  }

  @override
  void dispose() {
    _watch?.cancel();
    _settle?.cancel();
    super.dispose();
  }

  String get _surface => widget.mapOnly ? 'card' : 'run map';

  void _fail(MapFailure kind, String reason) {
    if (_done || !mounted) return;
    _done = true;
    _watch?.cancel();
    recordMapVerdict(
      _surface,
      SnapshotVerdict(blank: true, reason: reason),
      mapType: 'topo',
    );
    if (widget.onFailed != null) {
      widget.onFailed!(kind);
    } else {
      setState(() => _failed = true);
    }
  }

  GeoBounds get _bounds {
    final plan = widget.plan;
    final hasPlan = plan != null && plan.length > 1;
    return hasPlan
        ? RouteBuilder.boundsOf([...widget.route.points, ...plan])
        : widget.route.bounds!;
  }

  Future<void> _onStyle() async {
    final c = _ctl;
    if (c == null || _done || !mounted) return;
    _watch?.cancel();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final b = _bounds;
    try {
      if (!widget.mapOnly) {
        final colour = widget.routeColor ?? t.inkPrimary;
        final plan = widget.plan;
        if (plan != null && plan.length > 1) {
          await _setSource(
            c,
            TopoStyle.planSource,
            TopoStyle.line(
              _pairs(plan),
              colour: t.inkSecondary,
              casing: t.bgBase,
            ),
          );
        }
        await _setSource(
          c,
          TopoStyle.trackSource,
          TopoStyle.line(
            _pairs(widget.route.points),
            colour: colour,
            casing: t.bgBase,
          ),
        );
        await _setSource(
          c,
          TopoStyle.marksSource,
          TopoStyle.dots([
            for (final m in widget.route.markers)
              if (m.kind == RouteMarkerKind.start)
                (m.point.lat, m.point.lon, t.inkPrimary, t.inkPrimary)
              else if (m.kind == RouteMarkerKind.finish)
                (m.point.lat, m.point.lon, t.bgBase, t.inkPrimary),
          ]),
        );
      }
      await c.moveCamera(
        ml.CameraUpdate.newLatLngBounds(
          ml.LatLngBounds(
            southwest: ml.LatLng(b.south, b.west),
            northeast: ml.LatLng(b.north, b.east),
          ),
          left: 24,
          top: 24,
          right: 24,
          bottom: 24,
        ),
      );
    } on Object catch (e) {
      debugPrint('topo map: style setup failed ($e)');
    }
    if (widget.mapOnly) {
      _settle = Timer(_snapshotSettle, _snapshot);
    } else {
      _done = true;
    }
  }

  Future<void> _snapshot() async {
    final c = _ctl;
    if (c == null || _done || !mounted) return;
    try {
      final png = await c.takeSnapshot().timeout(const Duration(seconds: 8));
      final verdict = await judgeSnapshotPng(png);
      recordMapVerdict(_surface, verdict, mapType: 'topo');
      if (!mounted || _done) return;
      _done = true;
      if (verdict.blank) {
        widget.onFailed?.call(MapFailure.blank);
      } else {
        widget.onSnapshot?.call(png);
      }
    } on Object catch (e) {
      _fail(MapFailure.transient, 'snapshot error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    if (_failed) return MapFailedCard(route: widget.route);
    return FutureBuilder<String>(
      future: _style,
      builder: (context, snap) {
        if (snap.hasError) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _fail(MapFailure.permanent, 'style files: ${snap.error}'),
          );
        }
        final style = snap.data;
        if (style == null) return ColoredBox(color: t.bgBase);
        final b = _bounds;
        final limit = _packLimit(widget.pack);
        final map = _mapView(
          style: style,
          camera: ml.CameraPosition(
            target: ml.LatLng(b.centre.lat, b.centre.lon),
            zoom: 13,
          ),
          onCreated: (c) => _ctl = c,
          onStyle: _onStyle,
          gestures: widget.interactive,
          limit: widget.interactive ? limit : null,
        );
        // A non-interactive card must not swallow the tap that opens the
        // full-screen map.
        return ClipRRect(
          borderRadius: widget.interactive
              ? BorderRadius.zero
              : BorderRadius.circular(Radii.card),
          child: widget.interactive ? map : IgnorePointer(child: map),
        );
      },
    );
  }
}

/// The pack's box as map bounds: panning stops where the tiles stop.
ml.LatLngBounds _packLimit(InstalledPack pack) {
  final b = pack.region.bbox;
  return ml.LatLngBounds(
    southwest: ml.LatLng(b[1], b[0]),
    northeast: ml.LatLng(b[3], b[2]),
  );
}

/// The record screen's MAP view: north-up, follows the last point, goes back
/// to the runner about 8 s after the user stops panning.
class _TopoLiveMap extends StatefulWidget {
  const _TopoLiveMap({
    super.key,
    required this.pack,
    required this.files,
    required this.track,
    required this.color,
    this.plan,
  });
  final InstalledPack pack;
  final TopoFiles files;
  final LiveRouteTrack track;
  final Color color;
  final List<GeoPoint>? plan;

  @override
  State<_TopoLiveMap> createState() => _TopoLiveMapState();
}

class _TopoLiveMapState extends State<_TopoLiveMap> {
  static const double _followZoom = 16;
  static const int _maxDisplayPoints = 2000;

  late final Future<String> _style = widget.files.styleFor(widget.pack);
  ml.MapLibreMapController? _ctl;
  bool _loaded = false;
  bool _failed = false;
  int _prog = 0;
  bool _programmatic = false;
  Timer? _watch;
  Timer? _recentre;

  /// The drawn track, thinned past [_maxDisplayPoints]; the recorder keeps
  /// the full route. [_epoch] restarts it when the route is cleared.
  final List<GeoPoint> _line = [];
  int _fed = 0;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    widget.track.addListener(_onTrack);
    _watch = Timer(_loadTimeout, () {
      if (!mounted || _loaded) return;
      recordMapVerdict(
        'live map',
        const SnapshotVerdict(blank: true, reason: 'no style in 10 s'),
        mapType: 'topo',
      );
      setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    widget.track.removeListener(_onTrack);
    _watch?.cancel();
    _recentre?.cancel();
    super.dispose();
  }

  void _syncLine() {
    final track = widget.track;
    if (track.epoch != _epoch || track.count < _fed) {
      _epoch = track.epoch;
      _line.clear();
      _fed = 0;
    }
    _line.addAll(track.since(_fed));
    _fed = track.count;
    if (_line.length > _maxDisplayPoints) {
      final thin = simplifyForDisplay(List.of(_line), _maxDisplayPoints ~/ 2);
      _line
        ..clear()
        ..addAll(thin);
    }
  }

  void _onTrack() {
    if (!mounted) return;
    _syncLine();
    if (!_loaded) return;
    unawaited(_paint());
    if (_recentre == null || !_recentre!.isActive) unawaited(_follow());
  }

  Future<void> _paint() async {
    final c = _ctl;
    if (c == null || !mounted) return;
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    await _setSource(
      c,
      TopoStyle.trackSource,
      TopoStyle.line(_pairs(_line), colour: widget.color, casing: t.bgBase),
    );
    final last = widget.track.last;
    await _setSource(
      c,
      TopoStyle.meSource,
      last == null
          ? TopoStyle.emptyCollection
          : TopoStyle.dots([(last.lat, last.lon, widget.color, t.inkPrimary)]),
    );
  }

  Future<void> _onStyle() async {
    final c = _ctl;
    if (c == null || !mounted) return;
    _loaded = true;
    _watch?.cancel();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final plan = widget.plan;
    if (plan != null && plan.length > 1) {
      await _setSource(
        c,
        TopoStyle.planSource,
        TopoStyle.line(_pairs(plan), colour: t.inkSecondary, casing: t.bgBase),
      );
    }
    _syncLine();
    await _paint();
    await _follow();
  }

  Future<void> _follow() async {
    final c = _ctl;
    final p = widget.track.last;
    if (c == null || p == null || !_loaded) return;
    final token = ++_prog;
    _programmatic = true;
    try {
      await c.animateCamera(
        ml.CameraUpdate.newLatLng(_ll(p)),
        duration: const Duration(milliseconds: 800),
      );
    } on Object {
      // The map is optional; the run goes on.
    }
    // The move events of our own move land before this.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (_prog == token) _programmatic = false;
    });
  }

  /// Any camera move we did not start is the user panning or zooming: hold
  /// still, then come back to the runner.
  void _onCameraMove(ml.CameraPosition _) {
    if (_programmatic || !_loaded) return;
    _recentre?.cancel();
    _recentre = Timer(kTopoRecentre, () {
      _recentre = null;
      if (mounted) unawaited(_follow());
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    if (_failed) {
      return RouteShape(
        route: liveRouteGeometry(widget.track.points, plan: widget.plan),
        color: widget.plan == null ? null : widget.color,
        plan: widget.plan,
        caption: 'Map failed to load',
      );
    }
    final at = widget.track.last ?? widget.plan?.firstOrNull;
    return FutureBuilder<String>(
      future: _style,
      builder: (context, snap) {
        final style = snap.data;
        // Before the first fix there is nowhere to look yet.
        if (style == null || at == null) return ColoredBox(color: t.bgBase);
        return ClipRRect(
          borderRadius: BorderRadius.circular(Radii.card),
          child: _mapView(
            style: style,
            camera: ml.CameraPosition(target: _ll(at), zoom: _followZoom),
            onCreated: (c) => _ctl = c,
            onStyle: _onStyle,
            gestures: true,
            trackCamera: true,
            onCameraMove: _onCameraMove,
          ),
        );
      },
    );
  }
}
