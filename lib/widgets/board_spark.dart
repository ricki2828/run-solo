import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The boards card spark-bars (LB3c, mockup frame 1): the board's last 8
/// results, one bar each, oldest to newest. The best bar is Arc, the newest
/// is ink, the rest are muted. Height is the result's standing: the best
/// nearly reaches the top, the worst sits on a cropped baseline (10% of the
/// height), so small differences stay visible on a long-running board.
class BoardSpark extends StatelessWidget {
  const BoardSpark({
    super.key,
    required this.values,
    required this.lowerBetter,
    required this.best,
    required this.bestColor,
    required this.newestColor,
    required this.barColor,
    this.height = 40,
  });

  /// Oldest to newest, at most 8 (the board's raw metric per entry).
  final List<double> values;

  /// Time and pace boards: lower is better. VO2 and distance boards: higher.
  final bool lowerBetter;

  /// The board's best metric: that bar takes [bestColor].
  final double best;
  final Color bestColor;
  final Color newestColor;
  final Color barColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: BoardSparkPainter(
          values: values,
          lowerBetter: lowerBetter,
          best: best,
          bestColor: bestColor,
          newestColor: newestColor,
          barColor: barColor,
        ),
      ),
    );
  }
}

class BoardSparkPainter extends CustomPainter {
  BoardSparkPainter({
    required this.values,
    required this.lowerBetter,
    required this.best,
    required this.bestColor,
    required this.newestColor,
    required this.barColor,
  });

  final List<double> values;
  final bool lowerBetter;
  final double best;
  final Color bestColor;
  final Color newestColor;
  final Color barColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;
    final n = values.length;
    final slot = size.width / n;
    final barW = math.min(9.0, slot * 0.6);
    // Goodness: bigger is a better result, so all boards read the same way.
    final good = [for (final v in values) lowerBetter ? -v : v];
    final gBest = good.reduce(math.max);
    final gWorst = good.reduce(math.min);
    final span = gBest - gWorst;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < n; i++) {
      // Cropped baseline: the worst entry keeps 10% of the height, the best
      // stops 6% short of the top. All-equal results sit mid-height.
      final frac = span == 0 ? 0.55 : 0.10 + 0.84 * (good[i] - gWorst) / span;
      final h = math.max(2.0, size.height * frac);
      final x = slot * i + (slot - barW) / 2;
      final rect = Rect.fromLTWH(x, size.height - h, barW, h);
      paint.color = values[i] == best
          ? bestColor
          : i == n - 1
          ? newestColor
          : barColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(BoardSparkPainter old) =>
      old.values != values ||
      old.lowerBetter != lowerBetter ||
      old.best != best ||
      old.bestColor != bestColor ||
      old.newestColor != newestColor ||
      old.barColor != barColor;
}
