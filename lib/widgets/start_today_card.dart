import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Start's planned session: "Today: Norwegian 4x4 · 4 reps" and the plan's
/// reason line. One tap picks that format and preset, so START launches it.
/// 64 dp tall at least, so it is an easy tap.
class StartTodayCard extends StatelessWidget {
  const StartTodayCard({
    super.key,
    required this.title,
    required this.reason,
    required this.selected,
    required this.onTap,
  });

  /// "Today: Norwegian 4x4 · 4 reps".
  final String title;
  final String reason;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $reason',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('start-today'),
        borderRadius: BorderRadius.circular(Radii.card),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x12,
            vertical: Space.x8,
          ),
          decoration: BoxDecoration(
            color: t.bgRaised,
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(
              color: selected ? t.inkPrimary : t.lineHair,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RunSoloType.heading19.copyWith(
                        color: t.inkPrimary,
                      ),
                    ),
                    const SizedBox(height: Space.x4),
                    Text(
                      reason,
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
              if (selected) ...[
                const SizedBox(width: Space.x8),
                Icon(Icons.check, size: 18, color: t.inkPrimary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
