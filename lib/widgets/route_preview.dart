import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// A static picture of a saved route for the prep screens (Start, Ready):
/// the line on a flat ground, a filled start dot, a ringed finish dot and a
/// few small arrowheads for the direction. Painter only, no map SDK, so it
/// costs nothing before the GPS is up.
class RoutePreview extends StatelessWidget {
  const RoutePreview({
    super.key,
    required this.route,
    required this.ground,
    required this.line,
    required this.start,
    this.height = 120,
    this.radius = Radii.card,
  });
  final engine.SavedRoute route;

  /// Panel colour behind the line.
  final Color ground;

  /// The route line.
  final Color line;

  /// The start dot.
  final Color start;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Map of ${route.name}',
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: RoutePreviewPainter(
              points: route.points,
              ground: ground,
              line: line,
              start: start,
            ),
          ),
        ),
      ),
    );
  }
}

class RoutePreviewPainter extends CustomPainter {
  RoutePreviewPainter({
    required this.points,
    required this.ground,
    required this.line,
    required this.start,
  });
  final List<engine.RoutePoint> points;
  final Color ground;
  final Color line;
  final Color start;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    if (points.length < 2) return;
    var north = -90.0, south = 90.0, east = -180.0, west = 180.0;
    for (final p in points) {
      north = math.max(north, p.lat);
      south = math.min(south, p.lat);
      east = math.max(east, p.lon);
      west = math.min(west, p.lon);
    }
    const pad = 20.0;
    final w = size.width - 2 * pad;
    final h = size.height - 2 * pad;
    final cosLat = math.cos((north + south) / 2 * math.pi / 180);
    final spanX = math.max((east - west) * cosLat, 1e-9);
    final spanY = math.max(north - south, 1e-9);
    final k = math.min(w / spanX, h / spanY);
    Offset map(engine.RoutePoint p) => Offset(
      pad + (p.lon - west) * cosLat * k + (w - spanX * k) / 2,
      pad + (north - p.lat) * k + (h - spanY * k) / 2,
    );
    final offs = [for (final p in points) map(p)];
    final path = Path()..moveTo(offs.first.dx, offs.first.dy);
    for (final o in offs.skip(1)) {
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = ground.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    // Direction: an arrowhead a quarter, half and three quarters along,
    // cut into the line in the ground colour.
    for (final f in const [0.25, 0.5, 0.75]) {
      final i = ((offs.length - 1) * f).round().clamp(1, offs.length - 1);
      // Look back a few points so a jittery step does not flip the head.
      final back = (i - 4).clamp(0, i - 1);
      final tip = offs[i];
      final d = tip - offs[back];
      if (d.distance < 6) continue;
      final ang = math.atan2(d.dy, d.dx);
      Offset wing(double da) =>
          tip - Offset(math.cos(ang + da), math.sin(ang + da)) * 7;
      final head = Path()
        ..moveTo(wing(0.5).dx, wing(0.5).dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(wing(-0.5).dx, wing(-0.5).dy);
      canvas.drawPath(
        head,
        Paint()
          ..color = ground
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final end = offs.last;
    canvas.drawCircle(end, 6, Paint()..color = line);
    canvas.drawCircle(end, 3, Paint()..color = ground);
    final s = offs.first;
    canvas.drawCircle(s, 8, Paint()..color = ground);
    canvas.drawCircle(s, 6, Paint()..color = start);
  }

  @override
  bool shouldRepaint(RoutePreviewPainter old) =>
      old.points != points ||
      old.ground != ground ||
      old.line != line ||
      old.start != start;
}
