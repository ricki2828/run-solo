import 'package:flutter/material.dart';

import '../theme/theme.dart';

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
          padding: const EdgeInsets.all(Space.cardPadding),
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
