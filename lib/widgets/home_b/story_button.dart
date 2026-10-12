import 'package:flutter/material.dart';

import '../../state/progress_snapshot.dart';
import '../../theme/lanes.dart';
import '../../theme/theme.dart';

/// The weekly story entry: last week in km and runs, with a button into the
/// full-screen story. A button, not a nag: it sits quietly on Home.
class StoryButton extends StatelessWidget {
  const StoryButton({super.key, required this.story, required this.onTap});

  final WeeklyStory story;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final lane = story.laneOfWeek;
    final fill = lane == null ? t.inkPrimary : t.laneFill(lane);
    final ink = readableOn(fill);
    final km = story.km.toStringAsFixed(1);
    return Semantics(
      button: true,
      label: 'Last week: $km km in ${story.runs} runs. See your week.',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('home-story'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sheet),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x16,
            vertical: Space.x12,
          ),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(Radii.sheet),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'YOUR WEEK',
                      style: RunSoloType.micro11.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$km KM, ${story.runs} ${story.runs == 1 ? 'RUN' : 'RUNS'}',
                      style: RunSoloType.heading26.copyWith(color: ink),
                    ),
                  ],
                ),
              ),
              Text(
                'See it',
                style: RunSoloType.body15.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(Icons.chevron_right, color: ink),
            ],
          ),
        ),
      ),
    );
  }
}
