import 'package:flutter/material.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../app/services.dart';
import '../platform/gateway.dart' show Units;
import '../theme/lanes.dart';
import '../theme/theme.dart';

/// One past run in the Counted runs list: whether its 5K/10K window fed MID
/// and ESTIMATED TIMES, or the plain-words reason it did not. Everything is
/// read off the run's derived data ([engine.RunDerived]) and the engine's own
/// miss reasons ([engine.EffortNote.forRun]); nothing is recomputed here.
class CountedRun {
  const CountedRun({
    required this.runId,
    required this.date,
    required this.type,
    required this.distanceM,
    required this.windows,
    required this.reason,
    required this.notes,
  });

  final String runId;
  final DateTime date;

  /// "Free run", "Trail run", "Goal run"...
  final String type;
  final double distanceM;

  /// The 5K and/or 10K windows that counted, shortest first; empty when the
  /// run did not count.
  final List<CountedWindow> windows;

  /// Why it did not count; null when it did.
  final String? reason;

  /// "GPS gap bridged (45 s)", "Pause bridged (30 s)".
  final List<String> notes;

  bool get counted => windows.isNotEmpty;

  /// The run's own 5K window (or 10K without one): what "best" compares.
  CountedWindow? get headline => windows.isEmpty ? null : windows.first;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "20 Oct 2026": the year is there because the list can reach back a year.
  String get dateLabel => '${date.day} ${_months[date.month - 1]} ${date.year}';

  /// The list for [candidates], newest first.
  static List<CountedRun> all(
    Iterable<engine.LiveCandidate> candidates, {
    engine.Units units = engine.Units.km,
  }) {
    final out = [for (final c in candidates) _of(c, units)];
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  static CountedRun _of(engine.LiveCandidate c, engine.Units units) {
    final i = c.input;
    final efforts = c.derived.bestEfforts.efforts;
    final trailOk = i.mode != engine.RunMode.trail || i.trailMovingMs != null;
    final usable = i.mode != engine.RunMode.cooper && trailOk;
    final windows = <CountedWindow>[];
    if (usable) {
      for (final d in [
        engine.BestEffortDistance.k5,
        engine.BestEffortDistance.k10,
      ]) {
        final e = efforts[d];
        if (e == null) continue;
        final hills = i.mode == engine.RunMode.trail && e.gradeFactor != 1;
        windows.add(
          CountedWindow(
            label: d == engine.BestEffortDistance.k5 ? '5K' : '10K',
            elapsedMs: hills
                ? i
                      .factorsFor(e.gradeFactor)
                      .applyForScore(e.elapsedMs + 0.0)
                      .round()
                : e.elapsedMs,
            hillsAdjusted: hills,
          ),
        );
      }
    }
    final notes = <String>[
      for (final w
          in windows.isEmpty
              ? const <engine.BestEffort>[]
              : [
                  for (final d in [
                    engine.BestEffortDistance.k5,
                    engine.BestEffortDistance.k10,
                  ])
                    ?efforts[d],
                ]) ...[
        if (w.gpsGapMs > 0) 'GPS gap bridged (${_span(w.gpsGapMs)})',
        if (w.pausedMs > 0) 'Pause bridged (${_span(w.pausedMs)})',
      ],
    ];
    final date = engine.RunIdentity.localStart(i.date, i.utcOffsetMin);
    return CountedRun(
      runId: i.runId,
      date: date,
      type: _type(i),
      distanceM: i.runDistanceM,
      windows: windows,
      reason: windows.isNotEmpty ? null : _reason(c, units),
      notes: notes.toSet().toList(),
    );
  }

  static String _span(int ms) {
    final s = (ms / 1000).round();
    return s < 120 ? '$s s' : '${(s / 60).round()} min';
  }

  static String _type(engine.BoardInput i) => switch (i.mode) {
    engine.RunMode.free => 'Free run',
    engine.RunMode.laps => 'Laps run',
    engine.RunMode.cooper => 'Cooper test',
    engine.RunMode.trail => 'Trail run',
    engine.RunMode.intervals =>
      engine.ComparisonKey.isGoal(i.comparisonKey ?? '')
          ? 'Goal run'
          : 'Intervals',
  };

  static String _reason(engine.LiveCandidate c, engine.Units units) {
    final i = c.input;
    if (i.mode != engine.RunMode.cooper &&
        i.runDistanceM < engine.EffortNote.minRunM) {
      return units == engine.Units.mi ? 'Under 3.1 mi' : 'Under 5 km';
    }
    final note = engine.EffortNote.forRun(c, units: units);
    if (note != null) {
      final r = note.reason;
      return r[0].toUpperCase() + r.substring(1);
    }
    if (i.mode == engine.RunMode.intervals &&
        !engine.ComparisonKey.isGoal(i.comparisonKey ?? '')) {
      return 'Interval session, judged by its reps';
    }
    return 'No clean 5K stretch in the trace';
  }
}

class CountedWindow {
  const CountedWindow({
    required this.label,
    required this.elapsedMs,
    required this.hillsAdjusted,
  });

  final String label;
  final int elapsedMs;
  final bool hillsAdjusted;
}

/// Counted runs: every past run, newest first, with what it contributed to
/// MID and ESTIMATED TIMES, or why it did not count. Reached from the MID
/// analysis on Progress.
class CountedRunsScreen extends StatefulWidget {
  const CountedRunsScreen({super.key, this.candidates, this.units});

  /// Tests pass a fixture; production reads the live source's prepared runs.
  final List<engine.LiveCandidate>? candidates;
  final Units? units;

  @override
  State<CountedRunsScreen> createState() => _CountedRunsScreenState();
}

class _CountedRunsScreenState extends State<CountedRunsScreen> {
  Future<List<engine.LiveCandidate>>? _runs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runs ??= _load();
  }

  Future<List<engine.LiveCandidate>> _load() async {
    final fixed = widget.candidates;
    if (fixed != null) return fixed;
    final live = AppServices.of(context).live;
    if (live == null) return const [];
    await live.prepare();
    return live.preparedCandidates;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final units =
        widget.units ?? AppServices.of(context).settings.settings.units;
    final eu = units == Units.mi ? engine.Units.mi : engine.Units.km;
    return Material(
      color: t.bgBase,
      child: SafeArea(
        child: FutureBuilder<List<engine.LiveCandidate>>(
          future: _runs,
          builder: (context, snap) {
            final rows = CountedRun.all(snap.data ?? const [], units: eu);
            final n = rows.where((r) => r.counted).length;
            CountedWindow? best5;
            for (final r in rows) {
              for (final w in r.windows) {
                if (w.label == '5K' &&
                    (best5 == null || w.elapsedMs < best5.elapsedMs)) {
                  best5 = w;
                }
              }
            }
            return ListView(
              key: const ValueKey('counted-runs'),
              padding: const EdgeInsets.fromLTRB(
                Space.screenGutter,
                Space.x8,
                Space.screenGutter,
                Space.x32,
              ),
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.arrow_back, color: t.inkPrimary),
                    ),
                    Text(
                      'COUNTED RUNS',
                      style: RunSoloType.heading26.copyWith(
                        color: t.inkPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.x8),
                Text(
                  '$n of ${rows.length} runs count toward MID',
                  key: const ValueKey('counted-header'),
                  style: RunSoloType.title28.copyWith(
                    color: t.laneText(engine.IdentityLane.mid),
                  ),
                ),
                const SizedBox(height: Space.x4),
                Text(
                  'The same runs feed Estimated Times.',
                  style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                ),
                const SizedBox(height: Space.x16),
                for (final r in rows) ...[
                  _Tile(
                    run: r,
                    units: units,
                    isBest:
                        best5 != null &&
                        r.windows.any(
                          (w) =>
                              w.label == '5K' &&
                              w.elapsedMs == best5!.elapsedMs,
                        ),
                  ),
                  Divider(
                    height: Space.x24,
                    color: t.inkSecondary.withAlpha(60),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.run, required this.units, required this.isBest});

  final CountedRun run;
  final Units units;
  final bool isBest;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<RunSoloTokens>()!;
    final counted = run.counted;
    return Semantics(
      container: true,
      label:
          '${run.dateLabel}, ${run.type}, ${Fmt.distance1(run.distanceM, units)}. '
          '${counted ? 'Counted' : "Didn't count: ${run.reason}"}',
      excludeSemantics: true,
      child: Column(
        key: ValueKey('counted-${run.runId}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.dateLabel,
                      style: RunSoloType.body17.copyWith(color: t.inkPrimary),
                    ),
                    Text(
                      '${run.type}  ${Fmt.distance1(run.distanceM, units)}',
                      style: RunSoloType.body15.copyWith(color: t.inkSecondary),
                    ),
                  ],
                ),
              ),
              if (counted)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final w in run.windows)
                      Text(
                        '${w.label}  ${Fmt.clock(w.elapsedMs)}',
                        key: ValueKey('counted-${run.runId}-${w.label}'),
                        style: RunSoloType.heading26.copyWith(
                          color: isBest && w == run.headline
                              ? t.accentArc
                              : t.inkPrimary,
                          fontFeatures: RunSoloType.tabular,
                        ),
                      ),
                    if (run.windows.any((w) => w.hillsAdjusted))
                      Text(
                        'hills-adjusted',
                        style: RunSoloType.label13.copyWith(
                          color: t.inkSecondary,
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Space.x4),
          Text(
            counted ? 'Counts for MID and Estimated Times' : run.reason!,
            key: ValueKey('counted-${run.runId}-status'),
            style: RunSoloType.body15.copyWith(
              color: counted
                  ? t.laneText(engine.IdentityLane.mid)
                  : t.inkPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final n in run.notes)
            Text(n, style: RunSoloType.label13.copyWith(color: t.inkSecondary)),
        ],
      ),
    );
  }
}
