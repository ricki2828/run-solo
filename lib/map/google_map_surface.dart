/// Real `MapSurfaceFactory` over `google_maps_flutter` (plan §18.3,
/// addendum A4): lite-mode bitmap on run detail, interactive full-screen on
/// tap, Night Session style JSON from `assets/maps/night_session.json`
/// passed as `GoogleMap(style:)` (W10: `setMapStyle` is deprecated). Only
/// constructed in `AppServices.production()`; never under `flutter_test`.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;

import '../state/live_route.dart';
import '../theme/theme.dart';
import 'blank_snapshot.dart';
import 'live_google_map.dart';
import 'cached_map_card.dart';
import 'map_surface.dart';
import 'render_queue.dart';
import 'route_builder.dart';
import 'snapshot_cache.dart';

class GoogleMapSurfaceFactory implements MapSurfaceFactory {
  const GoogleMapSurfaceFactory();

  @override
  bool get available => kMapsApiKey.isNotEmpty;

  @override
  Widget build(
    BuildContext context,
    RouteGeometry route, {
    bool interactive = false,
    ValueChanged<int?>? onLapTap,
  }) {
    if (!available || route.isEmpty) return RouteShape(route: route);
    return _GoogleRouteMap(
      route: route,
      interactive: interactive,
      onLapTap: onLapTap,
    );
  }

  @override
  Widget buildLive(
    BuildContext context, {
    required LiveRouteTrack track,
    required Color color,
  }) {
    if (!available) {
      return ListenableBuilder(
        listenable: track,
        builder: (context, _) =>
            RouteShape(route: liveRouteGeometry(track.points)),
      );
    }
    return LiveGoogleMap(track: track, color: color);
  }

  @override
  Future<void> pruneCards(Set<String> liveRunIds) =>
      MapSnapshotCache.shared.pruneOrphans(liveRunIds);

  @override
  Widget buildCard(
    BuildContext context,
    RouteGeometry route, {
    required String runId,
    Color? routeColor,
  }) {
    if (!available || route.isEmpty) {
      return RouteShape(route: route, color: routeColor);
    }
    final hash = routeFingerprint(route);
    return CachedMapCard(
      route: route,
      routeColor: routeColor,
      cacheKey: (size, dpr) => MapSnapshotCache.keyFor(
        runId: runId,
        styleVersion: kMapStyleVersion,
        routeHash: hash,
        width: size.width,
        height: size.height,
        pixelRatio: dpr,
      ),
      cache: MapSnapshotCache.shared,
      queue: RenderQueue.shared,
      // The snapshot is the map only; the route is drawn over it by
      // RouteShape in the run-type colour.
      renderer: (size, onSnapshot, onFailed) => _GoogleRouteMap(
        route: route,
        interactive: false,
        mapOnly: true,
        onSnapshot: onSnapshot,
        onFailed: onFailed,
      ),
    );
  }
}

class _GoogleRouteMap extends StatefulWidget {
  const _GoogleRouteMap({
    required this.route,
    required this.interactive,
    this.onLapTap,
    this.mapOnly = false,
    this.onSnapshot,
    this.onFailed,
  });
  final RouteGeometry route;
  final bool interactive;
  final ValueChanged<int?>? onLapTap;

  /// Card mode: no polyline, no markers, no camera padding offset; the
  /// snapshot is the bare styled map.
  final bool mapOnly;

  /// Card mode: receives the verified (non-blank) snapshot PNG.
  final ValueChanged<Uint8List>? onSnapshot;

  /// Card mode: called instead of showing [MapFailedCard]; the owner keeps
  /// drawing its own fallback. The argument says whether and when to retry.
  final ValueChanged<MapFailure>? onFailed;

  @override
  State<_GoogleRouteMap> createState() => _GoogleRouteMapState();
}

class _GoogleRouteMapState extends State<_GoogleRouteMap> {
  static String? _styleJson;
  static final Map<String, gm.BitmapDescriptor> _icons = {};

  Set<gm.Marker> _markers = const {};
  bool _failed = false;
  bool _prepared = false;
  bool _checked = false;
  gm.GoogleMapController? _controller;
  Timer? _loadWatch;
  Timer? _idleFallback;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme / MediaQuery are read here, never in initState (P2-3).
    if (_prepared) return;
    _prepared = true;
    _prepare();
    // A rejected key or an unregistered signing SHA-1 still creates the map
    // and fires onMapCreated, so that callback proves nothing (W9). The
    // first camera idle triggers a snapshot check; if neither the idle nor
    // the snapshot has settled in 10 s, show the failed state anyway.
    // onCameraIdle may never fire while the platform view is occluded:
    // snapshot anyway after a short delay.
    _idleFallback = Timer(const Duration(seconds: 4), _checkBlank);
    _loadWatch = Timer(const Duration(seconds: 10), () {
      if (mounted && !_checked) _fail();
    });
  }

  void _fail([MapFailure kind = MapFailure.transient]) {
    if (widget.onFailed != null) {
      widget.onFailed!(kind);
    } else {
      setState(() => _failed = true);
    }
  }

  /// After the first idle: a flat single-colour canvas means no tiles were
  /// authorised. Styled tiles plus the Bone polyline are never flat.
  Future<void> _checkBlank() async {
    if (_checked) return;
    final c = _controller;
    if (c == null) return;
    _checked = true;
    _loadWatch?.cancel();
    _idleFallback?.cancel();
    try {
      // Tiles can land a beat after the idle callback.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final png = await c.takeSnapshot().timeout(const Duration(seconds: 8));
      if (png == null) {
        if (mounted) _fail();
        return;
      }
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      final rgba = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final blank =
          rgba == null ||
          isBlankSnapshot(
            rgba.buffer.asUint8List(),
            width: frame.image.width,
            height: frame.image.height,
          );
      if (!mounted) return;
      if (blank) {
        _fail(MapFailure.blank);
      } else {
        widget.onSnapshot?.call(png);
      }
    } catch (e) {
      debugPrint('map: snapshot check failed ($e)');
      if (mounted) _fail();
    }
  }

  @override
  void dispose() {
    _loadWatch?.cancel();
    _idleFallback?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    try {
      _styleJson ??= await rootBundle.loadString(
        'assets/maps/night_session.json',
      );
      final markers = <gm.Marker>{};
      for (final m
          in widget.mapOnly ? const <RouteMarker>[] : widget.route.markers) {
        final icon = await _iconFor(m, t, dpr);
        markers.add(
          gm.Marker(
            markerId: gm.MarkerId(
              '${m.kind.name}-${m.lapIndex ?? m.kind.name}',
            ),
            position: gm.LatLng(m.point.lat, m.point.lon),
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            consumeTapEvents: widget.onLapTap != null,
            onTap: widget.onLapTap == null
                ? null
                : () => widget.onLapTap!(m.lapIndex),
          ),
        );
      }
      if (mounted) setState(() => _markers = markers);
    } catch (e) {
      debugPrint('map: prepare failed ($e)');
      if (mounted) _fail(MapFailure.permanent);
    }
  }

  /// Start = 10 dp Bone dot; finish = black dot, 2 px Bone ring; lap chips =
  /// 22 dp black circles with the number (work Bone, recovery muted).
  Future<gm.BitmapDescriptor> _iconFor(
    RouteMarker m,
    RunSoloTokens t,
    double dpr,
  ) async {
    final key = '${m.kind.name}:${m.label}';
    final cached = _icons[key];
    if (cached != null) return cached;
    final size =
        (m.kind == RouteMarkerKind.start || m.kind == RouteMarkerKind.finish
            ? 12.0
            : 22.0) *
        dpr;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final c = Offset(size / 2, size / 2);
    switch (m.kind) {
      case RouteMarkerKind.start:
        canvas.drawCircle(c, 5 * dpr, Paint()..color = t.inkPrimary);
      case RouteMarkerKind.finish:
        canvas.drawCircle(c, 5 * dpr, Paint()..color = t.bgBase);
        canvas.drawCircle(
          c,
          5 * dpr,
          Paint()
            ..color = t.inkPrimary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * dpr,
        );
      case RouteMarkerKind.work:
      case RouteMarkerKind.recovery:
      case RouteMarkerKind.lap:
        final fill = m.kind == RouteMarkerKind.recovery
            ? t.inkMuted
            : t.inkPrimary;
        canvas.drawCircle(c, 11 * dpr, Paint()..color = t.bgBase);
        canvas.drawCircle(
          c,
          11 * dpr,
          Paint()
            ..color = fill
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * dpr,
        );
        final tp = TextPainter(
          text: TextSpan(
            text: m.label,
            style: RunSoloType.micro11.copyWith(
              color: fill,
              fontSize: 11 * dpr,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
    final image = await recorder.endRecording().toImage(
      size.ceil(),
      size.ceil(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final icon = gm.BytesMapBitmap(
      bytes!.buffer.asUint8List(),
      imagePixelRatio: dpr,
    );
    _icons[key] = icon;
    return icon;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final route = widget.route;
    if (_failed) return MapFailedCard(route: route);
    final b = route.bounds!;
    final bounds = gm.LatLngBounds(
      southwest: gm.LatLng(b.south, b.west),
      northeast: gm.LatLng(b.north, b.east),
    );
    final map = gm.GoogleMap(
      key: ValueKey('gmap-${widget.interactive}'),
      initialCameraPosition: gm.CameraPosition(
        target: gm.LatLng(b.centre.lat, b.centre.lon),
        zoom: 15,
      ),
      style: _styleJson,
      // Not lite mode: lite mode supports only click events, so
      // onCameraIdle (which drives the blank-snapshot check) may never fire.
      // The card is a full map with every gesture off and a tap layer on top.
      liteModeEnabled: false,
      mapToolbarEnabled: false,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      compassEnabled: false,
      zoomControlsEnabled: false,
      buildingsEnabled: false,
      trafficEnabled: false,
      zoomGesturesEnabled: widget.interactive,
      scrollGesturesEnabled: widget.interactive,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
      padding: widget.mapOnly
          ? EdgeInsets.zero
          : const EdgeInsets.only(left: 8, bottom: 8),
      polylines: widget.mapOnly
          ? const {}
          : {
              gm.Polyline(
                polylineId: const gm.PolylineId('route'),
                points: [for (final p in route.points) gm.LatLng(p.lat, p.lon)],
                color: t.inkPrimary,
                width: 4,
                jointType: gm.JointType.round,
                startCap: gm.Cap.roundCap,
                endCap: gm.Cap.roundCap,
              ),
            },
      markers: _markers,
      onMapCreated: (c) {
        _controller = c;
        // Fit with 24 dp padding (A4). Lite mode has no animation.
        unawaited(c.moveCamera(gm.CameraUpdate.newLatLngBounds(bounds, 24)));
      },
      onCameraIdle: _checkBlank,
    );
    // A non-interactive card must not swallow the tap that opens the
    // full-screen map: block the platform view's own touch handling.
    final card = widget.interactive ? map : IgnorePointer(child: map);
    return ClipRRect(
      borderRadius: widget.interactive
          ? BorderRadius.zero
          : BorderRadius.circular(Radii.card),
      child: card,
    );
  }
}
