import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// GPS accuracy bar (design brief §4.4): full at ≤ 5 m, empty at 30 m,
/// `sem.warn` past 20 m, "GPS dropped" when there is no fix.
class GpsBar extends StatelessWidget {
  const GpsBar({super.key, required this.accuracyM, required this.lost});
  final double? accuracyM;
  final bool lost;

  static const double _best = 5;
  static const double _worst = 30;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final acc = accuracyM;
    final noFix = lost || acc == null;
    final fill = noFix
        ? 0.0
        : (1 - ((acc - _best) / (_worst - _best))).clamp(0.0, 1.0);
    final weak = !noFix && acc > 20;
    final color = noFix
        ? t.semWarn
        : weak
        ? t.semWarn
        : t.inkPrimary;
    // A8: no number under 36 sp on the record screen, so the on-screen
    // label is a status word; the accuracy stays in the bar's fill and in
    // the screen-reader label.
    // The "GPS dropped" words live in the banner only (S7): the bar shows
    // an empty warn-coloured fill under a plain "GPS". A first fix still
    // being awaited has no banner, so it keeps its own words.
    final label = lost
        ? 'GPS'
        : noFix
        ? 'GPS dropped'
        : weak
        ? 'GPS weak'
        : 'GPS';
    return Semantics(
      label: lost ? 'GPS dropped' : (noFix ? label : 'GPS ${acc.round()} m'),
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 6,
                child: Stack(
                  children: [
                    Container(color: t.bgSunken),
                    FractionallySizedBox(
                      widthFactor: fill,
                      child: Container(color: color),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.x12),
          Text(label, style: RunLabelScope.style(context, color)),
          const SizedBox(width: Space.x8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ],
      ),
    );
  }
}
