import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../state/settings.dart';
import '../theme/theme.dart';

/// Only earned scores appear. Numeric display matches the product choice;
/// qualified bounds remain in semantics and Progress evidence.
class HomeScores extends StatelessWidget {
  const HomeScores({
    super.key,
    required this.scores,
    required this.profileSex,
    required this.age,
    required this.onOpen,
  });
  final Map<engine.IdentityLane, engine.IdentityScore> scores;
  final ProfileSex profileSex;
  final int? age;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    if (scores.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(right: Space.x8),
                  child: Icon(
                    Icons.circle_outlined,
                    size: 12,
                    color: t.inkMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.x8),
          Text(
            'Scores grow from clean intervals, a 5K and a 15K+ run.',
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'YOUR SCORES',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final lane in engine.IdentityLane.values)
                if (scores[lane] case final score?)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.x8),
                    child: _EarnedScore(
                      score: score,
                      profileSex: profileSex,
                      age: age,
                      onOpen: onOpen,
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EarnedScore extends StatelessWidget {
  const _EarnedScore({
    required this.score,
    required this.profileSex,
    required this.age,
    required this.onOpen,
  });
  final engine.IdentityScore score;
  final ProfileSex profileSex;
  final int? age;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final lab =
        score.lane == engine.IdentityLane.aerobic ||
        score.lane == engine.IdentityLane.speed;
    final sexKnown =
        profileSex == ProfileSex.male || profileSex == ProfileSex.female;
    final female = profileSex == ProfileSex.female;
    final comparison = !sexKnown
        ? null
        : lab
        ? age == null
              ? null
              : engine.FriendFitnessNorms.comparison(
                  score.vdot,
                  age!,
                  female: female,
                )
        : engine.RacePercentileNorms.comparison(
            score.vdot,
            score.lane,
            score.source,
            female: female,
          );
    final label = comparison == null
        ? '--'
        : RegExp(r'\d+').firstMatch(comparison)!.group(0)!;
    final cohort = !sexKnown
        ? 'Set profile for comparison'
        : lab
        ? age == null
              ? 'Add birth year'
              : age! < 20 || age! > 89
              ? 'Ages 20-89 only'
              : '${female ? 'women' : 'men'} ${age! ~/ 10 * 10} to ${age! ~/ 10 * 10 + 9}'
        : '${female ? 'women' : 'men'} race finishers · all ages';
    return Semantics(
      button: true,
      label:
          '${score.lane.name}, ${comparison ?? 'percentile unavailable'}, $cohort, estimate. Open Progress.',
      child: InkWell(
        key: ValueKey('home-score-${score.lane.name}'),
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
          width: 136,
          padding: const EdgeInsets.all(Space.x12),
          decoration: BoxDecoration(
            color: t.bgRaised,
            border: Border.all(color: t.lineHair),
            borderRadius: BorderRadius.circular(Radii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                score.lane.name.toUpperCase(),
                style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x4),
              Text(
                label,
                style: RunSoloType.heading19.copyWith(
                  fontSize: 30,
                  color: t.inkPrimary,
                ),
              ),
              Text(
                'percentile',
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x4),
              Text(
                cohort,
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
