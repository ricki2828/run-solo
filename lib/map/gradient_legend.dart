/// The small key for the gradient-coloured route line: flat, up, steep, down.
library;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'gradient.dart';

class GradientLegend extends StatelessWidget {
  const GradientLegend({super.key});

  static const _items = [
    (GradientClass.flat, 'FLAT'),
    (GradientClass.up, 'UP'),
    (GradientClass.steep, 'STEEP'),
    (GradientClass.down, 'DOWN'),
  ];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Route colours: flat, up, steep, down',
      excludeSemantics: true,
      child: DecoratedBox(
        key: const ValueKey('gradient-legend'),
        decoration: BoxDecoration(
          color: NightSession.bgBase.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(Space.x8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x8,
            vertical: Space.x4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (c, label) in _items) ...[
                Container(
                  width: 14,
                  height: 5,
                  decoration: BoxDecoration(
                    color: GradientColours.of(c),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: Space.x4),
                Text(
                  label,
                  style: RunSoloType.label13.copyWith(
                    color: NightSession.inkPrimary,
                  ),
                ),
                if (c != GradientClass.down) const SizedBox(width: Space.x8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
