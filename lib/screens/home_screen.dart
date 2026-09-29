import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../theme/theme.dart';
import '../widgets/coaching.dart';
import '../widgets/estimated_times_card.dart';
import '../widgets/fitness_hero.dart';
import '../widgets/goal_picker.dart';
import '../widgets/mode_chip.dart';
import '../widgets/recent_activity.dart';
import 'settings_screen.dart';

/// Home as the dashboard (product call 27-Sep: "a summary of recent
/// activity, overall performance/trend/fitness level and able to kick off
/// new activity all at same time"; variant A signed off the same day):
/// Tally + date, the fitness hero (VO2 estimate, trend, source), RECENT
/// ACTIVITY (last three sessions of any kind), ESTIMATED TIMES, TRY NEXT,
/// and strap status. Five run-type choices lead directly to their Start setup.
/// Checklist incomplete = red row above the run-type choices.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.now, this.onShowHistory});

  /// Injected for tests; defaults to the wall clock.
  final DateTime Function()? now;

  /// "All activity" switches the shell to the History tab.
  final VoidCallback? onShowHistory;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<RunSummary>>? _runs;
  Future<engine.HomeEstimates?>? _estimates;
  Future<engine.FitnessHero?>? _hero;
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
      _hero = live.prepare().then((_) => live.fitnessHero());
    }
  }

  /// #72 review P3: a just-finished run's derived data lands a moment after
  /// the first prepare, so the card lagged one background batch. Re-run the
  /// estimates chain when the batch lands; prepare() re-reads the index only
  /// when it changed, so a no-op batch costs one stat.
  void _onDerivedChanged() {
    if (!mounted) return;
    setState(_loadEstimates);
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

  /// The Home choice is the entry to Start setup, not a saved preference
  /// followed by another selector. Start's pinned button begins recording.
  Future<void> _chooseType({RecordMode? mode, bool goal = false}) async {
    final services = AppServices.of(context);
    await services.settings.update(
      (s) => goal
          ? s.copyWith(goalRun: true)
          : s.copyWith(lastMode: mode!, goalRun: false),
    );
    if (mounted) await _start();
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
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'GO AGAIN.',
                      style: RunSoloType.display64.copyWith(
                        color: t.inkPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.x8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Your next run starts here. Your last run sets the line '
                      'to beat.',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ),
                  const SizedBox(height: Space.x16),
                  if (perms != null && !perms.canRecord)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x12),
                      child: InkWell(
                        onTap: _start,
                        child: Text(
                          perms.coarseOnly
                              ? 'Location is approximate. Precise is needed '
                                    'for pace.'
                              : 'Location permission needed before you can '
                                    'record.',
                          style: text.labelLarge?.copyWith(color: t.semDanger),
                        ),
                      ),
                    ),
                  ModeChipRow(
                    selected: settings.lastMode,
                    session: services.pickedSession,
                    goal: settings.goalRun,
                    goalLabel: goalLabel(settings),
                    testsSelected:
                        !settings.goalRun &&
                        settings.lastMode == RecordMode.cooper,
                    onGoal: () => _chooseType(goal: true),
                    onSelect: (m) => _chooseType(mode: m),
                    onTests: () => _chooseType(mode: RecordMode.cooper),
                  ),
                  const SizedBox(height: Space.x32),
                  FutureBuilder<engine.FitnessHero?>(
                    future: _hero,
                    builder: (context, snap) =>
                        FitnessHeroBlock(hero: snap.data),
                  ),
                  const SizedBox(height: Space.x24),
                  FutureBuilder<List<RunSummary>>(
                    future: _runs,
                    builder: (context, snap) => RecentActivity(
                      runs: snap.data ?? const [],
                      units: settings.units,
                      now: _now,
                      onOpen: _openRun,
                      onShowAll: widget.onShowHistory,
                    ),
                  ),
                  FutureBuilder<engine.HomeEstimates?>(
                    future: _estimates,
                    builder: (context, snap) {
                      final e = snap.data;
                      if (e == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: Space.x24),
                        child: EstimatedTimesCard(estimates: e),
                      );
                    },
                  ),
                  // A10.4: TRY NEXT under ESTIMATED TIMES (variant A, 27-Sep).
                  const SizedBox(height: Space.x24),
                  TryNextCard(
                    onSetUp: (change) async {
                      await services.settings.update(change);
                      if (context.mounted) await _start();
                    },
                  ),
                  const SizedBox(height: Space.x16),
                  if (settings.pendingObservedMaxHr != null)
                    _StrapRow(
                      label:
                          'Strap saw ${settings.pendingObservedMaxHr} bpm, tap to review',
                      muted: false,
                      warn: true,
                      onTap: () => showPendingMaxSheet(context),
                    ),
                  _StrapRow(
                    label: settings.strap == null
                        ? 'No strap, tap to pair'
                        : 'Strap: ${settings.strap!.label}',
                    muted: settings.strap == null,
                    onTap: () async {
                      await Navigator.of(context).pushNamed(Routes.pairing);
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

class _StrapRow extends StatelessWidget {
  const _StrapRow({
    required this.label,
    required this.muted,
    required this.onTap,
    this.warn = false,
  });
  final String label;
  final bool muted;
  final VoidCallback onTap;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              Icon(
                Icons.favorite,
                size: 16,
                color: warn ? t.semWarn : t.hrZone,
              ),
              const SizedBox(width: Space.x8),
              Expanded(
                child: Text(
                  label,
                  style: RunSoloType.body15.copyWith(
                    color: warn
                        ? t.semWarn
                        : muted
                        ? t.inkSecondary
                        : t.inkPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
