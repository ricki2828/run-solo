import 'package:flutter/material.dart';

import '../state/settings.dart';
import '../theme/theme.dart';

/// Where a session runs, asked on Ready for intervals and the 12-minute test:
/// "Outdoors" (GPS, as always) or "On a treadmill" (no GPS; time, heart rate
/// and the distance markers). Choosing the treadmill opens the incline chips
/// (0 / 1 / 2 / 3+ %, the last one tapped is remembered) and, at 0 %, a one
/// line hint. Drawn in the Ready ground's ink, like the coach choice row.
class SurfaceChoiceRow extends StatelessWidget {
  const SurfaceChoiceRow({
    super.key,
    required this.onTreadmill,
    required this.incline,
    required this.onSurface,
    required this.onIncline,
    required this.onGround,
    this.compact = false,
  });

  /// Tight screens: no label line, 48 dp buttons.
  final bool compact;

  final bool onTreadmill;

  /// The remembered incline, percent (one of
  /// [AppSettings.treadmillInclineChoices]).
  final int incline;
  final ValueChanged<bool> onSurface;
  final ValueChanged<int> onIncline;
  final ({Color ink, Color onInk}) onGround;

  static const ValueKey<String> outdoorsKey = ValueKey('surface-outdoors');
  static const ValueKey<String> treadmillKey = ValueKey('surface-treadmill');
  static const ValueKey<String> hintKey = ValueKey('incline-hint');

  /// The chip key for an incline value.
  static ValueKey<String> inclineKey(int pct) => ValueKey('incline-$pct');

  /// "3+" for the top chip, else the number.
  static String inclineText(int pct) => pct >= 3 ? '3+%' : '$pct%';

  /// The one-line hint at 0 %.
  static const String flatHint = 'Set 1% to match outdoor effort.';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The label goes where the screen is tight (intervals: the session's
        // shape needs the room); the buttons say it themselves.
        if (!compact) ...[
          Text(
            'WHERE ARE YOU RUNNING?',
            style: RunSoloType.label13.copyWith(
              color: onGround.ink,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Space.x8),
        ],
        Row(
          children: [
            Expanded(
              child: _Pick(
                key: outdoorsKey,
                title: 'Outdoors',
                selected: !onTreadmill,
                onGround: onGround,
                onTap: () => onSurface(false),
                minHeight: compact ? 48 : 56,
              ),
            ),
            const SizedBox(width: Space.x8),
            Expanded(
              child: _Pick(
                key: treadmillKey,
                title: 'On a treadmill',
                selected: onTreadmill,
                onGround: onGround,
                onTap: () => onSurface(true),
                minHeight: compact ? 48 : 56,
              ),
            ),
          ],
        ),
        if (onTreadmill) ...[
          const SizedBox(height: Space.x8),
          Row(
            children: [
              Text(
                'INCLINE',
                style: RunSoloType.label13.copyWith(
                  color: onGround.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: Space.x12),
              for (final pct in AppSettings.treadmillInclineChoices) ...[
                Expanded(
                  child: _Pick(
                    key: inclineKey(pct),
                    title: inclineText(pct),
                    selected: incline == pct,
                    onGround: onGround,
                    onTap: () => onIncline(pct),
                    minHeight: 48,
                    size: 20,
                  ),
                ),
                if (pct != AppSettings.treadmillInclineChoices.last)
                  const SizedBox(width: Space.x4),
              ],
            ],
          ),
          if (incline == 0) ...[
            const SizedBox(height: Space.x4),
            Text(
              flatHint,
              key: hintKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RunSoloType.body15.copyWith(color: onGround.ink),
            ),
          ],
        ],
      ],
    );
  }
}

class _Pick extends StatelessWidget {
  const _Pick({
    super.key,
    required this.title,
    required this.selected,
    required this.onGround,
    required this.onTap,
    this.minHeight = 56,
    this.size = 20,
  });

  final String title;
  final bool selected;
  final ({Color ink, Color onInk}) onGround;
  final VoidCallback onTap;
  final double minHeight;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: title,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Space.x8),
          decoration: BoxDecoration(
            color: selected ? onGround.ink : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: onGround.ink, width: 2),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              maxLines: 1,
              softWrap: false,
              style: RunSoloType.title28.copyWith(
                fontSize: size,
                color: selected ? onGround.onInk : onGround.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
