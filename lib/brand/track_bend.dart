/// Track Bend painting shared by the intro and the in-app marks: five lanes of
/// a 400 m bend (Z1 outer .. Z5 inner) stroked from the generated centrelines
/// in `track_bend_paths.dart`, and the RUN SUPREME wordmark with its five zone
/// stripes. Flat zone colours, no gradients.
library;

import 'package:flutter/material.dart';

import '../theme/zones.dart';
import 'track_bend_paths.dart';

/// Lane Z1 (index 0) to Z5, zone colours for [brightness].
List<Color> trackBendColors(Brightness brightness) => [
  for (var z = 1; z <= TrackBendGeometry.laneCount; z++)
    HrZones.distribution(z, brightness),
];

final List<Path> _lanes = [
  trackBendLane1(),
  trackBendLane2(),
  trackBendLane3(),
  trackBendLane4(),
  trackBendLane5(),
];

final List<double> _laneLengths = [
  for (final p in _lanes) p.computeMetrics().fold(0.0, (a, m) => a + m.length),
];

final Path _word = trackBendWordmark();

/// Paints the lanes in mark units under [canvas]'s current transform. Lane
/// `i` is drawn up to `progress[i]` (0..1) of its length, from the top
/// straight round the bend; null draws all five whole. Butt caps, so a
/// finished lane ends square on its 400 m stagger mark.
void paintTrackBendLanes(
  Canvas canvas, {
  required List<Color> colors,
  List<double>? progress,
  double opacity = 1,
}) {
  for (var i = 0; i < _lanes.length; i++) {
    final p = (progress?[i] ?? 1).clamp(0.0, 1.0);
    if (p <= 0) continue;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = TrackBendGeometry.laneStroke
      ..strokeCap = StrokeCap.butt
      ..color = colors[i].withValues(alpha: colors[i].a * opacity);
    if (p >= 1) {
      canvas.drawPath(_lanes[i], paint);
    } else {
      final cut = Path();
      var left = _laneLengths[i] * p;
      for (final m in _lanes[i].computeMetrics()) {
        if (left <= 0) break;
        cut.addPath(m.extractPath(0, left.clamp(0, m.length)), Offset.zero);
        left -= m.length;
      }
      canvas.drawPath(cut, paint);
    }
  }
}

/// Paints the wordmark in font units under [canvas]'s current transform.
/// Stripe `i` runs left to right to `stripes[i]` (0..1) of the word's width;
/// null draws all five whole.
void paintTrackBendWordmark(
  Canvas canvas, {
  required Color ink,
  required List<Color> colors,
  List<double>? stripes,
  double opacity = 1,
}) {
  canvas.drawPath(
    _word,
    Paint()..color = ink.withValues(alpha: ink.a * opacity),
  );
  for (var i = 0; i < TrackBendGeometry.laneCount; i++) {
    final p = (stripes?[i] ?? 1).clamp(0.0, 1.0);
    if (p <= 0) continue;
    final top = TrackBendGeometry.stripeTop + i * TrackBendGeometry.stripePitch;
    canvas.drawRect(
      Rect.fromLTWH(
        TrackBendGeometry.wordLeft,
        top,
        (TrackBendGeometry.wordRight - TrackBendGeometry.wordLeft) * p,
        TrackBendGeometry.stripeHeight,
      ),
      Paint()..color = colors[i].withValues(alpha: colors[i].a * opacity),
    );
  }
}
