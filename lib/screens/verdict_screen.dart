import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/routes.dart';
import '../app/quest_sync.dart';
import '../app/services.dart';
import '../platform/gateway.dart';
import '../state/history_store.dart';
import '../state/max_hr.dart';
import '../state/progress_snapshot.dart';
import '../state/spoken_summary.dart';
import '../state/zone_histogram.dart';
import '../theme/theme.dart';
import '../widgets/board_chips.dart';
import '../widgets/chrome.dart';
import '../widgets/coaching.dart';
import '../widgets/delta_glyph.dart';
import '../widgets/feel_row.dart';
import '../widgets/rep_bars.dart';
import '../widgets/recent_activity.dart' show runTypeColor;
import '../widgets/result_b/result_b.dart';
import '../widgets/section_card.dart';
import '../widgets/splits_bars.dart';
import 'cooper_result_screen.dart';
import 'course_board_screen.dart';
import 'moment_screen.dart';
import 'board_detail_screen.dart';
import 'bronco_result_screen.dart';
import 'run_detail_screen.dart';
import 'trail_suggest_card.dart';
import 'trail_verdict_screen.dart';

/// The moment to show for a run that made several pending: a finished
/// quest, then PB, level-up, first and the weekly story; engine order breaks
/// ties.
@visibleForTesting
Moment pickMoment(List<Moment> pending) {
  int rank(Moment m) => switch (m.kind) {
    MomentKind.quest => 0,
    MomentKind.pb => 1,
    MomentKind.levelUp => 2,
    MomentKind.first => 3,
    MomentKind.story => 4,
  };
  return pending.reduce((a, b) => rank(b) < rank(a) ? b : a);
}

/// Post-run screen (design brief §4.6). A 4x4 gets the verdict with the M4
/// reveal; a Laps or Free run gets its summary (no verdict word, plan
/// §18.2). Opened right after Stop and from History rows.
///
/// M4 is Flutter-authored for now (one `AnimationController`, intervals per
/// beat); the Rive file replaces the middle beats when the founder has
/// iterated the timing. Reduced motion: end state, 160 ms fade.
class VerdictScreen extends StatefulWidget {
  const VerdictScreen({
    super.key,
    required this.runId,
    this.justFinished = false,
  });
  final String runId;

  /// Opened from Stop: fold this run's observed max HR into settings and show
  /// "Done" instead of a back arrow.
  final bool justFinished;

  @override
  State<VerdictScreen> createState() => _VerdictScreenState();
}

class _VerdictScreenState extends State<VerdictScreen> {
  Future<(RunDetail?, RunSummary?, List<RunSummary>)>? _load;

  /// The spoken summary is said once, for the run that has just finished.
  bool _spoke = false;

  /// At most one moment, once, after the result is up.
  bool _momentChecked = false;
  Timer? _momentTimer;

  @override
  void dispose() {
    _momentTimer?.cancel();
    super.dispose();
  }

  /// A just-finished run may unlock a full-screen moment: the first unseen
  /// one, shown over the result a beat after it appears, then marked seen.
  /// Never for a run that is not fresh (a replayed or imported run keeps its
  /// old timestamps), and nothing is scheduled when no moment is pending.
  Future<void> _maybeShowMoment(RunDetail detail, List<RunSummary> all) async {
    if (_momentChecked || !widget.justFinished) return;
    _momentChecked = true;
    final services = AppServices.of(context);
    final now = services.now();
    if (now.difference(detail.run.end).abs() > const Duration(hours: 2)) {
      return;
    }
    final seen = services.seenMoments;
    final p = services.settings.settings;
    // A run that finishes a quest closes it here, so QUEST DONE can show.
    final q = await syncQuests(services, all);
    final snapshot = buildProgressSnapshot(
      all,
      now: now,
      sex: p.profileSex,
      birthYear: p.birthYear,
      seenMoments: await seen.load(),
      pausedWeeks: q.pausedWeeks,
      questHistory: q.history,
    );
    if (snapshot.pending.isEmpty || !mounted) return;
    // One moment per run: the highest priority (PB, level-up, first, then
    // the weekly story). Every other moment this run made pending is marked
    // seen with it, so a stale "your first 5K" never shows after a later
    // run. The firsts still count on Home and Progress. A story that was
    // not the one shown stays pending: it has its own entry point.
    final moment = pickMoment(snapshot.pending);
    final toMark = [
      for (final m in snapshot.pending)
        if (m.kind != MomentKind.story || m.id == moment.id) m.id,
    ];
    _momentTimer = Timer(const Duration(milliseconds: 900), () async {
      if (!mounted) return;
      await seen.markSeen(toMark);
      if (!mounted) return;
      await showMoment(context, moment);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= _loadDetail();
  }

  Future<(RunDetail?, RunSummary?, List<RunSummary>)> _loadDetail() async {
    final services = AppServices.of(context);
    final detail = await services.history.load(widget.runId);
    if (detail == null) return (null, null, const <RunSummary>[]);
    final all = await services.history.list();
    final previous = previousFourByFour(all, detail.summary);
    // Fold on every load, not only right after Stop: the guard ignores
    // anything at or below the stored value, so this is idempotent, and a
    // run whose verdict screen never opened (app died after Stop) still
    // folds the next time it is viewed.
    final observed =
        detail.analysis.intervals?.observedMaxHrThisRun ??
        detail.analysis.laps?.observedMaxHrThisRun;
    if (observed != null) {
      await services.settings.update(
        (s) => MaxHr.foldObserved(s, observed, detail.run.end),
      );
    }
    if (widget.justFinished) unawaited(_maybeShowMoment(detail, all));
    if (widget.justFinished && !_spoke) {
      _spoke = true;
      unawaited(
        speakRunSummary(
          services.recorder,
          services.settings.settings,
          detail,
          all,
        ),
      );
    }
    return (detail, previous, all);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    return FutureBuilder<(RunDetail?, RunSummary?, List<RunSummary>)>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) {
          final history = AppServices.of(context).history;
          if (widget.justFinished &&
              history is FileRunStore &&
              history.isWaitingForWeather(widget.runId)) {
            return const Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: Space.x16),
                    Text('Checking weather'),
                  ],
                ),
              ),
            );
          }
          return const Scaffold(body: SizedBox.shrink());
        }
        final (detail, previous, all) = snap.data!;
        if (detail == null) {
          return Scaffold(
            appBar: const RunAppBar(title: 'RUN'),
            body: Padding(
              padding: const EdgeInsets.all(Space.screenGutter),
              child: Text(
                'This run could not be read. Its file may be missing.',
                style: RunSoloType.body17.copyWith(color: t.inkSecondary),
              ),
            ),
          );
        }
        return switch (detail.summary.mode) {
          // A GOAL run has its own result, no verdict (29-Sep field test:
          // the first 8K landed here and showed a giant NO VERDICT).
          RecordMode.intervals when detail.summary.spec?.isGoal == true =>
            _GoalResultScreen(
              detail: detail,
              all: all,
              justFinished: widget.justFinished,
            ),
          RecordMode.intervals => _FourByFourVerdict(
            detail: detail,
            previous: previous,
            all: all,
            justFinished: widget.justFinished,
            // K1: an official time or a course move recomputes the verdict.
            onChanged: () => setState(() {
              _load = _loadDetail();
            }),
          ),
          // C1: the test result replaces the verdict (A5, A10.5).
          RecordMode.cooper => CooperResultScreen(
            detail: detail,
            justFinished: widget.justFinished,
          ),
          // Bronco (manual sets, founder 28-Sep): its result, like C1.
          RecordMode.laps
              when detail.summary.spec?.templateId ==
                  engine.SessionSpec.broncoId =>
            BroncoResultScreen(
              detail: detail,
              justFinished: widget.justFinished,
            ),
          // A Trail run is judged on the same trail when there is a match,
          // else on true pace (engine `TrailVerdict`).
          RecordMode.trail => TrailVerdictScreen(
            detail: detail,
            all: all,
            justFinished: widget.justFinished,
            onChanged: () => setState(() {
              _load = _loadDetail();
            }),
          ),
          RecordMode.laps || RecordMode.free => _SummaryScreen(
            detail: detail,
            justFinished: widget.justFinished,
            // A re-tag (Trail suggestion) reloads the run under its new type.
            onChanged: () => setState(() {
              _load = _loadDetail();
            }),
          ),
        };
      },
    );
  }
}

/// The nearest earlier Intervals run of the same comparison key (plan
/// §3.7: like with like) with metrics, for the ghost bars.
RunSummary? previousFourByFour(List<RunSummary> all, RunSummary current) {
  final key = current.comparisonKey ?? current.spec?.comparisonKey;
  for (final r in all) {
    if (r.id == current.id) continue;
    if (!r.start.isBefore(current.start)) continue;
    if (!r.isFourByFour || !r.hasIntervals) continue;
    final k = r.comparisonKey ?? r.spec?.comparisonKey;
    if (key == null || k == null || k == key) return r;
  }
  return null;
}

/// Which M4 branch a verdict takes (design brief §3 M4 `state` input).
enum RevealState { baseline, faster, holding, slower, noise, none }

RevealState revealStateOf(engine.Verdict? v) {
  if (v == null) return RevealState.none;
  return switch (v.headline) {
    engine.VerdictHeadline.faster => RevealState.faster,
    engine.VerdictHeadline.holding => RevealState.holding,
    engine.VerdictHeadline.slower => RevealState.slower,
    engine.VerdictHeadline.noRealChange => RevealState.noise,
    engine.VerdictHeadline.baselineSet => RevealState.baseline,
    engine.VerdictHeadline.noVerdict ||
    engine.VerdictHeadline.indoorRun => RevealState.none,
  };
}

/// Rep rows for the bars: this run's reps against the previous run's.
List<RepBarDatum> repBarData(
  RunDetail detail,
  RunSummary? previous, {
  engine.HrZones? zones,
}) {
  final m = detail.analysis.intervals;
  if (m == null) return const [];
  final ghost = previous?.repPacesSecPerKm;
  return [
    for (final r in m.reps)
      RepBarDatum(
        label: 'Rep ${r.number}',
        paceSecPerKm: r.paceSecPerKm,
        repMetres: m.kind == engine.IntervalMetricKind.repTime
            ? m.nominalRepMetres
            : null,
        ghostSecPerKm: ghost != null && r.number - 1 < ghost.length
            ? ghost[r.number - 1]
            : null,
        zone: zones == null
            ? null
            : dominantZoneOf(
                detail.run,
                zones,
                (s) => s.tMs >= r.trimmedT0Ms && s.tMs < r.trimmedT1Ms,
              ),
        excluded: !r.clean,
        reason: r.dropped
            ? 'dropped'
            : switch (r.interruptReason) {
                engine.InterruptReason.gpsDropped => 'GPS dropped',
                engine.InterruptReason.paused => 'paused',
                engine.InterruptReason.recordingStopped => 'recording stopped',
                null => null,
              },
      ),
  ];
}

class _FourByFourVerdict extends StatefulWidget {
  const _FourByFourVerdict({
    required this.detail,
    required this.previous,
    required this.justFinished,
    this.all = const [],
    this.onChanged,
  });
  final RunDetail detail;
  final RunSummary? previous;
  final bool justFinished;

  /// Every run (K1 course labels and rank).
  final List<RunSummary> all;
  final VoidCallback? onChanged;

  @override
  State<_FourByFourVerdict> createState() => _FourByFourVerdictState();
}

class _FourByFourVerdictState extends State<_FourByFourVerdict>
    with SingleTickerProviderStateMixin {
  // M4 beats on a 900 ms timeline: bars 0-250, delta count-up 250-600,
  // verdict word (and a PB flash) 600-900.
  static const int _totalMs = 900;
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _totalMs),
  );
  late final Animation<double> _bars = _beat(0, 250);
  late final Animation<double> _delta = _beat(250, 600, MotionCurves.standard);
  late final Animation<double> _word = _beat(600, 900, MotionCurves.emphasized);
  late final Animation<double> _bloom = _beat(600, 900);
  late final Animation<double> _lines = _beat(600, 900);
  bool _hapticsFired = false;

  Animation<double> _beat(int from, int to, [Curve curve = Curves.linear]) =>
      CurvedAnimation(
        parent: _reveal,
        curve: Interval(from / _totalMs, to / _totalMs, curve: curve),
      );

  bool get _reduced =>
      MediaQuery.disableAnimationsOf(context) ||
      AppServices.of(context).settings.settings.reducedMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reveal.isAnimating || _reveal.isCompleted) return;
    if (_reduced) {
      // Static branch: the final state straight away (design brief §3).
      _reveal.value = 1;
      _fireHaptics();
    } else {
      _reveal.addListener(_onTick);
      _reveal.forward();
    }
  }

  bool _secondPulseFired = false;

  void _onTick() {
    final ms = _reveal.value * _totalMs;
    if (!_hapticsFired && ms >= 600) _fireHaptics();
    // FASTER: heavyImpact ×2, the second one 120 ms later (no Timer, so the
    // widget tree never leaves a pending timer behind).
    if (_hapticsFired && !_secondPulseFired && ms >= 720) {
      _secondPulseFired = true;
      if (revealStateOf(widget.detail.summary.verdict) == RevealState.faster &&
          AppServices.of(context).settings.settings.haptics) {
        HapticFeedback.heavyImpact();
      }
    }
  }

  void _fireHaptics() {
    _hapticsFired = true;
    if (!AppServices.of(context).settings.settings.haptics) return;
    switch (revealStateOf(widget.detail.summary.verdict)) {
      case RevealState.faster:
        HapticFeedback.heavyImpact();
      case RevealState.slower:
        HapticFeedback.mediumImpact();
      case RevealState.holding:
      case RevealState.noise:
        HapticFeedback.lightImpact();
      case RevealState.baseline:
      case RevealState.none:
        break;
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    final d = widget.detail;
    final v = d.summary.verdict;
    final state = revealStateOf(v);
    final reps = repBarData(d, widget.previous, zones: services.hrZones);
    final tone = switch (state) {
      RevealState.faster => RepTone.faster,
      RevealState.slower => RepTone.slower,
      _ => RepTone.neutral,
    };
    final flagged = state == RevealState.none;
    final durationMs = d.summary.durationMs;
    return Scaffold(
      backgroundColor: t.bgBase,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Arc bloom: radial, 40 % → 0, settles at 12 % (faster only).
          if (state == RevealState.faster)
            AnimatedBuilder(
              animation: _bloom,
              builder: (context, _) {
                final p = _bloom.value;
                if (p == 0) return const SizedBox.shrink();
                return IgnorePointer(
                  child: Opacity(
                    opacity: 0.4 - 0.28 * p,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, 0.15),
                          radius: 0.2 + 1.2 * p,
                          colors: [
                            t.semImproving,
                            t.semImproving.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              children: [
                const SizedBox(height: Space.x16),
                Row(
                  children: [
                    Expanded(
                      child: ResultHeadBlock(
                        fill: runTypeColor(d.summary, t),
                        builder: (context, ink) => Text(
                          '${runHeaderTitle(d.summary)} · ${Fmt.dayDate(d.run.start)} · ${Fmt.clock(durationMs)}',
                          style: RunSoloType.label13.copyWith(
                            color: ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    if (!widget.justFinished)
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
                        iconSize: 24,
                        constraints: const BoxConstraints(
                          minWidth: 56,
                          minHeight: 56,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Space.x16),
                if (reps.isNotEmpty)
                  SectionCard(
                    child: AnimatedBuilder(
                      animation: _reveal,
                      builder: (context, _) => RepBars(
                        reps: reps,
                        units: units,
                        progress: _bars.value,
                        deltaProgress: _delta.value,
                        // No slope line; the axis never spans under 30 s, as on
                        // run detail, so a 5 s spread is not dramatic.
                        fadeProgress: 0,
                        minSpanSec: SplitsBars.minSpanSec,
                        tone: _delta.value > 0 || _reduced
                            ? tone
                            : RepTone.neutral,
                      ),
                    ),
                  ),
                const SizedBox(height: Space.x16),
                // The verdict word wipes upward inside its card.
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRect(
                        child: AnimatedBuilder(
                          animation: _word,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(0, 96 * (1 - _word.value)),
                            child: Opacity(
                              opacity: _word.value.clamp(0, 1),
                              child: child,
                            ),
                          ),
                          child: VerdictWord(
                            text: v?.headline.text ?? 'NO VERDICT',
                            state: state,
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.x12),
                      AnimatedBuilder(
                        animation: _lines,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(0, 12 * (1 - _lines.value)),
                          child: Opacity(
                            opacity: _lines.value.clamp(0, 1),
                            child: child,
                          ),
                        ),
                        child: _Lines(
                          detail: d,
                          units: units,
                          flagged: flagged,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.x16),
                // A10.3: the rank on this session's board (or its PB), in
                // the old "New best" chip's slot; the verdict is unchanged.
                BoardChips(
                  runId: d.run.id,
                  justFinished: widget.justFinished,
                  onTapBoard: (k) => openBoardDetail(context, k),
                ),
                const SizedBox(height: Space.x24),
                if (d.summary.isParkrun) ...[
                  EventPanel(
                    detail: d,
                    all: widget.all,
                    onChanged: widget.onChanged ?? () {},
                  ),
                  const SizedBox(height: Space.x24),
                ],
                if (flagged && d.analysis.lapsInconsistent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.x12),
                    child: RunButton(
                      key: const ValueKey('fix-laps'),
                      label: 'FIX LAPS',
                      onPressed: () =>
                          Navigator.of(context)
                              .pushNamed(Routes.fixLaps, arguments: d.run.id),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: RunButton.secondary(
                        label: 'DETAILS',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RunDetailScreen(runId: d.run.id),
                          ),
                        ),
                      ),
                    ),
                    if (widget.justFinished) ...[
                      const SizedBox(width: Space.x12),
                      Expanded(
                        child: RunButton(
                          label: 'DONE',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.x24),
                SectionCard(
                  child: FeelRow(runId: d.run.id, initial: d.sidecar.feel),
                ),
                const SizedBox(height: Space.x16),
                // A10.6: coaching below Details, in the scroll, so the
                // verdict hero and its goldens do not move.
                CoachingSection(runId: d.run.id),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A GOAL run's post-run screen (founder 8K field test 29-Sep): the goal's
/// own result leads - finish time for a distance goal, distance covered
/// for a time goal - then what the run gathered (pace, total, distance,
/// heat) and, on the first run of a goal, the path to the board: the
/// second run of the same goal starts the ranking. No verdict word.
class _GoalResultScreen extends StatelessWidget {
  const _GoalResultScreen({
    required this.detail,
    required this.all,
    required this.justFinished,
  });
  final RunDetail detail;
  final List<RunSummary> all;
  final bool justFinished;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final services = AppServices.of(context);
    final units = services.settings.settings.units;
    final d = detail;
    final g = d.analysis.goal;
    final name = g?.name ?? d.summary.spec?.name ?? 'Goal';

    // The big figure: the goal's own result.
    final String figure;
    final String figureLabel;
    if (g == null) {
      figure = Fmt.clock(d.summary.durationMs);
      figureLabel = 'TIME';
    } else if (!g.reached) {
      figure = Fmt.distance(g.stoppedAtM, units);
      figureLabel = 'COVERED OF ${name.toUpperCase()}';
    } else if (g.kind == engine.GoalKind.distance) {
      figure = Fmt.clock(g.goalMs!);
      figureLabel = name.toUpperCase();
    } else {
      figure = Fmt.distance(g.goalDistanceM!, units);
      figureLabel = name.toUpperCase();
    }

    // What the run gathered.
    final lines = <String>[];
    if (g != null) {
      lines.add(g.resultLine);
      if (g.interrupted) lines.add(engine.GoalResult.interruptedNote);
      double? paceSecPerKm;
      if (g.reached &&
          g.kind == engine.GoalKind.distance &&
          g.goalMs != null &&
          g.target > 0) {
        paceSecPerKm = g.goalMs! / 1000 / (g.target / 1000);
      } else if (g.reached &&
          g.kind == engine.GoalKind.time &&
          (g.goalDistanceM ?? 0) > 0) {
        paceSecPerKm = g.target / (g.goalDistanceM! / 1000);
      }
      if (paceSecPerKm != null) {
        lines.add('Average pace ${Fmt.paceUnit(paceSecPerKm, units)}.');
      }
    }
    lines.add(
      'Total ${Fmt.clock(d.summary.durationMs)} · '
      '${Fmt.distance(d.summary.distanceM, units)}.',
    );
    if (d.analysis.heatLine != null) lines.add(d.analysis.heatLine!);

    // The unlock path: the second run of the same goal opens the board.
    final key = d.summary.comparisonKey ?? d.summary.spec?.comparisonKey;
    final sameGoal = all
        .where(
          (r) =>
              key != null && (r.comparisonKey ?? r.spec?.comparisonKey) == key,
        )
        .length;
    final firstOfGoal = sameGoal <= 1;

    return Scaffold(
      backgroundColor: t.bgBase,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
          children: [
            const SizedBox(height: Space.x16),
            Row(
              children: [
                Expanded(
                  child: ResultHeadBlock(
                    fill: runTypeColor(d.summary, t),
                    builder: (context, ink) => Text(
                      'GOAL · ${name.toUpperCase()} · ${Fmt.dayDate(d.run.start)} · ${Fmt.clock(d.summary.durationMs)}',
                      style: RunSoloType.label13.copyWith(
                        color: ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                if (!justFinished)
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    iconSize: 24,
                    constraints: const BoxConstraints(
                      minWidth: 56,
                      minHeight: 56,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.x16),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      figure,
                      key: const ValueKey('goal-result-figure'),
                      softWrap: false,
                      style: RunSoloType.display96.copyWith(
                        color: t.inkPrimary,
                      ),
                    ),
                  ),
                  Text(
                    g != null && !g.reached
                        ? '$figureLabel - NOT REACHED'
                        : figureLabel,
                    style: RunSoloType.label13.copyWith(color: t.inkSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.x16),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Space.x4),
                      child: Text(
                        l,
                        style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                      ),
                    ),
                  if (firstOfGoal) ...[
                    const SizedBox(height: Space.x8),
                    Text(
                      'First $name on the books. Run it again and your $name '
                      'board opens - every run from there gets ranked against '
                      'your best.',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Space.x16),
            BoardChips(
              runId: d.run.id,
              justFinished: justFinished,
              onTapBoard: (k) => openBoardDetail(context, k),
            ),
            const SizedBox(height: Space.x24),
            Row(
              children: [
                Expanded(
                  child: RunButton.secondary(
                    label: 'DETAILS',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RunDetailScreen(runId: d.run.id),
                      ),
                    ),
                  ),
                ),
                if (justFinished) ...[
                  const SizedBox(width: Space.x12),
                  Expanded(
                    child: RunButton(
                      label: 'DONE',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: Space.x24),
            SectionCard(
              child: FeelRow(runId: d.run.id, initial: d.sidecar.feel),
            ),
            const SizedBox(height: Space.x16),
            CoachingSection(runId: d.run.id),
          ],
        ),
      ),
    );
  }
}

class VerdictWord extends StatelessWidget {
  const VerdictWord({super.key, required this.text, required this.state});
  final String text;
  final RevealState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final color = switch (state) {
      RevealState.faster => t.semImproving,
      RevealState.slower => t.semSlower,
      RevealState.none => t.inkSecondary,
      _ => t.inkPrimary,
    };
    final direction = switch (state) {
      RevealState.faster => DeltaDirection.up,
      RevealState.slower => DeltaDirection.down,
      RevealState.holding || RevealState.noise => DeltaDirection.flat,
      RevealState.baseline || RevealState.none => null,
    };
    return Semantics(
      header: true,
      label: 'Verdict: $text',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (direction != null) ...[
              DeltaGlyph(
                key: ValueKey('verdict-arrow-${direction.name}'),
                direction: direction,
                color: color,
                size: 40,
              ),
              const SizedBox(width: Space.x12),
            ],
            Text(
              text,
              key: const ValueKey('verdict-word'),
              softWrap: false,
              style: RunSoloType.display96.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lines extends StatelessWidget {
  const _Lines({
    required this.detail,
    required this.units,
    required this.flagged,
  });
  final RunDetail detail;
  final Units units;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final a = detail.analysis;
    final v = detail.summary.verdict;
    final lines = <String>[];
    if (v != null) {
      lines.add(v.subline);
      // True pace: "4:22 true pace (4:31 actual, hot day)" once, under the
      // subline, when the hills or the heat moved the pace compared.
      final truePace = v.truePaceLine(
        units == Units.mi ? engine.Units.mi : engine.Units.km,
      );
      if (truePace != null) lines.add(truePace);
      // I3: "Last time: 4 reps, 3:00 recovery." on its own line (D4).
      if (v.comparisonNote != null) lines.add(v.comparisonNote!);
      if (v.hrLine != null) lines.add(v.hrLine!);
      // Too hot for the heat model: said once after the HR line.
      if (a.heatLine != null) lines.add(a.heatLine!);
    }
    if (flagged) {
      final why = a.detection?.inconsistencyDetail;
      if (why != null) lines.add(why);
      if (a.lapEditsInvalid) {
        lines.add('Your lap edits no longer fit this run and were ignored.');
      }
    }
    if (a.noisy) lines.add('GPS was too noisy for a pace verdict.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.x4),
            child: Text(
              l,
              style: RunSoloType.body17.copyWith(color: t.inkPrimary),
            ),
          ),
      ],
    );
  }
}

/// Static 2 % noise (design brief §2.2 texture): a deterministic dot field,
/// no animation, no image asset.
class VerdictGrain extends StatelessWidget {
  const VerdictGrain({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _GrainPainter(Theme.of(context).extension<RunSoloTokens>()!.grain),
  );
}

class _GrainPainter extends CustomPainter {
  _GrainPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = colour;
    var seed = 12345;
    for (var i = 0; i < 1200; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final x = (seed % 10007) / 10007 * size.width;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final y = (seed % 10007) / 10007 * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), p);
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.colour != colour;
}

/// Laps / Free summary after Stop (plan §18.2 post-run column): no verdict
/// word. Reuses the detail body.
class _SummaryScreen extends StatelessWidget {
  const _SummaryScreen({
    required this.detail,
    required this.justFinished,
    required this.onChanged,
  });
  final RunDetail detail;
  final bool justFinished;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final title = switch (detail.summary.mode) {
      RecordMode.laps
          when detail.summary.spec?.templateId ==
              engine.SessionSpec.fartlekId =>
        'FARTLEK',
      RecordMode.laps => 'LAPS RUN',
      RecordMode.free => 'FREE RUN',
      RecordMode.trail => 'TRAIL RUN',
      RecordMode.cooper => '12-MINUTE TEST',
      RecordMode.intervals => 'INTERVALS',
    };
    final suggestTrail =
        justFinished && trailSuggested(detail.run, detail.summary.mode);
    return Scaffold(
      appBar: RunAppBar(title: title, showBack: justFinished ? false : null),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: RunDetailBody(detail: detail, showHeader: true)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                0,
              ),
              child: FeelRow(
                runId: detail.run.id,
                initial: detail.sidecar.feel,
              ),
            ),
            if (suggestTrail)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.screenGutter,
                  Space.x8,
                  Space.screenGutter,
                  0,
                ),
                child: TrailSuggestCard(
                  runId: detail.run.id,
                  onSaved: onChanged,
                ),
              ),
            // A10.3: the run's board chips above Done.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: BoardChips(
                  runId: detail.run.id,
                  justFinished: justFinished,
                  onTapBoard: (k) => openBoardDetail(context, k),
                ),
              ),
            ),
            if (justFinished)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.screenGutter,
                  Space.x12,
                  Space.screenGutter,
                  Space.x24,
                ),
                child: RunButton(
                  label: 'DONE',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              )
            else
              SizedBox(
                height: Space.x24,
                child: ColoredBox(color: t.bgBase),
              ),
          ],
        ),
      ),
    );
  }
}
