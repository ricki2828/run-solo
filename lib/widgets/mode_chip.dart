import 'package:flutter/material.dart';

import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'structure_glyph.dart';

/// The run types at Start and Home (plan §3.2, design brief A8, A10.10):
/// INTERVALS (the old 4x4 slot, showing the last-used session and its
/// glyph), LAPS, FREE and the timed 5 km event, named from `kEventNames`
/// (founder 26-Sep: a run type of its own). Cooper (12-minute test) sits
/// under the "Tests" eyebrow (A5).
class ModeChipRow extends StatelessWidget {
  const ModeChipRow({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.session,
    this.event = false,
    this.onEvent,
  });
  final RecordMode selected;
  final ValueChanged<RecordMode> onSelect;

  /// The last-used Intervals session (name + glyph on the chip).
  final engine.SessionSpec session;

  /// The event chip is the picked one (then no mode chip is).
  final bool event;

  /// Picks the event; null hides its chip.
  final VoidCallback? onEvent;

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
                RecordMode.intervals => 'INTERVALS',
                RecordMode.laps => 'LAPS',
                RecordMode.free => 'FREE',
                RecordMode.cooper => 'TEST',
              },
              subtitle: switch (m) {
                RecordMode.intervals => session.name,
                RecordMode.laps => 'LAP by hand',
                RecordMode.free => 'Just run',
                RecordMode.cooper => '12 minutes',
              },
              selected: !event && selected == m,
              glyph: m == RecordMode.intervals && session.steps.isNotEmpty
                  ? session
                  : null,
              onTap: () => onSelect(m),
            ),
          ),
        ],
        if (onEvent != null) ...[
          const SizedBox(width: Space.x8),
          Expanded(
            child: ModeChip(
              key: const ValueKey('event-chip'),
              title: kEventNames.parkrun.toUpperCase(),
              subtitle: '5 km timed',
              selected: event,
              onTap: onEvent!,
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
    this.glyph,
  });

  /// Structure glyph under the subtitle (the INTERVALS chip, A8).
  final engine.SessionSpec? glyph;
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
              if (glyph == null)
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RunSoloType.label13.copyWith(
                    color: t.inkSecondary,
                    height: 1.2,
                  ),
                )
              else
                // One line above the glyph: shrink rather than cut the
                // session name ("Norwegian 4x4" at 360 dp, A8).
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    subtitle,
                    softWrap: false,
                    style: RunSoloType.label13.copyWith(
                      color: t.inkSecondary,
                      height: 1.2,
                    ),
                  ),
                ),
              if (glyph != null) ...[
                const SizedBox(height: Space.x4),
                StructureGlyph(spec: glyph!, height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
