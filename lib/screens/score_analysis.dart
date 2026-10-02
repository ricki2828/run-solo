import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/identity_display.dart';
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
      _services?.history.derivedChanged.removeListener(_reloadScores);
      _services = services;
      services.history.derivedChanged.addListener(_reloadScores);
      _scores = null;
    }
    final live = services.live;
    _scores ??= live == null
        ? Future.value(<engine.IdentityLane, engine.IdentityScore>{})
        : live.prepare().then((_) => live.identityScores());
  }

  void _reloadScores() {
    if (!mounted) return;
    final live = _services?.live;
    setState(
      () => _scores = live == null
          ? Future.value(<engine.IdentityLane, engine.IdentityScore>{})
          : live.prepare().then((_) => live.identityScores()),
    );
  }

  @override
  void dispose() {
    _services?.history.derivedChanged.removeListener(_reloadScores);
    super.dispose();
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
                'HOW YOU COMPARE',
                style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x8),
              Text(
                'Based on your best qualifying run in the last 42 days. '
                'Each one compares with a different group.',
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
    var needsProfile = false;
    String? estimate;
    var extrapolated = false;
    if (s == null) {
      contextLine = switch (lane) {
        engine.IdentityLane.aerobic => 'Your first qualifying session sets it.',
        engine.IdentityLane.speed => 'Log a clean interval session to unlock.',
        engine.IdentityLane.mid =>
          'Log a clean continuous 5K or 10K effort to unlock.',
        engine.IdentityLane.long => 'Log a 15K+ run to unlock.',
      };
    } else if (profileSex != ProfileSex.male &&
        profileSex != ProfileSex.female) {
      needsProfile = true;
      contextLine = 'Add your sex in Settings to see how you compare.';
    } else if (age == null) {
      needsProfile = true;
      contextLine = 'Add your birth year in Settings to see how you compare.';
    } else if ((lane == engine.IdentityLane.aerobic ||
            lane == engine.IdentityLane.speed) &&
        (age < 20 || age > 89)) {
      contextLine = 'Age comparison only covers 20 to 89.';
    } else {
      final female = profileSex == ProfileSex.female;
      if (lane == engine.IdentityLane.aerobic ||
          lane == engine.IdentityLane.speed) {
        final e = engine.FriendFitnessNorms.estimate(
          s.vdot,
          age,
          female: female,
        );
        estimate = e?.label;
        extrapolated = e?.extrapolated ?? false;
        contextLine =
            'Estimate, compared with US ${female ? 'women' : 'men'} '
            '${age ~/ 10 * 10} to ${age ~/ 10 * 10 + 9} tested on a lab treadmill.';
      } else {
        final e = engine.RacePercentileNorms.estimate(
          s.vdot,
          lane,
          s.source,
          female: female,
        );
        estimate = e?.label;
        extrapolated = e?.extrapolated ?? false;
        final distance = engine.RacePercentileNorms.referenceDistance(
          lane,
          s.source,
        );
        contextLine =
            'Estimate. Based on your run, we guessed your $distance time and '
            'compared it with ${female ? 'women' : 'men'} recreational '
            'finishers, all ages. Not a race result.';
      }
    }
    final number = IdentityDisplay.percentileNumber(estimate);
    final time = s == null ? null : IdentityDisplay.equivalentTime(s);
    final timeLabel = IdentityDisplay.equivalentLabel(lane);
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
                ? 'CAN\'T COMPARE YET'
                : '$number percentile',
            style: RunSoloType.heading19.copyWith(color: t.inkPrimary),
          ),
          const SizedBox(height: Space.x8),
          if (s != null) ...[
            Text(
              '${s.source == 'Cooper test' ? '12-minute test' : s.source} · ${Fmt.dayDate(s.date)} · fitness index ${s.vdot.toStringAsFixed(1)}',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ],
          if (time != null && timeLabel != null)
            Text(
              '$timeLabel $time',
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          if (extrapolated && estimate != null)
            Text(
              '${(int.tryParse(number ?? '') ?? 50) > 50 ? 'Above' : 'Below'} '
              'the published table, so this is an estimate from the shape of '
              'the data.',
              key: ValueKey('analysis-${lane.name}-extrapolated'),
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          if (needsProfile)
            InkWell(
              key: ValueKey('analysis-${lane.name}-profile'),
              onTap: () => Navigator.of(context).pushNamed(Routes.settings),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x8),
                child: Text(
                  contextLine,
                  style: RunSoloType.body15.copyWith(
                    color: t.inkPrimary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            )
          else
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
