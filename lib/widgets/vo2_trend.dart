/// Raw VO2 estimates by test (C1 Trend, CO2 result): dots joined by a 1 px
/// line on a padded scale, Bone on a hairline base. The raw estimate only,
/// never the heat twin (plan §3.3). No Arc: a measurement, not a verdict.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class Vo2TrendChart extends StatelessWidget {
  const Vo2TrendChart({
    super.key,
    required this.values,
    this.highlight,
    this.height = 120,
  });

  /// Oldest first.
  final List<double> values;

  /// The test this screen is about: a ring around its dot.
  final int? highlight;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: Vo2Painter(
          values,
          line: t.inkPrimary,
          grid: t.lineHair,
          highlight: highlight,
        ),
      ),
    );
  }
}

class Vo2Painter extends CustomPainter {
  Vo2Painter(
    this.values, {
    required this.line,
    required this.grid,
    this.highlight,
  });
  final List<double> values;
  final Color line;
  final Color grid;
  final int? highlight;

  @override
  void paint(Canvas canvas, Size size) {
    // Room for the ring at the edges (none without one: C1's Trend chart
    // is unchanged).
    final pad = highlight == null ? 0.0 : 10.0;
    final lo = values.reduce(math.min) - 3;
    final hi = values.reduce(math.max) + 3;
    final w = size.width - 2 * pad;
    final h = size.height - 2 * pad;
    Offset at(int i) => Offset(
      pad + (values.length == 1 ? w / 2 : w * i / (values.length - 1)),
      pad + h * (1 - (values[i] - lo) / (hi - lo)),
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()..color = grid,
    );
    final p = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var i = 1; i < values.length; i++) {
      canvas.drawLine(at(i - 1), at(i), p);
    }
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(at(i), 4, Paint()..color = line);
    }
    final hl = highlight;
    if (hl != null && hl >= 0 && hl < values.length) {
      canvas.drawCircle(
        at(hl),
        8,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(Vo2Painter old) =>
      old.values != values || old.highlight != highlight;
}
