import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/routes.dart';
import '../platform/gateway.dart';
import '../state/home_progress.dart';
import '../state/settings.dart';
import '../theme/theme.dart';
import 'home_score_spark.dart';

/// Only earned scores appear. Numeric display matches the product choice;
/// qualified bounds remain in semantics and Progress evidence.
class HomeScores extends StatelessWidget {
  const HomeScores({
    super.key,
    required this.scores,
    required this.profileSex,
    required this.age,
    required this.onOpen,
    this.onUnlock,
  });
  final Map<engine.IdentityLane, engine.IdentityScore> scores;
  final ProfileSex profileSex;
  final int? age;
  final VoidCallback onOpen;

  /// Opens Start preselected on the format that sets a lane; the empty-state
  /// rows are inert without it.
  final void Function(AppSettings Function(AppSettings))? onUnlock;

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
                color: scores[lane] != null ? t.semImproving : t.inkMuted,
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'SET YOUR SCORES',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          for (final lane in engine.IdentityLane.values)
            _UnlockRow(
              lane: lane,
              set: scores[lane] != null,
              onTap: onUnlock == null
                  ? null
                  : () => onUnlock!(_unlockApply(lane)),
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
        if (_footnote(earned, profileSex, age) case final note?) ...[
          const SizedBox(height: Space.x8),
          Text(
            note,
            key: const ValueKey('home-score-norms'),
            style: RunSoloType.label13.copyWith(color: t.inkSecondary),
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
  engine.IdentityLane.aerobic => 'a 12-minute test, or a hard 5K or 10K',
  engine.IdentityLane.speed => 'clean reps in 8 × 400 m',
  engine.IdentityLane.mid => 'a 5K or 10K run, try a goal 5K',
  engine.IdentityLane.long => 'a free run of 15K or more',
};

/// Start, preselected on the format that sets [lane].
AppSettings Function(AppSettings) _unlockApply(engine.IdentityLane lane) =>
    switch (lane) {
      engine.IdentityLane.aerobic => (s) => s.copyWith(
        lastMode: RecordMode.cooper,
        goalRun: false,
      ),
      engine.IdentityLane.speed => (s) => s.copyWith(
        lastMode: RecordMode.intervals,
        goalRun: false,
        sessionId: engine.SessionCatalogue.fourHundreds.id,
      ),
      engine.IdentityLane.mid => (s) => s.copyWith(
        goalRun: true,
        goalId: 'd5000',
      ),
      engine.IdentityLane.long => (s) => s.copyWith(
        lastMode: RecordMode.free,
        goalRun: false,
      ),
    };

/// The one line naming the norms behind the grid; null when the profile is
/// not enough for any card to compare (the cards say what to add).
String? _footnote(List<engine.IdentityLane> earned, ProfileSex sex, int? age) {
  if (sex != ProfileSex.male && sex != ProfileSex.female) return null;
  final who = sex == ProfileSex.female ? 'women' : 'men';
  final lab =
      earned.any(ScoreNorms.isLab) && age != null && age >= 20 && age <= 89
      ? '$who ${age ~/ 10 * 10}-${age ~/ 10 * 10 + 9} (lab norms)'
      : null;
  final race = earned.any((l) => !ScoreNorms.isLab(l))
      ? 'recreational race finishers ($who, all ages)'
      : null;
  final parts = [?lab, ?race];
  return parts.isEmpty ? null : 'Compared with ${parts.join(' and ')}.';
}

/// A compact tappable row (48 dp minimum) for a score not yet set.
class _UnlockRow extends StatelessWidget {
  const _UnlockRow({required this.lane, required this.set, this.onTap});
  final engine.IdentityLane lane;
  final bool set;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final label = '${lane.name.toUpperCase()}: ${_unlock(lane)}';
    return Semantics(
      button: onTap != null,
      label: set ? '${lane.name} set' : '$label. Opens Start.',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('home-unlock-${lane.name}'),
        onTap: set ? null : onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                set ? Icons.check_circle : Icons.circle_outlined,
                size: 16,
                color: set ? t.semImproving : t.inkMuted,
              ),
              const SizedBox(width: Space.x12),
              Expanded(
                child: Text(
                  label,
                  style: RunSoloType.label13.copyWith(
                    color: set ? t.inkPrimary : t.inkSecondary,
                  ),
                ),
              ),
              if (!set) Icon(Icons.chevron_right, color: t.inkSecondary),
            ],
          ),
        ),
      ),
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
    final lab = ScoreNorms.isLab(score.lane);
    final sexKnown =
        profileSex == ProfileSex.male || profileSex == ProfileSex.female;
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
    // Only a card that needs something shows its own line; the norms are named
    // once under the grid.
    final cohort = !sexKnown
        ? 'Add your sex to compare'
        : lab
        ? age == null
              ? 'Add your birth year to compare'
              : age! < 20 || age! > 89
              ? 'Ages 20-89 only'
              : null
        : null;
    // The score's history is the six-week-ago reading and today's; absent
    // when either has no percentile.
    final then = score.priorVdot == null || percentile == null
        ? null
        : ScoreNorms.percentile(
            score.lane,
            score.priorVdot!,
            score.priorSource ?? score.source,
            sex: profileSex,
            age: age,
          );
    final trend = [?then, ?percentile];
    final change = ScoreNorms.change(score, sex: profileSex, age: age);
    final (changeText, changeColour) = switch (change) {
      null => (null, t.inkSecondary),
      > 0 => ('Up $change in 6 weeks', t.semImproving),
      < 0 => ('Down ${-change} in 6 weeks', t.semSlower),
      _ => ('No change in 6 weeks', t.semNoise),
    };
    return Semantics(
      button: true,
      label:
          '${score.lane.name}, ${percentile == null ? 'percentile unavailable' : '$percentile${ScoreNorms.ordinalSuffix(percentile)} percentile'}, ${changeText == null ? '' : '$changeText, '}${cohort ?? (lab ? 'lab norms' : 'recreational race finishers')}. ${needsProfile ? 'Open settings.' : 'Open Progress.'}',
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
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: label,
                      style: RunSoloType.heading19.copyWith(
                        fontSize: 30,
                        color: t.inkPrimary,
                      ),
                    ),
                    // "60th percentile": the ordinal sits tight on the number.
                    TextSpan(
                      text: percentile == null
                          ? ' percentile'
                          : '${ScoreNorms.ordinalSuffix(percentile)} percentile',
                      style: RunSoloType.label13.copyWith(
                        color: t.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (trend.length >= 2) ...[
                const SizedBox(height: Space.x8),
                HomeScoreSpark(
                  key: ValueKey('home-spark-${score.lane.name}'),
                  values: trend,
                  rising: t.semImproving,
                  mutedColor: t.inkMuted,
                ),
              ],
              if (changeText != null) ...[
                const SizedBox(height: Space.x4),
                Text(
                  changeText,
                  style: RunSoloType.label13.copyWith(color: changeColour),
                ),
              ],
              if (cohort != null) ...[
                const SizedBox(height: Space.x4),
                Text(
                  cohort,
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
