import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../theme/theme.dart';

/// The Home fitness hero (variant A, signed off 27-Sep): the VO2 estimate
/// headline, its delta against six weeks ago, the source line, and the
/// trailing observations as a sparkline. No observation in the window
/// shows the baseline prompt (empty state).
class FitnessHeroBlock extends StatelessWidget {
  const FitnessHeroBlock({super.key, required this.hero});

  final engine.FitnessHero? hero;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final h = hero;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FITNESS · VO2 EST',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        if (h == null) ...[
          Text('NO BASELINE YET', style: text.displayMedium),
          const SizedBox(height: Space.x8),
          Text(
            'Your first session sets it.',
            style: text.bodyLarge?.copyWith(color: t.inkSecondary),
          ),
        ] else ...[
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: h.vo2.toStringAsFixed(1),
                  style: RunSoloType.display64,
                ),
                TextSpan(
                  text: ' ml/kg',
                  style: RunSoloType.title28.copyWith(color: t.inkSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.x8),
          _DeltaLine(hero: h),
          if (h.spark.length > 1) ...[
            const SizedBox(height: Space.x12),
            SizedBox(
              height: 56,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparkPainter(
                  values: h.spark,
                  line: t.inkMuted,
                  best: t.accentArc,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _DeltaLine extends StatelessWidget {
  const _DeltaLine({required this.hero});

  final engine.FitnessHero hero;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final d = hero.deltaVs6wks;
    final String delta;
    final Color deltaColor;
    if (d == null) {
      delta = '';
      deltaColor = t.inkSecondary;
    } else if (d > 0.05) {
      delta = '▲ +${d.toStringAsFixed(1)} vs 6 wks';
      deltaColor = t.accentArc;
    } else if (d < -0.05) {
      delta = '▼ ${d.toStringAsFixed(1)} vs 6 wks';
      deltaColor = t.inkSecondary;
    } else {
      delta = 'Level vs 6 wks';
      deltaColor = t.inkSecondary;
    }
    return Text.rich(
      TextSpan(
        children: [
          if (delta.isNotEmpty)
            TextSpan(
              text: '$delta · ',
              style: text.bodyMedium?.copyWith(color: deltaColor),
            ),
          TextSpan(
            text:
                '${hero.sourceLabel == 'Cooper test' ? '12-minute test' : hero.sourceLabel} · ${Fmt.dayDate(hero.asOf)}',
            style: text.bodyMedium?.copyWith(color: t.inkSecondary),
          ),
        ],
      ),
    );
  }
}

/// Muted polyline over the trailing observations; the best point in Arc
/// (the boards' convention: the best wins the accent).
class _SparkPainter extends CustomPainter {
  const _SparkPainter({
    required this.values,
    required this.line,
    required this.best,
  });

  final List<double> values;
  final Color line;
  final Color best;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = math.max(hi - lo, 1.0);
    Offset pointAt(int i) => Offset(
      size.width * i / (values.length - 1),
      size.height - 4 - (size.height - 8) * (values[i] - lo) / span,
    );
    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(pointAt(i).dx, pointAt(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    var bestI = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] >= values[bestI]) bestI = i;
    }
    canvas.drawCircle(pointAt(bestI), 3.5, Paint()..color = best);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.line != line || old.best != best;
}
