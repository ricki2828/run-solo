import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../theme/theme.dart';

/// One attempt on a [RecentBarsChart]: when, the value, and an optional
/// second reading (the heat-adjusted twin) drawn as a tick over the bar.
/// [noWeather] rings the bar instead when the twin does not exist.
class BarPoint {
  const BarPoint({
    required this.date,
    required this.value,
    this.twin,
    this.noWeather = false,
  });
  final DateTime date;
  final double value;
  final double? twin;
  final bool noWeather;
}

/// The GPS noise band drawn faintly across the bars: [center] +/- [half]
/// in the chart's own units. Bars inside it are level with the centre.
class NoiseBand {
  const NoiseBand({
    required this.center,
    required this.half,
    required this.label,
    required this.detail,
    required this.caption,
  });
  final double center;
  final double half;

  /// Gutter label ("Noise") and its second line ("+/- 8 s").
  final String label;
  final String detail;

  /// One plain sentence under the chart explaining the band.
  final String caption;
}

/// The one chart style for Trends and boards: recent attempts as vertical
/// bars, oldest left, newest right, starting at the left edge. The best bar
/// is Arc with its label, the rest neutral; a dashed "Best" line, faint
/// grid, single-line dates (thinned so they never overlap) and a stated
/// direction ("Faster is taller"), then the values as a list.
///
/// Fewer than two points draws [ChartEmptyState] instead, never a chart.
/// Boards add the heat twin ticks, tap-to-select callout and the PB-moment
/// animation through the optional parameters.
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
    this.bestIndex,
    this.maxBars = 8,
    this.showValues = true,
    this.tick,
    this.axisSuffix = '',
    this.roundTo = 1,
    this.steps,
    this.showTwins = false,
    this.selected,
    this.onSelect,
    this.selectedLabel,
    this.moment,
    this.previousBest,
    this.noise,
    this.chartKey,
  });

  /// Chronological, oldest first; at most [maxBars] are drawn (the newest).
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

  /// Index (into the drawn bars) of the PB bar; -1 when the PB is older
  /// than the shown attempts. Defaults to the bar equal to the best.
  final int? bestIndex;
  final int maxBars;

  /// The readable list under the chart; off where the screen already has one.
  final bool showValues;

  /// Short axis text ("24:30"); defaults to [format].
  final String Function(double)? tick;

  /// Appended to the axis-start note ("/km").
  final String axisSuffix;

  /// The axis baseline rounds outward to a multiple of this.
  final double roundTo;

  /// Round grid steps (largest last). Given: labelled gridlines in the
  /// right gutter; null: three plain lines.
  final List<double>? steps;
  final bool showTwins;
  final int? selected;
  final ValueChanged<int?>? onSelect;
  final String Function(int)? selectedLabel;

  /// The PB moment (A11.4): the new bar grows, then the Best line moves
  /// from [previousBest]. Null outside the moment.
  final Animation<double>? moment;
  final double? previousBest;
  final NoiseBand? noise;

  /// Key of the chart's tap area.
  final Key? chartKey;

  static const double kHeight = 224;
  static const double _gutter = 56;

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
    final pb = bestIndex ?? shown.indexWhere((p) => p.value == bestValue);
    final scale = _BarScale(
      values: [
        ...values,
        bestValue,
        ?previousBest,
        if (showTwins)
          for (final p in shown) ?p.twin,
      ],
      lowerIsBetter: lowerIsBetter,
      roundTo: roundTo,
    );
    final tickFmt = tick ?? format;
    Widget painter(double growT, double moveT) => CustomPaint(
      painter: _BarsPainter(
        points: shown,
        scale: scale,
        bestValue: bestValue,
        pb: pb,
        format: format,
        tick: tickFmt,
        steps: steps,
        lowerIsBetter: lowerIsBetter,
        maxBars: maxBars,
        showTwins: showTwins,
        selected: selected,
        selectedLabel: selectedLabel,
        growT: growT,
        moveT: moveT,
        previousBest: previousBest,
        noise: noise,
        tokens: t,
      ),
    );
    final m = moment;
    final chart = m == null
        ? painter(1, 1)
        : AnimatedBuilder(
            animation: m,
            builder: (context, _) => painter(
              const Interval(
                0,
                0.625,
                curve: MotionCurves.emphasized,
              ).transform(m.value),
              const Interval(
                0.625,
                1,
                curve: MotionCurves.standard,
              ).transform(m.value),
            ),
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
              '${shown.length} recent attempts.',
          child: LayoutBuilder(
            builder: (context, box) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: onSelect == null
                  ? null
                  : (d) {
                      final slot = (box.maxWidth - _gutter) / maxBars;
                      final dx = d.localPosition.dx;
                      final i = dx < 0 || dx >= slot * shown.length
                          ? null
                          : (dx / slot).floor();
                      onSelect!(i == selected ? null : i);
                    },
              child: SizedBox(
                key: chartKey,
                height: kHeight,
                width: double.infinity,
                child: chart,
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.x8),
        Text(
          'Axis starts at ${tickFmt(scale.base)}$axisSuffix',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        if (noise != null) ...[
          const SizedBox(height: Space.x4),
          Text(
            noise!.caption,
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ],
        if (showValues) ...[
          const SizedBox(height: Space.x16),
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

/// Goodness scale: better is up. The baseline sits 15% of the range past
/// the worst so the worst bar still shows, rounded outward to [roundTo];
/// the best stops 6% short of the top.
class _BarScale {
  _BarScale({
    required List<double> values,
    required this.lowerIsBetter,
    required double roundTo,
  }) {
    final hi = values.reduce(math.max);
    final lo = values.reduce(math.min);
    var span = hi - lo;
    if (span == 0) span = hi.abs() * 0.02;
    if (span == 0) span = 1;
    if (lowerIsBetter) {
      top = lo - span * 0.06;
      base = ((hi + span * 0.15) / roundTo).ceil() * roundTo;
    } else {
      top = hi + span * 0.06;
      base = ((lo - span * 0.15) / roundTo).floor() * roundTo;
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
    required this.tick,
    required this.steps,
    required this.lowerIsBetter,
    required this.maxBars,
    required this.showTwins,
    required this.selected,
    required this.selectedLabel,
    required this.growT,
    required this.moveT,
    required this.previousBest,
    required this.noise,
    required this.tokens,
  });
  final List<BarPoint> points;
  final _BarScale scale;
  final double bestValue;
  final int pb;
  final String Function(double) format;
  final String Function(double) tick;
  final List<double>? steps;
  final bool lowerIsBetter;
  final int maxBars;
  final bool showTwins;
  final int? selected;
  final String Function(int)? selectedLabel;
  final double growT;
  final double moveT;
  final double? previousBest;
  final NoiseBand? noise;
  final RunSoloTokens tokens;

  static const _gutter = RecentBarsChart._gutter;
  static const _top = 32.0, _bottom = 24.0;

  TextPainter _tp(
    String s,
    Color c, {
    FontWeight w = FontWeight.w500,
    double size = 11,
  }) => TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: RunSoloType.ui,
        fontSize: size,
        fontWeight: w,
        color: c,
        fontFeatures: RunSoloType.tabular,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  void _dashed(Canvas canvas, double y, double x1, Paint paint) {
    for (var x = 0.0; x < x1; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 3, x1), y), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _gutter;
    final bottom = size.height - _bottom;
    double y(double v) => bottom - (bottom - _top) * scale.frac(v);
    final n = points.length;
    final slot = plotW / maxBars;
    final barW = math.min(24.0, slot * 0.6);
    final by = y(bestValue);

    // Faint grid: round-step lines with gutter labels, or three plain ones.
    final gridPaint = Paint()
      ..color = tokens.lineHair
      ..strokeWidth = 1;
    final st = steps;
    if (st == null) {
      for (var k = 1; k <= 3; k++) {
        final yy = bottom - (bottom - _top) * k / 3;
        canvas.drawLine(Offset(0, yy), Offset(plotW, yy), gridPaint);
      }
    } else {
      final lo = math.min(scale.base, scale.top);
      final hi = math.max(scale.base, scale.top);
      final step = st.firstWhere(
        (s) => (hi - lo) / s <= 3.2,
        orElse: () => st.last,
      );
      for (var v = (lo / step).ceil() * step; v <= hi; v += step) {
        final yy = y(v);
        if ((yy - by).abs() < 12 || yy > bottom - 4) continue;
        canvas.drawLine(Offset(0, yy), Offset(plotW, yy), gridPaint);
        final tp = _tp(tick(v), tokens.inkMuted);
        tp.paint(canvas, Offset(plotW + 6, yy - tp.height / 2));
      }
    }
    canvas.drawLine(
      Offset(0, bottom),
      Offset(plotW, bottom),
      Paint()
        ..color = tokens.inkMuted
        ..strokeWidth = 1,
    );

    // Bars.
    for (var i = 0; i < n; i++) {
      final x = i * slot + (slot - barW) / 2;
      final vy = y(points[i].value);
      final isPb = i == pb;
      final top = isPb ? bottom - (bottom - vy) * growT : vy;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x, top, x + barW, bottom),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = isPb ? tokens.accentArc : tokens.inkMuted,
      );
      if (showTwins) {
        final twin = points[i].twin;
        if (twin != null) {
          canvas.drawLine(
            Offset(x - 3, y(twin)),
            Offset(x + barW + 3, y(twin)),
            Paint()
              ..color = tokens.inkSecondary
              ..strokeWidth = 2,
          );
        } else if (points[i].noWeather) {
          canvas.drawCircle(
            Offset(x + barW / 2, vy - 9),
            2.5,
            Paint()
              ..color = tokens.inkMuted
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
        }
      }
      if (selected == i) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(x - 2, vy - 2, x + barW + 2, bottom),
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
          ),
          Paint()
            ..color = tokens.inkPrimary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (isPb && growT >= 1) {
        final pl = _tp('PB', tokens.accentArc, w: FontWeight.w700);
        pl.paint(
          canvas,
          Offset(x + barW / 2 - pl.width / 2, vy - pl.height - 3),
        );
      }
    }

    // The noise band, faint, across the bars, labelled in the gutter.
    final nb = noise;
    if (nb != null) {
      final y0 = y(nb.center - nb.half), y1 = y(nb.center + nb.half);
      canvas.drawRect(
        Rect.fromLTRB(0, math.min(y0, y1), plotW, math.max(y0, y1)),
        Paint()..color = tokens.inkPrimary.withValues(alpha: 0.12),
      );
      var ly = (y0 + y1) / 2;
      if ((ly - by).abs() < 30) ly = by + 30;
      final l1 = _tp(nb.label, tokens.inkSecondary);
      final l2 = _tp(nb.detail, tokens.inkSecondary);
      l1.paint(canvas, Offset(plotW + 6, ly - l1.height));
      l2.paint(canvas, Offset(plotW + 6, ly));
    }

    // Single-line dates, thinned so none overlap: PB, newest and oldest
    // first, then the rest left to right.
    final order = <int>[
      if (pb >= 0 && pb < n) pb,
      if (n - 1 != pb) n - 1,
      if (0 != pb && 0 != n - 1) 0,
      for (var i = 1; i < n - 1; i++)
        if (i != pb) i,
    ];
    final taken = <Rect>[];
    for (final i in order) {
      final d = points[i].date;
      final tp = _tp('${d.day}/${d.month}', tokens.inkSecondary);
      final cx = i * slot + slot / 2;
      final r = Rect.fromLTWH(
        cx - tp.width / 2,
        bottom + 6,
        tp.width,
        tp.height,
      );
      if (r.left < 0 || taken.any((o) => o.inflate(3).overlaps(r))) continue;
      taken.add(r);
      tp.paint(canvas, r.topLeft);
    }

    // The Best line; in the PB moment it moves up from the old best,
    // which stays behind as a ghost ("was 51:10").
    var lineY = by;
    final prev = previousBest;
    if (prev != null) {
      final oldY = y(prev);
      lineY = oldY + (by - oldY) * moveT;
      if (moveT < 1) {
        _dashed(
          canvas,
          oldY,
          plotW,
          Paint()
            ..color = tokens.inkMuted.withValues(alpha: 0.45)
            ..strokeWidth = 1,
        );
        final tp = _tp('was ${tick(prev)}', tokens.inkMuted);
        tp.paint(canvas, Offset(plotW + 6, oldY - tp.height / 2));
      }
    }
    _dashed(
      canvas,
      lineY,
      plotW,
      Paint()
        ..color = tokens.inkSecondary
        ..strokeWidth = 1,
    );
    final bl = _tp('Best', tokens.inkPrimary);
    final bv = _tp(tick(bestValue), tokens.inkSecondary);
    bl.paint(canvas, Offset(plotW + 6, lineY - bl.height));
    bv.paint(canvas, Offset(plotW + 6, lineY + 1));

    // The tap callout: "Sat 20 Sep · 24:05 · 17 s off your best".
    final sel = selected;
    if (sel != null && sel < n && selectedLabel != null) {
      final tp = _tp(selectedLabel!(sel), tokens.inkPrimary, size: 12);
      final w = math.min(size.width, tp.width + 24);
      final cx = sel * slot + slot / 2;
      final bx = (cx - w / 2).clamp(0.0, size.width - w);
      final box = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, 0, w, 24),
        const Radius.circular(8),
      );
      canvas.drawRRect(box, Paint()..color = tokens.bgRaised);
      canvas.drawRRect(
        box,
        Paint()
          ..color = tokens.lineHair
          ..style = PaintingStyle.stroke,
      );
      tp.paint(canvas, Offset(bx + (w - tp.width) / 2, 12 - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.points != points ||
      old.bestValue != bestValue ||
      old.growT != growT ||
      old.moveT != moveT ||
      old.selected != selected ||
      old.noise != noise ||
      old.tokens != tokens;
}
