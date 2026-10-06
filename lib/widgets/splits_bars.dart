import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// One bar on [SplitsBars]: the label under it and its pace (s/km). A null
/// pace (a lap with no distance) leaves the slot empty.
@immutable
class SplitBar {
  const SplitBar({required this.label, required this.paceSecPerKm});
  final String label;
  final double? paceSecPerKm;
}

/// Run detail's splits chart, in the leaderboard bar style
/// (`RecentBarsChart`): one vertical bar per km, mile or lap, taller =
/// faster, the fastest in Arc with its pace on top, the rest Bone. The axis
/// note says which way is better and where the baseline starts.
///
/// [truePace] only changes the wording: the caller passes True Pace values
/// when the run has them, and the chart says so.
class SplitsBars extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
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
    final span = math.max(slowest - fastest, minSpanSec);
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
    return Column(
      key: const ValueKey('splits-bars'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          truePace ? '$title · TRUE PACE' : title,
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        Semantics(
          label:
              'Pace per split, faster is taller. Fastest '
              '${Fmt.pace(fastest, units)} per $unit.',
          child: SizedBox(
            height: kHeight,
            width: double.infinity,
            child: CustomPaint(
              painter: _SplitsPainter(
                bars: bars,
                units: units,
                best: best,
                fastest: fastest,
                base: base,
                top: top,
                tokens: t,
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
        if (truePace) ...[
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
    required this.fastest,
    required this.base,
    required this.top,
    required this.tokens,
  });
  final List<SplitBar> bars;
  final Units units;
  final Set<int> best;
  final double fastest;
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
    // Label every k-th bar so the numbers never touch; highlighted ones
    // always.
    final step = math.max(1, (26 / slot).ceil());
    for (var i = 0; i < n; i++) {
      final p = bars[i].paceSecPerKm;
      if (p == null) continue;
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x, y(p), x + barW, bottom),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = best.contains(i) ? tokens.accentArc : tokens.inkMuted,
      );
    }
    for (var i = 0; i < n; i++) {
      final hi = best.contains(i);
      if (i % step != 0 && !hi) continue;
      final tp = _tp(
        bars[i].label,
        hi ? tokens.accentArc : tokens.inkSecondary,
        w: hi ? FontWeight.w700 : FontWeight.w500,
      );
      tp.paint(canvas, Offset(i * slot + slot / 2 - tp.width / 2, bottom + 5));
    }
    // The pace on top only while a few bars share the highlight; the axis
    // note carries the fastest pace either way.
    if (best.isNotEmpty) {
      final tp = _tp(
        Fmt.pace(fastest, units),
        tokens.accentArc,
        w: FontWeight.w700,
      );
      for (final i in best) {
        final cx = i * slot + slot / 2;
        tp.paint(
          canvas,
          Offset(
            (cx - tp.width / 2).clamp(0.0, size.width - tp.width),
            y(bars[i].paceSecPerKm!) - tp.height - 3,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SplitsPainter old) =>
      old.bars != bars ||
      old.best != best ||
      old.base != base ||
      old.top != top ||
      old.tokens != tokens;
}
