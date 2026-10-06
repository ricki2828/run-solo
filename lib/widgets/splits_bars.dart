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
    final span = math.max(slowest - fastest, 1.0);
    final base = slowest + span * 0.15;
    final top = fastest - span * 0.06;
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
          'Faster is taller. Axis starts at ${Fmt.pace(base, units)}/$unit.',
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
    required this.fastest,
    required this.base,
    required this.top,
    required this.tokens,
  });
  final List<SplitBar> bars;
  final Units units;
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
    // Label every k-th bar so the numbers never touch; the fastest always.
    final step = math.max(1, (26 / slot).ceil());
    var best = -1;
    for (var i = 0; i < n; i++) {
      final p = bars[i].paceSecPerKm;
      if (p == null) continue;
      final isBest = p == fastest && best == -1;
      if (isBest) best = i;
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x, y(p), x + barW, bottom),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        Paint()..color = isBest ? tokens.accentArc : tokens.inkMuted,
      );
    }
    for (var i = 0; i < n; i++) {
      if (i % step != 0 && i != best) continue;
      final tp = _tp(
        bars[i].label,
        i == best ? tokens.accentArc : tokens.inkSecondary,
        w: i == best ? FontWeight.w700 : FontWeight.w500,
      );
      tp.paint(canvas, Offset(i * slot + slot / 2 - tp.width / 2, bottom + 5));
    }
    if (best >= 0) {
      final tp = _tp(
        Fmt.pace(fastest, units),
        tokens.accentArc,
        w: FontWeight.w700,
      );
      final cx = best * slot + slot / 2;
      tp.paint(
        canvas,
        Offset(
          (cx - tp.width / 2).clamp(0.0, size.width - tp.width),
          y(fastest) - tp.height - 3,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_SplitsPainter old) =>
      old.bars != bars ||
      old.base != base ||
      old.top != top ||
      old.tokens != tokens;
}
