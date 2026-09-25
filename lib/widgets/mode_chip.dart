import 'package:flutter/material.dart';

import '../app/format.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';

/// Three chips at Start and Home (plan §18.2, addendum A2): 4x4, Laps,
/// Free. Cooper (12-minute test) is Phase 3 and not offered here.
class ModeChipRow extends StatelessWidget {
  const ModeChipRow({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.reps,
    required this.recoverySeconds,
  });
  final RecordMode selected;
  final ValueChanged<RecordMode> onSelect;
  final int reps;
  final int recoverySeconds;

  static const List<RecordMode> offered = [
    RecordMode.intervals,
    RecordMode.laps,
    RecordMode.free,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final m in offered) ...[
          if (m != offered.first) const SizedBox(width: Space.x8),
          Expanded(
            child: ModeChip(
              title: switch (m) {
                RecordMode.intervals => '4x4',
                RecordMode.laps => 'LAPS',
                RecordMode.free => 'FREE',
                RecordMode.cooper => 'TEST',
              },
              subtitle: switch (m) {
                RecordMode.intervals =>
                  '$reps × 4:00\n${Fmt.recovery(recoverySeconds)} rec',
                RecordMode.laps => 'LAP by hand',
                RecordMode.free => 'Just run',
                RecordMode.cooper => '12 minutes',
              },
              selected: selected == m,
              onTap: () => onSelect(m),
            ),
          ),
        ],
      ],
    );
  }
}

/// 96 dp mode chip; selected = 2 px Bone border (design brief §5).
class ModeChip extends StatelessWidget {
  const ModeChip({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $subtitle',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          curve: MotionCurves.standard,
          height: 96,
          padding: const EdgeInsets.all(Space.x12),
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  softWrap: false,
                  style: RunSoloType.title28.copyWith(
                    color: selected ? t.inkPrimary : t.inkSecondary,
                  ),
                ),
              ),
              const SizedBox(height: Space.x4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RunSoloType.label13.copyWith(
                  color: t.inkSecondary,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
