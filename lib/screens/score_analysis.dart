import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../state/settings.dart';
import '../theme/theme.dart';

/// The four earned identities in one place, with the evidence and the
/// qualified age-group context separate from the app's own display score.
class ScoreAnalysis extends StatefulWidget {
  const ScoreAnalysis({super.key});

  @override
  State<ScoreAnalysis> createState() => _ScoreAnalysisState();
}

class _ScoreAnalysisState extends State<ScoreAnalysis> {
  Future<Map<engine.IdentityLane, engine.IdentityScore>>? _scores;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppServices.of(context);
    if (_services != services) {
      _services = services;
      _scores = null;
    }
    final live = services.live;
    _scores ??= live == null
        ? Future.value(<engine.IdentityLane, engine.IdentityScore>{})
        : live.prepare().then((_) => live.identityScores());
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) => FutureBuilder(
        future: _scores,
        builder: (context, snap) {
          final settings = services.settings.settings;
          final scores =
              snap.data ?? const <engine.IdentityLane, engine.IdentityScore>{};
          final age = settings.birthYear == null
              ? null
              : services.now().year - settings.birthYear!;
          return ListView(
            key: const ValueKey('score-analysis'),
            padding: const EdgeInsets.fromLTRB(
              Space.screenGutter,
              Space.x8,
              Space.screenGutter,
              Space.x32,
            ),
            children: [
              Text(
                'ESTIMATED PERCENTILES',
                style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                'Best eligible effort in the past 42 days for each lane. '
                'Estimates use different reference groups; see each lane.',
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x24),
              for (final lane in engine.IdentityLane.values) ...[
                _LaneAnalysis(
                  lane: lane,
                  score: scores[lane],
                  age: age,
                  profileSex: settings.profileSex,
                ),
                const SizedBox(height: Space.x12),
              ],
              const SizedBox(height: Space.x12),
              Text(
                engine.FriendFitnessNorms.caveat,
                style: RunSoloType.body15.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                'MID/LONG: ${engine.RacePercentileNorms.source}. '
                'runrepeat.com/how-do-you-masure-up-the-runners-percentile-calculator',
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                '${engine.FriendFitnessNorms.source}. '
                'Kaminsky et al., Mayo Clinic Proceedings 2022;97:285-293, Table 3. doi.org/10.1016/j.mayocp.2021.08.020',
                style: RunSoloType.label13.copyWith(color: t.inkSecondary),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LaneAnalysis extends StatelessWidget {
  const _LaneAnalysis({
    required this.lane,
    required this.score,
    required this.age,
    required this.profileSex,
  });
  final engine.IdentityLane lane;
  final engine.IdentityScore? score;
  final int? age;
  final ProfileSex profileSex;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final s = score;
    final age = this.age;
    final String contextLine;
    String? estimate;
    if (s == null) {
      contextLine = switch (lane) {
        engine.IdentityLane.aerobic => 'Your first eligible session sets it.',
        engine.IdentityLane.speed => 'Log a clean interval session to unlock.',
        engine.IdentityLane.mid => 'Log a 5K or 10K effort to unlock.',
        engine.IdentityLane.long => 'Log a 15K+ run to unlock.',
      };
    } else if (profileSex != ProfileSex.male &&
        profileSex != ProfileSex.female) {
      contextLine = 'Set male or female in Settings to use these published reference tables.';
    } else if (age == null) {
      contextLine = 'Add your birth year in Settings to show an estimate.';
    } else if ((lane == engine.IdentityLane.aerobic ||
            lane == engine.IdentityLane.speed) &&
        (age! < 20 || age > 89)) {
      contextLine = 'FRIEND age-group comparison covers ages 20-89.';
    } else {
      final female = profileSex == ProfileSex.female;
      if (lane == engine.IdentityLane.aerobic ||
          lane == engine.IdentityLane.speed) {
        estimate = engine.FriendFitnessNorms.comparison(
          s.vdot,
          age!,
          female: female,
        );
        contextLine =
            'Estimated vs ${female ? 'women' : 'men'} '
            '${age ~/ 10 * 10}-${age ~/ 10 * 10 + 9} (FRIEND lab VO2peak).';
      } else {
        estimate = engine.RacePercentileNorms.comparison(
          s.vdot,
          lane,
          s.source,
          female: female,
        );
        final distance = engine.RacePercentileNorms.referenceDistance(
          lane,
          s.source,
        );
        contextLine =
            'Estimated $distance equivalent vs ${female ? 'women' : 'men'} '
            'race finishers (RunRepeat, all ages). Not an age percentile or race result.';
      }
    }
    return Container(
      key: ValueKey('analysis-${lane.name}'),
      padding: const EdgeInsets.all(Space.x16),
      decoration: BoxDecoration(
        color: t.bgRaised,
        border: Border.all(color: t.lineHair),
        borderRadius: BorderRadius.circular(Radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lane.name.toUpperCase(),
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
          const SizedBox(height: Space.x8),
          Text(
            s == null
                ? 'LOCKED'
                : estimate == null
                ? 'NO ESTIMATE'
                : '$estimate percentile',
            style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
          ),
          const SizedBox(height: Space.x8),
          if (s != null) ...[
            Text(
              '${s.source} · ${Fmt.dayDate(s.date)} · VDOT ${s.vdot.toStringAsFixed(1)}',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ],
          Text(
            contextLine,
            style: RunSoloType.body15.copyWith(color: t.inkSecondary),
          ),
          if (s != null)
            TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .pushNamed(Routes.runDetail, arguments: s.runId),
              child: const Text('VIEW SOURCE RUN'),
            ),
        ],
      ),
    );
  }
}
