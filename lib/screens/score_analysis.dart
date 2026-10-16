import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/identity_display.dart';
import '../app/quest_sync.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/progress_snapshot.dart';
import '../state/quests/quest_build.dart';
import '../state/settings.dart';
import '../share/share_card.dart';
import '../share/share_card_sheet.dart';
import '../theme/theme.dart';
import '../widgets/pack_panel.dart';
import '../widgets/quests_section.dart';
import '../widgets/race_estimates_card.dart';
import 'boards_overview.dart';

/// The Progress tab body: QUESTS, YOUR PACK (age band from published norms),
/// BOARDS & RECORDS, then the four earned identities with the evidence and
/// the qualified age-group context separate from the app's own display score.
class ScoreAnalysis extends StatefulWidget {
  const ScoreAnalysis({super.key, this.snapshot, this.questBoard});

  /// Goldens and widget tests pass a fixture; production builds one from the
  /// run history with [buildProgressSnapshot].
  final ProgressSnapshot? snapshot;

  /// Goldens pass a fixture board; production builds one from the runs.
  final QuestBoard? questBoard;

  @override
  State<ScoreAnalysis> createState() => _ScoreAnalysisState();
}

class _ScoreAnalysisState extends State<ScoreAnalysis> {
  Future<Map<engine.IdentityLane, engine.IdentityScore>>? _scores;
  Future<engine.RaceEstimates?>? _race;
  Future<ProgressSnapshot>? _snap;
  Future<QuestBoard>? _board;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppServices.of(context);
    if (_services != services) {
      _services?.history.derivedChanged.removeListener(_reloadScores);
      _services?.quests.removeListener(_reloadQuests);
      _services = services;
      services.history.derivedChanged.addListener(_reloadScores);
      services.quests.addListener(_reloadQuests);
      _scores = null;
      _race = null;
      _snap = null;
      _board = null;
    }
    _snap ??= _loadSnapshot(services);
    _board ??= _loadBoard(services);
    final live = services.live;
    _scores ??= live == null
        ? Future.value(<engine.IdentityLane, engine.IdentityScore>{})
        : live.prepare().then((_) => live.identityScores());
    _race ??= _loadRace(live);
  }

  static Future<engine.RaceEstimates?> _loadRace(LiveContextSource? live) =>
      live == null
      ? Future.value(null)
      : live
            .prepare()
            .then<engine.RaceEstimates?>((_) => live.raceEstimates())
            .catchError((_) => null);

  Future<ProgressSnapshot> _loadSnapshot(AppServices services) async {
    final fixed = widget.snapshot;
    if (fixed != null) return fixed;
    final runs = await services.history.list();
    final q = await syncQuests(services, runs);
    final s = services.settings.settings;
    return buildProgressSnapshot(
      runs,
      now: services.now(),
      sex: s.profileSex,
      birthYear: s.birthYear,
      pausedWeeks: q.pausedWeeks,
    );
  }

  /// Never throws: a failure leaves the QUESTS section out.
  Future<QuestBoard> _loadBoard(AppServices services) async {
    final fixed = widget.questBoard;
    if (fixed != null) return fixed;
    if (widget.snapshot != null) return QuestBoard.empty;
    try {
      final List<RunSummary> runs = await services.history.list();
      await syncQuests(services, runs);
      final inputs = questInputsOf(runs);
      final now = services.now();
      return buildQuestBoard(
        services.quests.state,
        inputs,
        now,
        exposed: questsExposed(inputs.runs, now),
      );
    } catch (e) {
      return QuestBoard.empty;
    }
  }

  void _reloadQuests() {
    if (!mounted) return;
    setState(() {
      _snap = _loadSnapshot(_services!);
      _board = _loadBoard(_services!);
    });
  }

  void _reloadScores() {
    if (!mounted) return;
    final live = _services?.live;
    setState(() {
      _snap = _loadSnapshot(_services!);
      _board = _loadBoard(_services!);
      _scores = live == null
          ? Future.value(<engine.IdentityLane, engine.IdentityScore>{})
          : live.prepare().then((_) => live.identityScores());
      _race = _loadRace(live);
    });
  }

  @override
  void dispose() {
    _services?.history.derivedChanged.removeListener(_reloadScores);
    _services?.quests.removeListener(_reloadQuests);
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
            // The whole page is a short list: build it all, so every lane
            // card exists for finders and screen readers.
            scrollCacheExtent: const ScrollCacheExtent.pixels(10000),
            padding: const EdgeInsets.fromLTRB(
              Space.screenGutter,
              Space.x8,
              Space.screenGutter,
              Space.x32,
            ),
            children: [
              FutureBuilder<QuestBoard>(
                future: _board,
                initialData: widget.questBoard,
                builder: (context, snap) {
                  final board = snap.data ?? QuestBoard.empty;
                  if (board.isEmpty) {
                    return const SizedBox.shrink(key: ValueKey('quests-none'));
                  }
                  final quests = services.quests;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Space.x32),
                    child: QuestsSection(
                      board: board,
                      onTake: () => quests.accept(services.now()),
                      onAnother: quests.another,
                      onSkip: quests.skip,
                      onDrop: () => quests.drop(services.now()),
                    ),
                  );
                },
              ),
              FutureBuilder<ProgressSnapshot>(
                future: _snap,
                initialData: widget.snapshot,
                builder: (context, snap) => PackPanel(
                  snapshot: snap.data ?? ProgressSnapshot.empty,
                  units: settings.units,
                  onOpenSettings: () =>
                      Navigator.of(context).pushNamed(Routes.settings),
                  onShare: packShareData(snap.data?.pack) == null
                      ? null
                      : () => showShareCardSheet(
                          context,
                          data: PackCardData(
                            pack: packShareData(snap.data?.pack)!,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: Space.x32),
              Text(
                'BOARDS & RECORDS',
                style: RunSoloType.title28.copyWith(color: t.inkPrimary),
              ),
              const SizedBox(height: Space.x8),
              const BoardsOverview(embedded: true),
              const SizedBox(height: Space.x24),
              FutureBuilder<engine.RaceEstimates?>(
                future: _race,
                builder: (context, snap) {
                  final race = snap.data;
                  if (race == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Space.x24),
                    child: RaceEstimatesCard(estimates: race),
                  );
                },
              ),
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
              if (scores.isNotEmpty) ...[
                const SizedBox(height: Space.x16),
                OutlinedButton(
                  key: const ValueKey('share-scores'),
                  onPressed: () => showShareCardSheet(
                    context,
                    data: scoresCardData(
                      scores,
                      sex: settings.profileSex,
                      age: age,
                    ),
                  ),
                  child: const Text('SHARE MY SCORES'),
                ),
              ],
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
          if (s != null && s.source != 'Cooper test')
            Text(
              'Scored at true pace: hills and heat taken out.',
              key: ValueKey('analysis-${lane.name}-truepace'),
              style: RunSoloType.body15.copyWith(color: t.inkSecondary),
            ),
          if (s != null &&
              (s.source == engine.TrailScore.longSource ||
                  s.source == 'trail run'))
            Text(
              '${engine.TrailScore.note}.',
              key: ValueKey('analysis-${lane.name}-trail'),
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
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
