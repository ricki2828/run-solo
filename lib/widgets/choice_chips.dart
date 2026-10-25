import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// The one filter control for History and Trends: chips in a wrap. Selected
/// = filled ink, the app's one selection grammar (the builder's segments, the
/// run-type cards); unselected = hairline outline. A wrap, not a sideways
/// scroll, so no chip is ever clipped at the edge.
class ChoiceChips extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
    this.keys,
  });
  final List<String> labels;
  final List<Key>? keys;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Wrap(
      spacing: Space.x8,
      runSpacing: Space.x8,
      children: [
        for (var i = 0; i < labels.length; i++)
          Semantics(
            button: true,
            selected: i == selected,
            child: GestureDetector(
              key: keys?[i],
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(i),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: Space.x16),
                decoration: BoxDecoration(
                  color: i == selected ? t.inkPrimary : t.bgRaised,
                  borderRadius: BorderRadius.circular(Radii.chip),
                  border: Border.all(
                    color: i == selected ? t.inkPrimary : t.lineHair,
                    width: 2,
                  ),
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    labels[i],
                    style: RunSoloType.label13.copyWith(
                      color: i == selected ? t.bgRaised : t.inkSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
