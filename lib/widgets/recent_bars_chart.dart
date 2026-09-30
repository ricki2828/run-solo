import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../theme/theme.dart';

/// One attempt on a [RecentBarsChart]: when, the value, and an optional
/// second reading (the heat-adjusted twin) drawn as a tick over the bar.
class BarPoint {
  const BarPoint({required this.date, required this.value, this.twin});
  final DateTime date;
  final double value;
  final double? twin;
}

/// The one chart style for Trends and boards: recent attempts as vertical
/// bars, oldest left, newest right. The best bar is Arc with its label,
/// the rest neutral; a dashed "Best" line, faint grid, horizontal dates
/// and a stated direction ("Faster is taller"), then the values as a list.
///
/// Fewer than two points draws [ChartEmptyState] instead, never a chart.
class RecentBarsChart extends StatelessWidget {
  const RecentBarsChart({
    super.key,
    required this.points,
    required this.lowerIsBetter,
    required this.format,
    required this.direction,
    required this.emptyTitle,
    this.emptyBody,
    this.best,
    this.maxBars = 8,
    this.showValues = true,
  });

  /// Chronological, oldest first.
  final List<BarPoint> points;

  /// Times and paces: true. Distance and scores: false.
  final bool lowerIsBetter;
  final String Function(double) format;

  /// "Faster is taller".
  final String direction;
  final String emptyTitle;
  final String? emptyBody;

  /// The best value across every attempt, older ones included; defaults to
  /// the best shown.
  final double? best;
  final int maxBars;

  /// The readable list under the chart; off where the screen already has one.
  final bool showValues;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return ChartEmptyState(title: emptyTitle, body: emptyBody);
    }
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final shown = points.length > maxBars
        ? points.sublist(points.length - maxBars)
        : points;
    final values = [for (final p in shown) p.value];
    final shownBest = lowerIsBetter
        ? values.reduce(math.min)
        : values.reduce(math.max);
    final bestValue = best ?? shownBest;
    final pb = shown.indexWhere((p) => p.value == bestValue);
    final scale = _BarScale(
      values: [...values, bestValue],
      lowerIsBetter: lowerIsBetter,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${direction.toUpperCase()} · LAST ${shown.length}',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Semantics(
          label:
              '$direction. Best ${format(bestValue)}. '
              '${shown.length} recent attempts listed below.',
          excludeSemantics: true,
          child: SizedBox(
            height: 200,
            width: double.infinity,
            child: CustomPaint(
              painter: _BarsPainter(
                points: shown,
                scale: scale,
                bestValue: bestValue,
                pb: pb,
                format: format,
                bar: t.inkMuted,
                arc: t.accentArc,
                ink: t.inkPrimary,
                label: t.inkSecondary,
                grid: t.lineHair,
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.x8),
        Text(
          'Axis starts at ${format(scale.base)}',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        if (showValues) const SizedBox(height: Space.x16),
        if (showValues)
          for (var i = shown.length - 1; i >= 0; i--)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.x8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      Fmt.dayDate(shown[i].date),
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ),
                  if (i == pb)
                    Padding(
                      padding: const EdgeInsets.only(right: Space.x12),
                      child: Text(
                        'PB',
                        style: RunSoloType.label13.copyWith(color: t.accentArc),
                      ),
                    ),
                  Text(
                    format(shown[i].value),
                    style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Shared by 0 and 1 attempt on every chart: three faint outline bars and
/// a line of plain words. Never a chart with fewer than two points.
class ChartEmptyState extends StatelessWidget {
  const ChartEmptyState({super.key, required this.title, this.body});
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.cardPadding),
      decoration: BoxDecoration(
        color: t.bgRaised,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: t.lineHair),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 48,
            child: CustomPaint(painter: _GhostBarsPainter(t.inkMuted)),
          ),
          const SizedBox(width: Space.x16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                ),
                if (body != null) ...[
                  const SizedBox(height: Space.x4),
                  Text(
                    body!,
                    style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GhostBarsPainter extends CustomPainter {
  _GhostBarsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const heights = [0.4, 0.65, 1.0];
    for (var i = 0; i < 3; i++) {
      final h = size.height * heights[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * 20.0 + 1, size.height - h, 14, h),
          const Radius.circular(3),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_GhostBarsPainter old) => old.color != color;
}

/// Goodness scale: better is up. The baseline sits a quarter of the range
/// past the worst so the worst bar still shows, rounded to a whole unit;
/// the best stops 6% short of the top.
class _BarScale {
  _BarScale({required List<double> values, required this.lowerIsBetter}) {
    final hi = values.reduce(math.max);
    final lo = values.reduce(math.min);
    var span = hi - lo;
    if (span == 0) span = hi.abs() * 0.02;
    if (span == 0) span = 1;
    if (lowerIsBetter) {
      top = lo - span * 0.06;
      base = (hi + span * 0.25).ceilToDouble();
    } else {
      top = hi + span * 0.06;
      base = (lo - span * 0.25).floorToDouble();
    }
  }
  final bool lowerIsBetter;
  late final double top;
  late final double base;

  /// 0 at the baseline, 1 at the top.
  double frac(double v) =>
      ((lowerIsBetter ? base - v : v - base) /
              (lowerIsBetter ? base - top : top - base))
          .clamp(0.0, 1.0);
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.points,
    required this.scale,
    required this.bestValue,
    required this.pb,
    required this.format,
    required this.bar,
    required this.arc,
    required this.ink,
    required this.label,
    required this.grid,
  });
  final List<BarPoint> points;
  final _BarScale scale;
  final double bestValue;
  final int pb;
  final String Function(double) format;
  final Color bar, arc, ink, label, grid;

  static const _gutter = 64.0, _top = 20.0, _bottom = 22.0;

  TextPainter _tp(String s, Color c, {FontWeight w = FontWeight.w500}) =>
      TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: RunSoloType.ui,
            fontSize: 12,
            fontWeight: w,
            color: c,
            fontFeatures: RunSoloType.tabular,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _gutter;
    final bottom = size.height - _bottom;
    final h = bottom - _top;
    double y(double v) => bottom - h * scale.frac(v);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var k = 0; k <= 3; k++) {
      final yy = bottom - h * k / 3;
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), gridPaint);
    }
    final n = points.length;
    final slot = plotW / n;
    final barW = math.min(28.0, slot * 0.6);
    for (var i = 0; i < n; i++) {
      final cx = slot * (i + 0.5);
      final top = y(points[i].value);
      final isPb = i == pb;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - barW / 2, top, cx + barW / 2, bottom),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = isPb ? arc : bar,
      );
      final twin = points[i].twin;
      if (twin != null) {
        final ty = y(twin);
        canvas.drawLine(
          Offset(cx - barW / 2 - 2, ty),
          Offset(cx + barW / 2 + 2, ty),
          Paint()
            ..color = ink
            ..strokeWidth = 2,
        );
      }
      final d = points[i].date;
      final dt = _tp('${d.day}/${d.month}', label);
      dt.paint(canvas, Offset(cx - dt.width / 2, bottom + 5));
      if (isPb) {
        final pl = _tp('PB', arc, w: FontWeight.w700);
        pl.paint(canvas, Offset(cx - pl.width / 2, top - pl.height - 3));
      }
    }
    // Dashed Best line with its label in the right gutter.
    final by = y(bestValue);
    final dash = Paint()
      ..color = label
      ..strokeWidth = 1;
    for (var x = 0.0; x < plotW; x += 8) {
      canvas.drawLine(Offset(x, by), Offset(math.min(x + 4, plotW), by), dash);
    }
    final bl = _tp('Best', label);
    final bv = _tp(format(bestValue), ink, w: FontWeight.w700);
    bl.paint(canvas, Offset(plotW + 8, by - bl.height));
    bv.paint(canvas, Offset(plotW + 8, by));
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.points != points ||
      old.bestValue != bestValue ||
      old.bar != bar ||
      old.arc != arc;
}
