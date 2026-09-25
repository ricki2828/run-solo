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

import '../theme/theme.dart';
import 'map_surface.dart';
import 'route_builder.dart';

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
}

class _GoogleRouteMap extends StatefulWidget {
  const _GoogleRouteMap({
    required this.route,
    required this.interactive,
    this.onLapTap,
  });
  final RouteGeometry route;
  final bool interactive;
  final ValueChanged<int?>? onLapTap;

  @override
  State<_GoogleRouteMap> createState() => _GoogleRouteMapState();
}

class _GoogleRouteMapState extends State<_GoogleRouteMap> {
  static String? _styleJson;
  static final Map<String, gm.BitmapDescriptor> _icons = {};

  Set<gm.Marker> _markers = const {};
  bool _failed = false;
  bool _ready = false;
  Timer? _loadWatch;

  @override
  void initState() {
    super.initState();
    _prepare();
    // A blank canvas (missing key, SHA mismatch) never reports an error; if
    // the map has not called back within 8 s we show the failed state (W9).
    _loadWatch = Timer(const Duration(seconds: 8), () {
      if (mounted && !_ready) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _loadWatch?.cancel();
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
      for (final m in widget.route.markers) {
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
      if (mounted) setState(() => _failed = true);
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
      liteModeEnabled: !widget.interactive,
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
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      polylines: {
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
        _ready = true;
        _loadWatch?.cancel();
        // Fit with 24 dp padding (A4). Lite mode has no animation.
        unawaited(c.moveCamera(gm.CameraUpdate.newLatLngBounds(bounds, 24)));
      },
    );
    return ClipRRect(
      borderRadius: widget.interactive
          ? BorderRadius.zero
          : BorderRadius.circular(Radii.card),
      child: map,
    );
  }
}
