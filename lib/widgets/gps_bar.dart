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
    final label = noFix ? 'GPS dropped' : 'GPS ${acc.round()} m';
    return Semantics(
      label: label,
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
          Text(label, style: RunSoloType.micro11.copyWith(color: color)),
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
