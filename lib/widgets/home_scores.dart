import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/routes.dart';
import '../state/home_progress.dart';
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
    final earned = [
      for (final lane in engine.IdentityLane.values)
        if (scores[lane] != null) lane,
    ];
    final dots = Wrap(
      spacing: Space.x12,
      runSpacing: Space.x4,
      children: [
        for (final lane in engine.IdentityLane.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                scores[lane] != null
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                size: 12,
                color: scores[lane] != null ? t.inkPrimary : t.inkMuted,
              ),
              const SizedBox(width: Space.x4),
              Text(
                lane.name.toUpperCase(),
                style: RunSoloType.micro11.copyWith(
                  color: scores[lane] != null ? t.inkPrimary : t.inkSecondary,
                ),
              ),
            ],
          ),
      ],
    );
    if (earned.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final lane in engine.IdentityLane.values)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(
                      Icons.circle_outlined,
                      size: 12,
                      color: t.inkMuted,
                    ),
                  ),
                  const SizedBox(width: Space.x8),
                  Expanded(
                    child: Text(
                      '${lane.name.toUpperCase()}: ${_unlock(lane)}',
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    Widget card(engine.IdentityLane lane) => _EarnedScore(
      score: scores[lane]!,
      profileSex: profileSex,
      age: age,
      onOpen: onOpen,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'YOUR SCORES',
          style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
        ),
        const SizedBox(height: Space.x8),
        for (var i = 0; i < earned.length; i += 2) ...[
          if (i > 0) const SizedBox(height: Space.x8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: card(earned[i])),
                const SizedBox(width: Space.x8),
                Expanded(
                  child: i + 1 < earned.length
                      ? card(earned[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
        if (earned.length < engine.IdentityLane.values.length) ...[
          const SizedBox(height: Space.x12),
          dots,
        ],
      ],
    );
  }
}

String _unlock(engine.IdentityLane lane) => switch (lane) {
  engine.IdentityLane.aerobic => 'a hard 5K or 10K, or a 12-minute test',
  engine.IdentityLane.speed => 'clean reps in an intervals session',
  engine.IdentityLane.mid => 'a 5K or 10K run',
  engine.IdentityLane.long => 'a 15K+ run',
};

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
    final lab = ScoreNorms.isLab(score.lane);
    final sexKnown =
        profileSex == ProfileSex.male || profileSex == ProfileSex.female;
    final female = profileSex == ProfileSex.female;
    final percentile = ScoreNorms.percentile(
      score.lane,
      score.vdot,
      score.source,
      sex: profileSex,
      age: age,
    );
    final label = percentile?.toString() ?? '--';
    // A card that names what to add opens Settings, not Progress.
    final needsProfile = !sexKnown || (lab && age == null);
    final cohort = !sexKnown
        ? 'Add your sex to compare'
        : lab
        ? age == null
              ? 'Add your birth year to compare'
              : age! < 20 || age! > 89
              ? 'Ages 20-89 only'
              : '${female ? 'Women' : 'Men'} ${age! ~/ 10 * 10} to ${age! ~/ 10 * 10 + 9}, lab norms'
        : '${female ? 'Women' : 'Men'}, recreational race finishers, all ages';
    final change = ScoreNorms.change(score, sex: profileSex, age: age);
    final (changeText, changeColour) = switch (change) {
      null => (null, t.inkSecondary),
      > 0 => ('Up $change in 6 weeks', NightSession.semImproving),
      < 0 => ('Down ${-change} in 6 weeks', t.semSlower),
      _ => ('No change in 6 weeks', t.semNoise),
    };
    return Semantics(
      button: true,
      label:
          '${score.lane.name}, ${percentile == null ? 'percentile unavailable' : '$percentile percentile'}, ${changeText == null ? '' : '$changeText, '}$cohort. ${needsProfile ? 'Open settings.' : 'Open Progress.'}',
      child: InkWell(
        key: ValueKey('home-score-${score.lane.name}'),
        onTap: needsProfile
            ? () => Navigator.of(context).pushNamed(Routes.settings)
            : onOpen,
        borderRadius: BorderRadius.circular(Radii.card),
        child: Container(
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    label,
                    style: RunSoloType.heading19.copyWith(
                      fontSize: 30,
                      color: t.inkPrimary,
                    ),
                  ),
                  const SizedBox(width: Space.x4),
                  Text(
                    'percentile',
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
              if (changeText != null) ...[
                const SizedBox(height: Space.x4),
                Text(
                  changeText,
                  style: RunSoloType.label13.copyWith(color: changeColour),
                ),
              ],
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
