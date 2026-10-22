import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// The pre-run choice for a Free or goal run (founder 22-Oct): two big
/// buttons side by side, one tap, readable at arm's length. "Chase your best"
/// races the best run on file and says how you stand; "Steady run" says no
/// comparisons. The last one tapped is kept (settings) and shown selected.
///
/// Selected = a 2 px Bone border and Bone title; the other is muted. The
/// buttons share one height so a wrapped title never makes them uneven.
class CoachChoiceRow extends StatelessWidget {
  const CoachChoiceRow({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final engine.CoachChoice selected;
  final ValueChanged<engine.CoachChoice> onSelect;

  static const ValueKey<String> chaseKey = ValueKey('coach-choice-chase');
  static const ValueKey<String> steadyKey = ValueKey('coach-choice-steady');

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'HOW DO YOU WANT TO RUN?',
          style: RunSoloType.label13.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _ChoiceButton(
                  key: chaseKey,
                  title: 'Chase your best',
                  subtitle: 'Voice says how you stand',
                  selected: selected == engine.CoachChoice.chase,
                  onTap: () => onSelect(engine.CoachChoice.chase),
                ),
              ),
              const SizedBox(width: Space.x8),
              Expanded(
                child: _ChoiceButton(
                  key: steadyKey,
                  title: 'Steady run',
                  subtitle: 'No comparisons',
                  selected: selected == engine.CoachChoice.steady,
                  onTap: () => onSelect(engine.CoachChoice.steady),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
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
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.button),
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(Space.x16),
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.button),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: RunSoloType.title28.copyWith(
                  color: selected ? t.inkPrimary : t.inkSecondary,
                ),
              ),
              const SizedBox(height: Space.x4),
              Text(
                subtitle,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
