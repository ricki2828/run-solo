import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../theme/theme.dart';

/// The pre-run choice for a Free or goal run (founder 22-Oct): two big
/// buttons side by side, one tap, readable at arm's length. "Chase your best"
/// races the best run on file and says how you stand; "Steady run" says no
/// comparisons. The last one tapped is kept (settings) and shown selected.
///
/// Same grammar as the run-type cards above it (ui review 24-Oct #12): a 2 px
/// border in both states (Bone selected, hairline unselected), a one-line
/// title of 20 sp or less and a 96 dp minimum height (the same as the run-type
/// cards). Both cards grow to the taller one at large text sizes, so nothing
/// wraps unevenly or clips at 360 x 640.
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
                  title: 'Chase best',
                  subtitle: 'Vs your best, live',
                  selected: selected == engine.CoachChoice.chase,
                  onTap: () => onSelect(engine.CoachChoice.chase),
                ),
              ),
              const SizedBox(width: Space.x8),
              Expanded(
                child: _ChoiceButton(
                  key: steadyKey,
                  title: 'Steady',
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
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
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
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  style: RunSoloType.title28.copyWith(
                    fontSize: 20,
                    color: selected ? t.inkPrimary : t.inkSecondary,
                  ),
                ),
              ),
              const SizedBox(height: Space.x4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
