import 'package:flutter/material.dart';

import '../app/format.dart';
import '../state/zone_histogram.dart';
import '../theme/theme.dart';
import '../theme/zones.dart';

/// Time in zone, in colour: one stacked bar of the share of moving time per
/// zone, then a row per zone (swatch, name, bar to scale, %, m:ss). Zones
/// with no time stay as dimmed rows so the scale reads. Hues are for
/// graphics only; every row says its zone in words.
class TimeInZone extends StatelessWidget {
  const TimeInZone({super.key, required this.seconds, required this.maxHrLine});
  final List<double> seconds;
  final String maxHrLine;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final shares = ZoneShares.from(seconds);
    if (shares == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final total = shares.seconds.fold(0.0, (a, b) => a + b);
    final note = shares.partialNote;
    return Column(
      key: const ValueKey('time-in-zone'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TIME IN ZONE',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x4),
        Text(
          maxHrLine,
          key: const ValueKey('time-in-zone-max-hr'),
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
        if (note != null) ...[
          const SizedBox(height: Space.x4),
          Text(
            note,
            key: const ValueKey('time-in-zone-partial'),
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ],
        const SizedBox(height: Space.x12),
        SizedBox(
          height: 14,
          child: Row(
            key: const ValueKey('time-in-zone-bar'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var z = 1, shown = 0; z <= 5; z++)
                if (shares.seconds[z - 1] > 0) ...[
                  if (shown++ > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: (shares.seconds[z - 1] / total * 1000).round().clamp(
                      1,
                      1000,
                    ),
                    child: DecoratedBox(
                      key: ValueKey('time-in-zone-segment-$z'),
                      decoration: BoxDecoration(
                        color: HrZones.distribution(z, brightness),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
            ],
          ),
        ),
        const SizedBox(height: Space.x16),
        for (var z = 1; z <= 5; z++)
          _ZoneRow(
            zone: z,
            seconds: shares.seconds[z - 1],
            percent: shares.percents[z - 1],
            share: shares.seconds[z - 1] / total,
            hue: HrZones.distribution(z, brightness),
          ),
      ],
    );
  }
}

class _ZoneRow extends StatelessWidget {
  const _ZoneRow({
    required this.zone,
    required this.seconds,
    required this.percent,
    required this.share,
    required this.hue,
  });
  final int zone;
  final double seconds;
  final int percent;
  final double share;
  final Color hue;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final name = 'Z$zone · ${HrZones.name(zone)}';
    final time = Fmt.clock((seconds * 1000).round());
    final pct = seconds > 0 && percent == 0 ? '<1%' : '$percent%';
    final style = RunSoloType.label13.copyWith(color: t.inkPrimary);
    return Semantics(
      container: true,
      label: '$name, $pct, $time',
      child: ExcludeSemantics(
        child: Opacity(
          key: ValueKey('time-in-zone-row-$zone'),
          opacity: seconds > 0 ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x4),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: hue,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const SizedBox(width: 12, height: 12),
                ),
                const SizedBox(width: Space.x8),
                SizedBox(width: 84, child: Text(name, style: style)),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: ColoredBox(
                      color: t.bgSunken,
                      child: SizedBox(
                        height: 8,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            heightFactor: 1,
                            widthFactor: seconds > 0
                                ? share.clamp(0.02, 1.0)
                                : 0,
                            child: ColoredBox(color: hue),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: Space.x8),
                SizedBox(
                  width: 36,
                  child: Text(pct, textAlign: TextAlign.right, style: style),
                ),
                const SizedBox(width: Space.x8),
                SizedBox(
                  width: 44,
                  child: Text(time, textAlign: TextAlign.right, style: style),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
