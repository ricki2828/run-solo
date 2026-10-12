import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/block_plan.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/load_guard.dart';
import '../state/settings.dart';
import 'start_screen.dart' show StartArgs;
import '../widgets/week_strip.dart';
import '../widgets/chrome.dart';
import '../widgets/goal_picker.dart';
import '../state/home_progress.dart';
import '../theme/theme.dart';
import '../state/progress_snapshot.dart';
import '../widgets/home_b/home_b.dart';
import '../widgets/readiness_line.dart';
import '../widgets/load_warning.dart';
import '../widgets/recent_activity.dart';
import '../widgets/section_card.dart';
import 'progress_screen.dart';

/// Direction B Home: the pack hero first, then the next session, the weekly
/// streak, the four scores as lane blocks, the last-month ghost and the weekly
/// story. The reusable pieces live in `widgets/home_b/home_b.dart`.
///
/// Scores-first Home. Start opens setup with the saved session unchanged;
/// results and recent activity remain history-backed, never synthetic.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.now,
    this.onShowHistory,
    this.onShowProgress,
    this.snapshot,
    this.onOpenStory,
  });

  /// Injected for tests and goldens; defaults to [buildProgressSnapshot] over
  /// the runs Home loaded.
  final ProgressSnapshot? snapshot;

  /// Opens the weekly story screen. Until that screen lands Home shows the
  /// week's headline in a sheet.
  final void Function(WeeklyStory story)? onOpenStory;

  /// Injected for tests; defaults to the wall clock.
  final DateTime Function()? now;

  /// "All activity" switches the shell to the History tab.
  final VoidCallback? onShowHistory;

  /// Switches the shell to Progress. Standalone Home pushes Progress.
  final VoidCallback? onShowProgress;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Future<List<RunSummary>>? _runs;
  Future<engine.HomeEstimates?>? _estimates;
  Future<String?>? _raceLine;
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
    final settings = services.settings.settings;
    _data = _load(
      runs,
      scores,
      now: _now,
      sex: settings.profileSex,
      birthYear: settings.birthYear,
    );
    services.permissions.status().then((p) {
      if (mounted) setState(() => _perms = p);
    });
  }

  /// Never throws: a failed scores read comes back as [_HomeData.failed],
  /// so Home still shows Start and the run list.
  static Future<_HomeData> _load(
    Future<List<RunSummary>> runs,
    Future<Map<engine.IdentityLane, engine.IdentityScore>?>? scores, {
    required DateTime now,
    required ProfileSex sex,
    required int? birthYear,
  }) async {
    final r = await runs;
    final sc = scores == null
        ? const <engine.IdentityLane, engine.IdentityScore>{}
        : await scores;
    final snap = buildProgressSnapshot(
      r,
      now: now,
      sex: sex,
      birthYear: birthYear,
    );
    return sc == null
        ? _HomeData(r, const {}, snap, failed: true)
        : _HomeData(r, sc, snap);
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
      _raceLine = live
          .prepare()
          .then<String?>((_) => live.raceEstimates()?.homeLine)
          .catchError((_) => null);
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

  /// Start and Change both open setup; with a session to preset, setup opens
  /// preset to it (setup keeps it only if a run starts).
  Future<void> _start(
    AppSettings Function(AppSettings)? apply, {
    bool ready = false,
  }) async {
    final perms = _perms;
    if (perms != null && !perms.canRecord) {
      final ok = await Navigator.of(context).pushNamed(Routes.permissions);
      if (!mounted || ok != true) {
        _refresh();
        return;
      }
    }
    if (!mounted) return;
    // The session button goes to Ready (the one START); Change and the
    // score tiles open the picker.
    await Navigator.of(context).pushNamed(
      Routes.start,
      arguments: ready ? StartArgs(preset: apply, readyFirst: true) : apply,
    );
    if (mounted) setState(_refresh);
  }

  static String _capitalised(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

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

  void _openStory(WeeklyStory story) {
    final open = widget.onOpenStory;
    if (open != null) return open(story);
    Navigator.of(context).pushNamed(Routes.weeklyStory, arguments: story);
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

  Future<void> _openPlan() async {
    await Navigator.of(context).pushNamed(Routes.plan);
    if (mounted) setState(_refresh);
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
      listenable: Listenable.merge([services.settings, services.plans]),
      builder: (context, _) {
        final settings = services.settings.settings;
        final perms = _perms;
        return Scaffold(
          appBar: RunAppBar(
            title: 'RUN SUPREME',
            showBack: false,
            trailing: FutureBuilder<_HomeData>(
              future: _data,
              builder: (context, snap) {
                final data = snap.data;
                final view = data == null || data.failed
                    ? null
                    : PlanContext(
                        runs: data.runs,
                        scores: data.scores,
                        now: _now,
                        maxHr: services.maxHr.maxHr,
                      ).view(
                        services.plans.plan,
                        loadDismissed: LoadDismissal.dismissed(settings, _now),
                      );
                return Text(
                  view == null ? Fmt.dayDate(_now) : PlanText.barLine(view),
                  style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                );
              },
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              child: Column(
                children: [
                  const SizedBox(height: Space.x16),
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
                      // The running plan, if any: judged from History's index
                      // rows and the same scores as the hero.
                      final planCtx = data == null
                          ? null
                          : PlanContext(
                              runs: data.runs,
                              scores: data.scores,
                              now: _now,
                              maxHr: services.maxHr.maxHr,
                            );
                      final planView = planCtx?.view(
                        services.plans.plan,
                        loadDismissed: LoadDismissal.dismissed(settings, _now),
                      );
                      final next = planView?.finished == false
                          ? planView!.next
                          : null;
                      final warned =
                          planCtx?.loadCheck.flag != null &&
                          !LoadDismissal.dismissed(settings, _now);
                      // Start and Change never wait on the scores: until
                      // they load (or if they fail) Start keeps the last
                      // run type.
                      final String startLabel;
                      if (next != null) {
                        startLabel = '${next.session.name} ›';
                      } else if (rec != null) {
                        startLabel = rec.startLabel;
                      } else {
                        startLabel =
                            '${_capitalised(_lastUsedName(settings, services.pickedSession))} ›';
                      }
                      // While the warning says an easy run is the safer
                      // choice, Start is the easy run; the planned hard
                      // session stays one tap away. A plan already eases its
                      // own next session, and a free run is already easy.
                      final hardPick =
                          next == null &&
                          warned &&
                          (rec == null
                              ? settings.lastMode != RecordMode.free &&
                                    settings.lastMode != RecordMode.trail
                              : rec.lane != engine.IdentityLane.long);
                      final plannedApply = next == null
                          ? rec?.apply
                          : PlanStart.apply(next.session);
                      final plannedName =
                          rec?.sessionName ??
                          _lastUsedName(settings, services.pickedSession);
                      final snap0 =
                          widget.snapshot ??
                          data?.snapshot ??
                          ProgressSnapshot.empty;
                      final firstRun = data == null || data.runs.isEmpty
                          ? null
                          : data.runs
                                .map((r) => r.start)
                                .reduce((a, b) => a.isBefore(b) ? a : b);
                      final weekN = firstRun == null
                          ? 1
                          : _now.difference(firstRun).inDays ~/ 7 + 1;
                      // No name is held in the app, so no greeting: the chip
                      // sits alone on the right.
                      return Column(
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: BlockChip(
                              key: const ValueKey('home-week-chip'),
                              label: snap0.streak.weeks >= 2
                                  ? '${snap0.streak.weeks} WK STREAK'
                                  : 'WEEK $weekN',
                              fill: t.inkPrimary,
                              ink: t.bgBase,
                            ),
                          ),
                          const SizedBox(height: Space.x8),
                          PackHero(
                            level: snap0.level,
                            pack: snap0.pack,
                            runCount: snap0.runCount,
                            needsProfile:
                                (settings.profileSex != ProfileSex.male &&
                                    settings.profileSex != ProfileSex.female) ||
                                settings.birthYear == null,
                            onAddProfile: () =>
                                Navigator.of(context)
                                    .pushNamed(Routes.settings),
                          ),
                          const SizedBox(height: Space.x16),
                          _GetBetter(
                            lane: rec?.lane ?? engine.IdentityLane.aerobic,
                            warning: warned
                                ? LoadWarning(
                                    flag: planCtx!.loadCheck.flag!,
                                    now: _now,
                                  )
                                : null,
                            summary: next == null || planView == null
                                ? null
                                : PlanText.homeLine(planView, _now),
                            reason: next?.session.reason ?? rec?.reason,
                            target: next == null
                                ? null
                                : PlanText.targetLine(
                                    next.session,
                                    planCtx?.vdot,
                                    settings.units,
                                  ),
                            startLabel: hardPick ? 'Easy run ›' : startLabel,
                            onStart: () => _start(
                              hardPick ? PlanStart.easyRun : plannedApply,
                              ready: true,
                            ),
                            anywayLabel: hardPick
                                ? 'Do the $plannedName anyway'
                                : null,
                            onAnyway: () => _start(plannedApply, ready: true),
                            onChange: () => _start(null),
                            planLabel: planView == null
                                ? (data == null || data.failed
                                      ? null
                                      : 'Build a 4-week plan around your scores')
                                : planView.finished
                                ? 'Plan done: ${planView.doneCount} of '
                                      '${planView.totalCount}. Build the next 4 weeks'
                                : 'See the plan',
                            onPlan: _openPlan,
                          ),
                          const SizedBox(height: Space.x16),
                          StreakCard(
                            streak: snap0.streak,
                            firstsDone: snap0.firstsDone,
                            firstsTotal: kFirstsTotal,
                          ),
                          const SizedBox(height: Space.x16),
                          if (data == null || data.failed) ...[
                            Text(
                              data == null
                                  ? ProgressHeadline.loading.line
                                  : ProgressHeadline.failed.line,
                              style: RunSoloType.body15.copyWith(
                                color: t.inkSecondary,
                              ),
                            ),
                            const SizedBox(height: Space.x16),
                          ],
                          if (data != null && !data.failed) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: Space.x8),
                              child: Text(
                                data.scores.isEmpty
                                    ? 'SET YOUR SCORES'
                                    : 'YOUR FOUR SCORES',
                                style: RunSoloType.micro11.copyWith(
                                  color: t.inkSecondary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            HomeLaneBlocks(
                              scores: data.scores,
                              profileSex: settings.profileSex,
                              age: age,
                              onOpen: _openProgress,
                              onUnlock: _start,
                            ),
                            const SizedBox(height: Space.x16),
                          ],
                          if (snap0.ghost != null) ...[
                            GhostCard(ghost: snap0.ghost!),
                            const SizedBox(height: Space.x16),
                          ],
                          if (snap0.story != null) ...[
                            StoryButton(
                              story: snap0.story!,
                              units: settings.units,
                              onTap: () => _openStory(snap0.story!),
                            ),
                            const SizedBox(height: Space.x16),
                          ],
                          if (data != null) ...[
                            SectionCard(
                              child: WeekStrip(
                                runs: data.runs,
                                zones: services.hrZones,
                                now: _now,
                              ),
                            ),
                            const SizedBox(height: Space.x16),
                          ],
                        ],
                      );
                    },
                  ),
                  if (perms != null && !perms.canRecord)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x16),
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
                          ReadinessLine(runs: runs, now: _now),
                          FutureBuilder<engine.HomeEstimates?>(
                            future: _estimates,
                            builder: (context, estimateSnap) =>
                                FutureBuilder<String?>(
                                  future: _raceLine,
                                  builder: (context, raceSnap) =>
                                      RecentActivity(
                                        runs: runs,
                                        units: settings.units,
                                        now: _now,
                                        onOpen: _openRun,
                                        onShowAll: widget.onShowHistory,
                                        estimates: estimateSnap.data,
                                        moreLine: raceSnap.data,
                                        onMore: _openProgress,
                                      ),
                                ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: Space.x8),
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
  const _HomeData(this.runs, this.scores, this.snapshot, {this.failed = false});
  final bool failed;

  /// Built once per load, not per rebuild.
  final ProgressSnapshot snapshot;
  final List<RunSummary> runs;
  final Map<engine.IdentityLane, engine.IdentityScore> scores;
}

/// One recommended session with its reason. Start opens setup preset to it;
/// Change opens the same screen to pick something else.
class _GetBetter extends StatelessWidget {
  const _GetBetter({
    required this.lane,
    required this.reason,
    required this.startLabel,
    required this.onStart,
    required this.onChange,
    this.summary,
    this.target,
    this.planLabel,
    this.onPlan,
    this.warning,
    this.anywayLabel,
    this.onAnyway,
  });
  final engine.IdentityLane lane;
  final String? reason;

  /// The plan's "This week: 2 of 3 done · Next: ..." line, when one runs.
  final String? summary;

  /// The pace the session aims at, when there is an estimate.
  final String? target;
  final String startLabel;
  final VoidCallback onStart;
  final VoidCallback onChange;

  /// The link to the Plan screen (or to build a plan).
  final String? planLabel;
  final VoidCallback? onPlan;

  /// The "don't overdo it" notice, when this week is running hot.
  final Widget? warning;

  /// While the warning is up, the planned hard session as a secondary link.
  final String? anywayLabel;
  final VoidCallback? onAnyway;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return LaneTintCard(
      lane: lane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reason != null)
            Text(
              'HOW TO GET BETTER',
              style: RunSoloType.micro11.copyWith(color: t.inkSecondary),
            ),
          if (summary != null) ...[
            const SizedBox(height: Space.x4),
            Text(
              summary!,
              key: const ValueKey('home-plan-line'),
              style: RunSoloType.body15.copyWith(color: t.inkPrimary),
            ),
          ],
          if (reason != null) ...[
            const SizedBox(height: Space.x4),
            Text(
              reason!,
              key: const ValueKey('home-recommendation'),
              style: RunSoloType.body15.copyWith(
                color: summary == null ? t.inkPrimary : t.inkSecondary,
              ),
            ),
          ],
          if (target != null) ...[
            const SizedBox(height: Space.x4),
            Text(
              target!,
              key: const ValueKey('home-plan-target'),
              style: RunSoloType.label13.copyWith(color: t.inkSecondary),
            ),
          ],
          const SizedBox(height: Space.x12),
          if (warning != null) ...[warning!, const SizedBox(height: Space.x12)],
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
          if (anywayLabel != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('home-do-anyway'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onAnyway,
                child: Text(anywayLabel!),
              ),
            ),
          if (planLabel != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('home-plan-link'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: Space.x12),
                ),
                onPressed: onPlan,
                child: Text(planLabel!),
              ),
            ),
        ],
      ),
    );
  }
}
