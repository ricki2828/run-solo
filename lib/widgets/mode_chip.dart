import 'package:flutter/material.dart';

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import '../theme/theme.dart';
import 'structure_glyph.dart';

/// The run types at Start and Home, in the founder's order (26-Sep, plan
/// §G): FREE · LAPS · GOAL · INTERVALS. INTERVALS shows the last-used
/// session and its glyph (A8); GOAL shows the picked goal. Four across only
/// from [rowMinWidth]; narrower it is a 2 × 2 grid, so no chip text drops
/// below 13 sp (founder readability rule). Cooper (12-minute test) sits
/// under the "Tests" eyebrow (A5).
class ModeChipRow extends StatelessWidget {
  const ModeChipRow({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.session,
    this.goal = false,
    this.goalLabel = 'Distance or time',
    this.onGoal,
  });
  final RecordMode selected;
  final ValueChanged<RecordMode> onSelect;

  /// The last-used Intervals session (name + glyph on the chip).
  final engine.SessionSpec session;

  /// GOAL is the picked chip (then no mode chip is).
  final bool goal;

  /// The picked goal, under the GOAL title.
  final String goalLabel;

  /// Picks GOAL; null hides its chip.
  final VoidCallback? onGoal;

  /// Below this width the four chips wrap into two rows.
  static const double rowMinWidth = 480;

  static const List<RecordMode> offered = [
    RecordMode.free,
    RecordMode.laps,
    RecordMode.intervals,
  ];

  Widget _mode(RecordMode m) => ModeChip(
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
    selected: !goal && selected == m,
    glyph: m == RecordMode.intervals && session.steps.isNotEmpty
        ? session
        : null,
    onTap: () => onSelect(m),
  );

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _mode(RecordMode.free),
      _mode(RecordMode.laps),
      if (onGoal != null)
        ModeChip(
          key: const ValueKey('goal-chip'),
          title: 'GOAL',
          subtitle: goalLabel,
          selected: goal,
          onTap: onGoal!,
        ),
      _mode(RecordMode.intervals),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        Widget row(List<Widget> items) => Row(
          children: [
            for (final (i, w) in items.indexed) ...[
              if (i > 0) const SizedBox(width: Space.x8),
              Expanded(child: w),
            ],
          ],
        );
        if (c.maxWidth >= rowMinWidth || chips.length < 4) return row(chips);
        return Column(
          children: [
            row(chips.sublist(0, 2)),
            const SizedBox(height: Space.x8),
            row(chips.sublist(2)),
          ],
        );
      },
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
              // 13 sp at any width (founder rule): a long session name
              // ellipsises, it never shrinks.
              Text(
                subtitle,
                maxLines: glyph == null ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: RunSoloType.label13.copyWith(
                  color: t.inkSecondary,
                  height: 1.2,
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
