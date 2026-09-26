import 'package:flutter/material.dart';

import '../app/event_names.dart';
import '../state/settings.dart';
import '../theme/theme.dart';

/// The GOAL chip's subtitle: the picked goal ("10K", "30 min", the event's
/// own name from `kEventNames`).
String goalLabel(String goalId) {
  final g = GoalChoice.byId(goalId);
  if (g == null) return 'Distance or time';
  return g.id == GoalChoice.eventId ? kEventNames.parkrun : g.label;
}

/// GOAL (plan §G): Distance | Time, then the goal chips. Every chip is at
/// least 56 dp tall and its text 15 sp; goals that need the engine's G1
/// specs show but cannot be picked yet.
class GoalPicker extends StatelessWidget {
  const GoalPicker({super.key, required this.goalId, required this.onPick});
  final String goalId;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final picked = GoalChoice.byId(goalId);
    final byDistance = picked?.distance ?? true;
    final list = byDistance ? GoalChoice.distances : GoalChoice.times;
    Widget toggle(String label, bool on, List<GoalChoice> to) => Expanded(
      child: _Choice(
        key: ValueKey('goal-${label.toLowerCase()}'),
        label: label,
        selected: on,
        onTap: on
            ? null
            : () => onPick(
                to.firstWhere((g) => g.available, orElse: () => to.first).id,
              ),
      ),
    );
    return Column(
      key: const ValueKey('goal-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            toggle('Distance', byDistance, GoalChoice.distances),
            const SizedBox(width: Space.x8),
            toggle('Time', !byDistance, GoalChoice.times),
          ],
        ),
        const SizedBox(height: Space.x12),
        Wrap(
          spacing: Space.x8,
          runSpacing: Space.x8,
          children: [
            for (final g in list)
              _Choice(
                key: ValueKey('goal-${g.id}'),
                label: g.id == GoalChoice.eventId
                    ? kEventNames.parkrun
                    : g.label,
                selected: g.id == goalId,
                muted: !g.available,
                onTap: () => onPick(g.id),
              ),
          ],
        ),
        if (picked != null && !picked.available)
          Padding(
            padding: const EdgeInsets.only(top: Space.x8),
            child: Text(
              'Coming with the next build.',
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.muted = false,
  });
  final String label;
  final bool selected;
  final bool muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: muted ? '$label, coming with the next build' : label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56, minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: Space.x16),
          decoration: BoxDecoration(
            color: selected ? t.inkPrimary : t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(color: selected ? t.inkPrimary : t.lineHair),
          ),
          // Sized to its label (a Wrap chip), centred in the 56 dp height.
          child: Align(
            widthFactor: 1,
            child: Text(
              label,
              style: RunSoloType.body15.copyWith(
                color: selected
                    ? t.bgBase
                    : muted
                    ? t.inkMuted
                    : t.inkPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
