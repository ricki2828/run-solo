import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/zones.dart';

/// bpm + % max. Strap dropped shows "--" and "reconnecting", never 0
/// (design brief §4.4). Hidden entirely when no strap is paired.
class HrBadge extends StatelessWidget {
  const HrBadge({
    super.key,
    required this.hr,
    required this.paired,
    required this.maxHr,
    this.large = false,
    this.onZone = false,
  });
  final int? hr;
  final bool paired;
  final int maxHr;
  final bool large;

  /// On a zone background labels render in Bone 70 % (addendum A1).
  final bool onZone;

  @override
  Widget build(BuildContext context) {
    if (!paired) return const SizedBox.shrink();
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final dropped = hr == null;
    final pct = hr == null || maxHr <= 0 ? null : (hr! * 100 / maxHr).round();
    final numberStyle = (large ? RunSoloType.display44 : RunSoloType.title28)
        .copyWith(
          color: dropped
              ? (onZone ? HrZones.secondaryOnZone : t.inkMuted)
              : t.inkPrimary,
        );
    return Semantics(
      label: dropped ? 'Heart rate strap reconnecting' : 'Heart rate $hr',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Icon(Icons.favorite, size: 16, color: t.hrZone),
          const SizedBox(width: Space.x8),
          Text(dropped ? '--' : '$hr', style: numberStyle),
          const SizedBox(width: Space.x8),
          Text(
            dropped ? 'reconnecting' : '$pct%',
            style: RunSoloType.label13.copyWith(
              color: dropped
                  ? t.semWarn
                  : onZone
                  ? HrZones.secondaryOnZone
                  : t.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
