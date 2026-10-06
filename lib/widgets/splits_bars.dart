import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// One bar on [SplitsBars]: the label under it and its pace (s/km). A null
/// pace (a lap with no distance) leaves the slot empty. [readout] is the line
/// shown above the chart while the bar is selected ("km 3 · 6:00/km ·
/// +21 m"); [semantics] is what a screen reader says for it.
@immutable
class SplitBar {
  const SplitBar({
    required this.label,
    required this.paceSecPerKm,
    this.readout,
    this.semantics,
  });
  final String label;
  final double? paceSecPerKm;
  final String? readout;
  final String? semantics;
}

/// Run detail's splits chart, in the leaderboard bar style
/// (`RecentBarsChart`): one vertical bar per km, mile or lap, taller =
/// faster, the fastest in Arc, the rest Bone. Every bar carries its pace
/// above it (every second bar once they get too tight for it). Tap or drag
/// across the bars to pick one: it is outlined and its readout shows above
/// the chart. The axis note says which way is better and where the baseline
/// starts.
///
/// [truePace] only changes the wording: the caller passes True Pace values
/// when the run has them, and the chart says so.
class SplitsBars extends StatefulWidget {
  const SplitsBars({
    super.key,
    required this.bars,
    required this.units,
    required this.title,
    this.truePace = false,
  });

  final List<SplitBar> bars;
  final Units units;

  /// "KM SPLITS", "LAPS": the small caps line above the chart.
  final String title;
  final bool truePace;

  static const double kHeight = 160;

  /// The narrowest pace range the axis spans, s/km.
  static const double minSpanSec = 30;

  @override
  State<SplitsBars> createState() => _SplitsBarsState();
}

class _SplitsBarsState extends State<SplitsBars> {
  int? _selected;

  void _pick(double dx, double width, {bool toggle = false}) {
    final n = widget.bars.length;
    if (n == 0 || width <= 0) return;
    final i = (dx / (width / n)).floor().clamp(0, n - 1);
    if (widget.bars[i].paceSecPerKm == null) return;
    setState(() => _selected = toggle && _selected == i ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final bars = widget.bars;
    final units = widget.units;
    final paces = [
      for (final b in bars)
        if (b.paceSecPerKm != null) b.paceSecPerKm!,
    ];
    if (paces.length < 2) return const SizedBox.shrink();
    final fastest = paces.reduce(math.min);
    final slowest = paces.reduce(math.max);
    final unit = units == Units.mi ? 'mi' : 'km';
    // The axis never spans less than [minSpanSec]: splits within GPS noise
    // of each other read as level, not as a collapse.
    final span = math.max(slowest - fastest, SplitsBars.minSpanSec);
    final base = fastest + span * 1.15;
    final top = fastest - span * 0.06;
    // Cyan means "best", so it needs a standout: the fastest split alone or
    // tied by two at most. More ties than that (or all level) and none.
    final best = <int>{
      for (var i = 0; i < bars.length; i++)
        if (bars[i].paceSecPerKm != null &&
            bars[i].paceSecPerKm!.round() == fastest.round())
          i,
    };
    if (best.length > 2) best.clear();
    final sel = _selected != null && _selected! < bars.length
        ? _selected
        : null;
    final readout = sel == null ? null : bars[sel].readout;
    return Column(
      key: const ValueKey('splits-bars'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.truePace ? '${widget.title} · TRUE PACE' : widget.title,
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        // Fixed height, so picking a bar never moves the chart.
        SizedBox(
          height: 22,
          child: Text(
            readout ?? 'Tap a bar to see its pace',
            key: const ValueKey('splits-readout'),
            style: RunSoloType.label13.copyWith(
              color: readout == null ? t.inkMuted : t.inkPrimary,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
            key: const ValueKey('splits-chart-area'),
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                _pick(d.localPosition.dx, box.maxWidth, toggle: true),
            onHorizontalDragStart: (d) =>
                _pick(d.localPosition.dx, box.maxWidth),
            onHorizontalDragUpdate: (d) =>
                _pick(d.localPosition.dx, box.maxWidth),
            child: SizedBox(
              height: SplitsBars.kHeight,
              width: double.infinity,
              child: CustomPaint(
                painter: _SplitsPainter(
                  bars: bars,
                  units: units,
                  best: best,
                  selected: sel,
                  base: base,
                  top: top,
                  tokens: t,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.x8),
        Text(
          'Faster is taller. Fastest ${Fmt.pace(fastest, units)}/$unit. '
          'Axis starts at ${Fmt.pace(base, units)}/$unit.',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        if (widget.truePace) ...[
          const SizedBox(height: Space.x4),
          Text(
            'True pace takes hills and heat out. It is an estimate.',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        ],
      ],
    );
  }
}

class _SplitsPainter extends CustomPainter {
  _SplitsPainter({
    required this.bars,
    required this.units,
    required this.best,
    required this.selected,
    required this.base,
    required this.top,
    required this.tokens,
  });
  final List<SplitBar> bars;
  final Units units;
  final Set<int> best;
  final int? selected;
  final double base;
  final double top;
  final RunSoloTokens tokens;

  static const _topPad = 20.0, _bottomPad = 22.0;

  TextPainter _tp(String s, Color c, {FontWeight w = FontWeight.w500}) =>
      TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: RunSoloType.ui,
            fontSize: 11,
            fontWeight: w,
            color: c,
            fontFeatures: RunSoloType.tabular,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    if (n == 0) return;
    final bottom = size.height - _bottomPad;
    double y(double pace) =>
        bottom - (bottom - _topPad) * ((base - pace) / (base - top));
    final slot = size.width / n;
    final barW = math.min(24.0, slot * 0.6);
    final grid = Paint()
      ..color = tokens.lineHair
      ..strokeWidth = 1;
    for (var k = 1; k <= 3; k++) {
      final yy = bottom - (bottom - _topPad) * k / 3;
      canvas.drawLine(Offset(0, yy), Offset(size.width, yy), grid);
    }
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = tokens.inkMuted
        ..strokeWidth = 1,
    );
    // The pace above a bar and the number under it; once the bars get too
    // tight for the pace, every second one (the picked bar always).
    final paceW = _tp('00:00', tokens.inkSecondary).width + 4;
    final paceStep = math.max(1, (paceW / slot).ceil());
    final numStep = math.max(1, (26 / slot).ceil());
    for (var i = 0; i < n; i++) {
      final p = bars[i].paceSecPerKm;
      if (p == null) continue;
      final x = i * slot + (slot - barW) / 2;
      final rect = Rect.fromLTRB(x, y(p), x + barW, bottom);
      final isSel = selected == i;
      if (isSel) {
        canvas.drawRect(
          Rect.fromLTRB(i * slot, _topPad - 4, (i + 1) * slot, bottom),
          Paint()..color = tokens.inkPrimary.withValues(alpha: 0.08),
        );
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = best.contains(i) ? tokens.accentArc : tokens.inkMuted,
      );
      if (isSel) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect.inflate(2),
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()
            ..color = tokens.inkPrimary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (i % paceStep == 0 || isSel) {
        final hi = best.contains(i);
        final tp = _tp(
          Fmt.pace(p, units),
          hi
              ? tokens.accentArc
              : isSel
              ? tokens.inkPrimary
              : tokens.inkSecondary,
          w: hi || isSel ? FontWeight.w700 : FontWeight.w500,
        );
        final lx = (i * slot + slot / 2 - tp.width / 2).clamp(
          0.0,
          size.width - tp.width,
        );
        tp.paint(canvas, Offset(lx, y(p) - tp.height - (isSel ? 5 : 3)));
      }
    }
    for (var i = 0; i < n; i++) {
      final hi = best.contains(i) || selected == i;
      if (i % numStep != 0 && !hi) continue;
      final tp = _tp(
        bars[i].label,
        best.contains(i) ? tokens.accentArc : tokens.inkSecondary,
        w: hi ? FontWeight.w700 : FontWeight.w500,
      );
      tp.paint(canvas, Offset(i * slot + slot / 2 - tp.width / 2, bottom + 5));
    }
  }

  /// One node per bar, full column wide and tall, for a screen reader.
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final n = bars.length;
    final slot = size.width / n;
    return [
      for (var i = 0; i < n; i++)
        if (bars[i].paceSecPerKm != null)
          CustomPainterSemantics(
            rect: Rect.fromLTWH(i * slot, 0, slot, size.height),
            properties: SemanticsProperties(
              label:
                  bars[i].semantics ??
                  '${bars[i].label}, ${Fmt.pace(bars[i].paceSecPerKm, units)}',
              selected: selected == i,
              textDirection: TextDirection.ltr,
            ),
          ),
    ];
  };

  @override
  bool shouldRepaint(_SplitsPainter old) =>
      old.bars != bars ||
      old.best != best ||
      old.selected != selected ||
      old.base != base ||
      old.top != top ||
      old.tokens != tokens;
}
