/// The seam between run detail and `google_maps_flutter` (plan §18.3 W9).
/// `GoogleMap` is a platform view that renders nothing under `flutter_test`,
/// so screens ask a [MapSurfaceFactory] for a widget and tests get the fake.
/// The same seam is where a follow-the-runner strip would plug in if the
/// live map ever returns (post-launch backlog); the recorder never sees it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

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
}

/// The route drawn on our own canvas: fallback for no key / no GMS / load
/// failure, and the whole map surface in tests.
class RouteShape extends StatelessWidget {
  const RouteShape({super.key, required this.route, this.caption});
  final RouteGeometry route;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      label: 'Route map, ${route.markers.length} markers',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.card),
        child: ColoredBox(
          color: t.bgRaised,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _RoutePainter(
                  route: route,
                  ink: t.inkPrimary,
                  muted: t.inkMuted,
                  ground: t.bgBase,
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
  });
  final RouteGeometry route;
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
  bool shouldRepaint(_RoutePainter old) => old.route != route;
}
