import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/settings.dart';
import '../widgets/goal_picker.dart';
import '../state/home_progress.dart';
import '../theme/theme.dart';
import '../widgets/home_scores.dart';
import '../widgets/recent_activity.dart';
import 'progress_screen.dart';

/// Scores-first Home. Start opens setup with the saved session unchanged;
/// results and recent activity remain history-backed, never synthetic.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.now,
    this.onShowHistory,
    this.onShowProgress,
    this.planHeadline,
  });

  /// Injected for tests; defaults to the wall clock.
  final DateTime Function()? now;

  /// "All activity" switches the shell to the History tab.
  final VoidCallback? onShowHistory;

  /// Switches the shell to Progress. Standalone Home pushes Progress.
  final VoidCallback? onShowProgress;

  /// Supplied only by a future persisted plan integration, never inferred.
  final ({String name, String subtitle})? planHeadline;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<RunSummary>>? _runs;
  Future<engine.HomeEstimates?>? _estimates;
  Future<Map<engine.IdentityLane, engine.IdentityScore>?>? _scores;
  Future<_HomeData>? _data;
  PermissionSnapshot? _perms;
  HistoryStore? _history;

  /// The event row shows only once a course exists (A10.4, K1).
  static bool _hasEventCourse(LiveContextSource live) => live.hasEventCourse;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final history = AppServices.of(context).history;
    if (_history != history) {
      _history?.derivedChanged.removeListener(_onDerivedChanged);
      _history = history..derivedChanged.addListener(_onDerivedChanged);
    }
    _refresh();
  }

  @override
  void dispose() {
    _history?.derivedChanged.removeListener(_onDerivedChanged);
    super.dispose();
  }

  void _refresh() {
    final services = AppServices.of(context);
    _runs = services.history.list();
    _loadEstimates();
    final runs = _runs!, scores = _scores;
    _data = _load(runs, scores);
    services.permissions.status().then((p) {
      if (mounted) setState(() => _perms = p);
    });
  }

  /// Never throws: a failed scores read comes back as [_HomeData.failed],
  /// so Home still shows Start and the run list.
  static Future<_HomeData> _load(
    Future<List<RunSummary>> runs,
    Future<Map<engine.IdentityLane, engine.IdentityScore>?>? scores,
  ) async {
    final r = await runs;
    final sc = scores == null
        ? const <engine.IdentityLane, engine.IdentityScore>{}
        : await scores;
    return sc == null ? _HomeData(r, const {}, failed: true) : _HomeData(r, sc);
  }

  void _loadEstimates() {
    // PD2: ESTIMATED TIMES and the fitness hero read the index's derived
    // data, prepared off the UI isolate; both show once the first prepare
    // lands.
    final live = AppServices.of(context).live;
    if (live != null) {
      _estimates = live.prepare().then(
        (_) => live.homeEstimates(includeEvent: _hasEventCourse(live)),
      );
      // A failed read becomes null here, so no error is left unhandled.
      _scores = live
          .prepare()
          .then<Map<engine.IdentityLane, engine.IdentityScore>?>(
            (_) => live.identityScores(),
          )
          .catchError((_) => null);
    } else {
      _scores = null;
    }
  }

  /// #72 review P3: a just-finished run's derived data lands a moment after
  /// the first prepare, so the card lagged one background batch. Re-run the
  /// estimates chain when the batch lands; prepare() re-reads the index only
  /// when it changed, so a no-op batch costs one stat.
  ///
  /// 29-Sep field test: reload EVERYTHING, RECENT ACTIVITY included - the
  /// finish flow pops back here without re-running [_refresh], so the new
  /// run only showed after an app restart.
  void _onDerivedChanged() {
    if (!mounted) return;
    setState(_refresh);
  }

  /// Start and Change both open setup; with a recommendation, setup opens
  /// preset to it (setup keeps it only if a run starts).
  Future<void> _start(Recommendation? rec) async {
    final perms = _perms;
    if (perms != null && !perms.canRecord) {
      final ok = await Navigator.of(context).pushNamed(Routes.permissions);
      if (!mounted || ok != true) {
        _refresh();
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).pushNamed(Routes.start, arguments: rec?.apply);
    if (mounted) setState(_refresh);
  }

  /// What Start would run from the saved choice, before any recommendation.
  static String _lastUsedName(AppSettings s, engine.SessionSpec picked) {
    if (s.goalRun) {
      final label = goalLabel(s);
      return label == 'Distance or time' ? 'goal run' : label;
    }
    return switch (s.lastMode) {
      RecordMode.free => 'free run',
      RecordMode.trail => 'trail run',
      RecordMode.laps =>
        picked.templateId == engine.SessionSpec.broncoId
            ? 'Bronco test'
            : 'laps run',
      RecordMode.cooper => '12-minute test',
      RecordMode.intervals => picked.name,
    };
  }

  void _openProgress() {
    if (widget.onShowProgress != null) {
      widget.onShowProgress!();
    } else {
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute(builder: (_) => const ProgressScreen()));
    }
  }

  void _openRun(RunSummary r) {
    Navigator.of(context).pushNamed(
      r.isFourByFour ? Routes.verdict : Routes.runDetail,
      arguments: r.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final text = Theme.of(context).textTheme;
    final services = AppServices.of(context);
    return ListenableBuilder(
      listenable: services.settings,
      builder: (context, _) {
        final settings = services.settings.settings;
        final perms = _perms;
        final plan = widget.planHeadline;
        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              child: Column(
                children: [
                  const SizedBox(height: Space.x24),
                  Row(
                    children: [
                      Text(
                        'RUN SUPREME',
                        style: RunSoloType.heading19.copyWith(
                          color: t.inkPrimary,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        Fmt.dayDate(_now),
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.x32),
                  FutureBuilder<_HomeData>(
                    future: _data,
                    builder: (context, snap) {
                      final data = snap.data;
                      final age = settings.birthYear == null
                          ? null
                          : _now.year - settings.birthYear!;
                      final rec = data == null || data.failed
                          ? null
                          : Recommendation.of(
                              data.scores,
                              data.runs,
                              now: _now,
                              sex: settings.profileSex,
                              age: age,
                              presetEdits: settings.allPresetEdits,
                            );
                      // Start and Change never wait on the scores: until
                      // they load (or if they fail) Start keeps the last
                      // run type.
                      final String startLabel;
                      if (plan != null) {
                        startLabel = 'Start ${plan.name}';
                      } else if (rec != null) {
                        startLabel = rec.startLabel;
                      } else {
                        startLabel =
                            'Start ${_lastUsedName(settings, services.pickedSession)}';
                      }
                      return Column(
                        children: [
                          _ProgressHero(
                            headline: data != null && !data.failed
                                ? ProgressHeadline.of(
                                    data.scores,
                                    now: _now,
                                    sex: settings.profileSex,
                                    age: age,
                                  )
                                : data != null || snap.hasError
                                ? ProgressHeadline.failed
                                : ProgressHeadline.loading,
                          ),
                          const SizedBox(height: Space.x16),
                          if (data != null && !data.failed) ...[
                            HomeScores(
                              scores: data.scores,
                              profileSex: settings.profileSex,
                              age: age,
                              onOpen: _openProgress,
                            ),
                            const SizedBox(height: Space.x16),
                          ],
                          _GetBetter(
                            reason: plan?.subtitle ?? rec?.reason,
                            startLabel: startLabel,
                            onStart: () => _start(plan == null ? rec : null),
                            onChange: () => _start(null),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: Space.x12),
                  if (perms != null && !perms.canRecord)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: InkWell(
                        onTap: () => _start(null),
                        child: Text(
                          perms.coarseOnly
                              ? 'Location is approximate. Precise is needed for pace.'
                              : 'Location permission needed before you can record.',
                          style: text.labelLarge?.copyWith(color: t.semDanger),
                        ),
                      ),
                    ),
                  FutureBuilder<List<RunSummary>>(
                    future: _runs,
                    builder: (context, snap) {
                      final runs =
                          (snap.data ?? const <RunSummary>[])
                              .where((r) => !r.missing)
                              .toList()
                            ..sort((a, b) => b.start.compareTo(a.start));
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FutureBuilder<engine.HomeEstimates?>(
                            future: _estimates,
                            builder: (context, estimateSnap) => RecentActivity(
                              runs: runs,
                              units: settings.units,
                              now: _now,
                              onOpen: _openRun,
                              onShowAll: widget.onShowHistory,
                              estimates: estimateSnap.data,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: Space.x24),
                  const SizedBox(height: Space.x24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeData {
  const _HomeData(this.runs, this.scores, {this.failed = false});
  final bool failed;
  final List<RunSummary> runs;
  final Map<engine.IdentityLane, engine.IdentityScore> scores;
}

class _ProgressHero extends StatelessWidget {
  const _ProgressHero({required this.headline});
  final ProgressHeadline headline;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          headline.title,
          style: RunSoloType.display44.copyWith(color: t.inkPrimary),
        ),
        Text(
          headline.line,
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}

/// One recommended session with its reason. Start opens setup preset to it;
/// Change opens the same screen to pick something else.
class _GetBetter extends StatelessWidget {
  const _GetBetter({
    required this.reason,
    required this.startLabel,
    required this.onStart,
    required this.onChange,
  });
  final String? reason;
  final String startLabel;
  final VoidCallback onStart;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reason != null)
          Text(
            'HOW TO GET BETTER',
            style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
          ),
        if (reason != null) ...[
          const SizedBox(height: Space.x4),
          Text(
            reason!,
            key: const ValueKey('home-recommendation'),
            style: RunSoloType.body15.copyWith(color: t.inkPrimary),
          ),
        ],
        const SizedBox(height: Space.x12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: onStart,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(startLabel, maxLines: 1),
                ),
              ),
            ),
            const SizedBox(width: Space.x8),
            OutlinedButton(onPressed: onChange, child: const Text('Change')),
          ],
        ),
      ],
    );
  }
}
