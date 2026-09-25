import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/zones.dart';

/// `ZONE 4 · HARD` + 5-segment vertical gauge (addendum A1): label and
/// number carry the meaning, colour is reinforcement. Segments 6 × 14 dp,
/// gap 2, filled Bone, empty white 20 %. Zone 0 reads the strap state.
class ZoneHeader extends StatelessWidget {
  const ZoneHeader({
    super.key,
    required this.zone,
    required this.paired,
    this.onZoneBackground = true,
  });
  final int zone;
  final bool paired;

  /// Bone labels when a zone background is active (A1), else secondary ink.
  final bool onZoneBackground;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final label = HrZones.label(zone, paired: paired);
    return Semantics(
      label: zone > 0
          ? 'Heart rate zone $zone, ${HrZones.words[zone].toLowerCase()}'
          : label.toLowerCase(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            key: const ValueKey('zone-label'),
            style: RunSoloType.label13.copyWith(
              color: onZoneBackground ? t.inkPrimary : t.inkSecondary,
              letterSpacing: 13 * 0.04,
            ),
          ),
          const SizedBox(width: Space.x8),
          ZoneGauge(zone: zone),
        ],
      ),
    );
  }
}

class ZoneGauge extends StatelessWidget {
  const ZoneGauge({super.key, required this.zone});
  final int zone;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= HrZones.count; i++) ...[
            if (i > 1) const SizedBox(width: 2),
            Container(
              width: 6,
              height: 14,
              decoration: BoxDecoration(
                color: i <= zone ? t.inkPrimary : HrZones.gaugeEmpty,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
