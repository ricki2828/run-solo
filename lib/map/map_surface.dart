/// The seam between run detail and `google_maps_flutter` (plan §18.3 W9).
/// `GoogleMap` is a platform view that renders nothing under `flutter_test`,
/// so screens ask a [MapSurfaceFactory] for a widget and tests get the fake.
/// [MapSurfaceFactory.buildLive] is the follow-the-runner map for the record
/// screen's MAP view; the recorder never sees it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/live_route.dart';
import '../theme/theme.dart';
import 'route_builder.dart';

/// Present at build time when the release job injects the Maps key
/// (`--dart-define=RUN_SOLO_MAPS_API_KEY=…`, the same value the manifest
/// placeholder gets). Empty in CI and on dev builds: the route-shape
/// fallback draws instead and nothing can crash.
const String kMapsApiKey = String.fromEnvironment('RUN_SOLO_MAPS_API_KEY');

abstract class MapSurfaceFactory {
  /// Whether a Google map can be shown at all (key present, GMS on device).
  bool get available;

  /// 4:3 lite-mode bitmap with the route, or the interactive full-screen map
  /// when [interactive]. Implementations must never throw: a failed load
  /// renders [MapFailedCard] with the route still drawn on our own canvas.
  Widget build(
    BuildContext context,
    RouteGeometry route, {
    bool interactive = false,
    ValueChanged<int?>? onLapTap,
  });

  /// The record screen's MAP view: the interactive map following the last
  /// point of [track] (north-up, recentring about 8 s after a pan), the
  /// route so far in [color] and a marker at the current position. Never
  /// throws; a failed load draws the route on our own canvas instead.
  Widget buildLive(
    BuildContext context, {
    required LiveRouteTrack track,
    required Color color,
  });

  /// Home's recent-run card background (non-interactive). Shows a cached
  /// snapshot of the map with the route drawn on it, or the [RouteShape]
  /// instantly while that is not available (not yet rendered, no key, no
  /// GMS, offline, blank snapshot). Never throws, never a blank box and
  /// never a failure caption.
  ///
  /// [routeColor] is the run-type colour the route is drawn in over the map.
  Widget buildCard(
    BuildContext context,
    RouteGeometry route, {
    required String runId,
    Color? routeColor,
  });

  /// Drop cached card images of runs that no longer exist. [liveRunIds] is
  /// every run id in History; an empty set deletes nothing.
  Future<void> pruneCards(Set<String> liveRunIds);
}

/// Test / no-GMS stand-in: draws the route shape on a canvas.
class FakeMapSurfaceFactory implements MapSurfaceFactory {
  const FakeMapSurfaceFactory({this.available = false, this.failLoad = false});

  @override
  final bool available;

  /// Simulate "map failed to load" (missing key / SHA mismatch, W9).
  final bool failLoad;

  @override
  Widget build(
    BuildContext context,
    RouteGeometry route, {
    bool interactive = false,
    ValueChanged<int?>? onLapTap,
  }) {
    if (failLoad) return MapFailedCard(route: route);
    return RouteShape(route: route, key: const ValueKey('fake-map'));
  }

  @override
  Widget buildLive(
    BuildContext context, {
    required LiveRouteTrack track,
    required Color color,
  }) => ListenableBuilder(
    listenable: track,
    builder: (context, _) {
      final route = liveRouteGeometry(track.points);
      return failLoad
          ? MapFailedCard(route: route)
          : RouteShape(route: route, key: const ValueKey('fake-live-map'));
    },
  );

  @override
  Widget buildCard(
    BuildContext context,
    RouteGeometry route, {
    required String runId,
    Color? routeColor,
  }) => RouteShape(
    route: route,
    color: routeColor,
    key: const ValueKey('fake-card-map'),
  );

  @override
  Future<void> pruneCards(Set<String> liveRunIds) async {}
}

/// The track as drawable geometry (a start dot, the finish dot is the
/// runner's current position). Empty until two points exist.
RouteGeometry liveRouteGeometry(List<GeoPoint> points) {
  if (points.length < 2) {
    return const RouteGeometry(points: [], markers: [], bounds: null);
  }
  return RouteGeometry(
    points: points,
    markers: [
      RouteMarker(point: points.first, kind: RouteMarkerKind.start),
      RouteMarker(point: points.last, kind: RouteMarkerKind.finish),
    ],
    bounds: RouteBuilder.boundsOf(points),
  );
}

/// The route drawn on our own canvas: fallback for no key / no GMS / load
/// failure, and the whole map surface in tests.
class RouteShape extends StatelessWidget {
  const RouteShape({
    super.key,
    required this.route,
    this.caption,
    this.color,
    this.overlay = false,
  });
  final RouteGeometry route;
  final String? caption;

  /// Route colour; defaults to the primary ink.
  final Color? color;

  /// Drawn over a map image: transparent background and a dark casing under
  /// the route so it stays the brightest thing on the card.
  final bool overlay;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      label: 'Route map, ${route.markers.length} markers',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.card),
        child: ColoredBox(
          color: overlay ? Colors.transparent : t.bgRaised,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _RoutePainter(
                  route: route,
                  ink: color ?? t.inkPrimary,
                  muted: t.inkMuted,
                  ground: t.bgBase,
                  casing: overlay,
                ),
              ),
              if (caption != null)
                Positioned(
                  left: Space.x12,
                  bottom: Space.x8,
                  child: Text(
                    caption!,
                    style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Map failed to load" over the route shape (addendum A4 failed state).
class MapFailedCard extends StatelessWidget {
  const MapFailedCard({super.key, required this.route});
  final RouteGeometry route;

  @override
  Widget build(BuildContext context) =>
      RouteShape(route: route, caption: 'Map failed to load');
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.route,
    required this.ink,
    required this.muted,
    required this.ground,
    this.casing = false,
  });
  final RouteGeometry route;
  final bool casing;
  final Color ink;
  final Color muted;
  final Color ground;

  @override
  void paint(Canvas canvas, Size size) {
    final b = route.bounds;
    if (b == null || route.isEmpty) return;
    const pad = 24.0;
    final w = size.width - 2 * pad;
    final h = size.height - 2 * pad;
    final spanLon = (b.east - b.west);
    final spanLat = (b.north - b.south);
    // Keep aspect: metres per degree differ by cos(lat).
    final cosLat = math.cos(b.centre.lat * math.pi / 180);
    final k = math.min(w / (spanLon * cosLat), h / spanLat);
    Offset map(GeoPoint p) => Offset(
      pad + (p.lon - b.west) * k * cosLat + (w - spanLon * k * cosLat) / 2,
      pad + (b.north - p.lat) * k + (h - spanLat * k) / 2,
    );
    final first = map(route.points.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final p in route.points.skip(1)) {
      final o = map(p);
      path.lineTo(o.dx, o.dy);
    }
    if (casing) {
      canvas.drawPath(
        path,
        Paint()
          ..color = ground.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    for (final m in route.markers) {
      final o = map(m.point);
      switch (m.kind) {
        case RouteMarkerKind.start:
          canvas.drawCircle(o, 5, Paint()..color = ink);
        case RouteMarkerKind.finish:
          canvas.drawCircle(o, 5, Paint()..color = ground);
          canvas.drawCircle(
            o,
            5,
            Paint()
              ..color = ink
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        case RouteMarkerKind.work:
        case RouteMarkerKind.recovery:
        case RouteMarkerKind.lap:
          final fill = m.kind == RouteMarkerKind.recovery ? muted : ink;
          canvas.drawCircle(o, 11, Paint()..color = ground);
          canvas.drawCircle(
            o,
            11,
            Paint()
              ..color = fill
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
          final tp = TextPainter(
            text: TextSpan(
              text: m.label,
              style: RunSoloType.micro11.copyWith(color: fill),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, o - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.route != route || old.ink != ink || old.casing != casing;
}
