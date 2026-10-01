import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/next_session.dart';
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
  Future<
    ({
      engine.FitnessHero? hero,
      Map<engine.IdentityLane, engine.IdentityScore> scores,
    })
  >?
  _scores;
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
    services.permissions.status().then((p) {
      if (mounted) setState(() => _perms = p);
    });
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
      _scores = live.prepare().then(
        (_) => (hero: live.fitnessHero(), scores: live.identityScores()),
      );
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

  Future<void> _start() async {
    final perms = _perms;
    if (perms != null && !perms.canRecord) {
      final ok = await Navigator.of(context).pushNamed(Routes.permissions);
      if (!mounted || ok != true) {
        _refresh();
        return;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).pushNamed(Routes.start);
    if (mounted) setState(_refresh);
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
        final next = plan != null
            ? NextSession.plan(plan.name)
            : NextSession.lastUsed(settings, services.pickedSession);
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
                  FutureBuilder<List<RunSummary>>(
                    future: _runs,
                    builder: (context, snap) => HomeHeadline(
                      next: next,
                      runs: snap.data ?? const [],
                      units: settings.units,
                      planSubtitle: widget.planHeadline?.subtitle,
                    ),
                  ),
                  const SizedBox(height: Space.x16),
                  FutureBuilder<
                    ({
                      engine.FitnessHero? hero,
                      Map<engine.IdentityLane, engine.IdentityScore> scores,
                    })
                  >(
                    future: _scores,
                    builder: (context, snap) => HomeScores(
                      scores: snap.data?.scores ?? const {},
                      profileSex: settings.profileSex,
                      age: settings.birthYear == null
                          ? null
                          : _now.year - settings.birthYear!,
                      onOpen: _openProgress,
                    ),
                  ),
                  const SizedBox(height: Space.x16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _start,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(next.startLabel, maxLines: 1),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.x8),
                      OutlinedButton(
                        onPressed: _start,
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.x12),
                  if (perms != null && !perms.canRecord)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: InkWell(
                        onTap: _start,
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

/// Headline, line and Start all come from [next]. The number is the one that
/// session is judged on, from its last comparable run; none yet means "set
/// your line" for that session.
class HomeHeadline extends StatelessWidget {
  const HomeHeadline({
    super.key,
    required this.next,
    required this.runs,
    required this.units,
    this.planSubtitle,
  });
  final NextSession next;
  final List<RunSummary> runs;
  final Units units;
  final String? planSubtitle;

  @override
  Widget build(BuildContext context) {
    final String title, subtitle;
    if (next.kind == NextKind.plan) {
      title = '${next.name.toUpperCase()} TODAY';
      subtitle = planSubtitle ?? 'Next up in your plan.';
    } else if (nextBeat(next, runs, units) case final beat?) {
      title = 'BEAT ${beat.value}';
      subtitle = beat.line;
    } else {
      title = 'SET YOUR LINE';
      subtitle = hasUnusableRun(next, runs)
          ? next.kind == NextKind.interval
                ? 'Your last ${next.name} had no clean reps to beat. Your next one sets the line.'
                : 'Your last ${next.name} had nothing to compare. Your next one sets the line.'
          : 'Your first ${next.name} is the one to beat.';
    }
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: RunSoloType.display64.copyWith(color: t.inkPrimary)),
        Text(
          subtitle,
          style: RunSoloType.body15.copyWith(color: t.inkSecondary),
        ),
      ],
    );
  }
}
