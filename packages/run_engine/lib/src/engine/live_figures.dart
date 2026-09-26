import '../model/run_file.dart';
import '../run_mode.dart';
import 'analysis.dart';
import 'best_efforts.dart';
import 'cooper_projection.dart';
import 'trace.dart';

/// A nudge the recorder spoke, from the journal's `cue_fired` lines (plan
/// §3.5, WARN-5): the engine blocks the same rule at the same km or rep on
/// the next run. Empty until LV1 journals them.
class FiredNudge {
  const FiredNudge(this.rule, this.index);

  final String rule;

  /// The km (distance runs) or rep (intervals) it fired at.
  final int index;

  List<Object> toJson() => [rule, index];

  static FiredNudge fromJson(Object? j) {
    final l = j! as List;
    return FiredNudge(l[0] as String, l[1] as int);
  }
}

/// Per-run figures live compare races against (plan §3.1, BLOCK-2): stored
/// in the index next to the board data, used only live, never by boards or
/// verdicts.
class LiveFigures {
  const LiveFigures({
    this.repPacesSecPerKm = const [],
    this.cooperMinuteM = const [],
    this.kmHr = const [],
  });

  static const LiveFigures none = LiveFigures();

  /// Per work rep, in order: **untrimmed** lap distance ÷ lap moving time,
  /// s/km, the way native computes a rep live, not I3's trimmed headline.
  /// Lap edges are placed by interpolating the distance stream at the lap's
  /// time (never the stored lap distance, which runs before LV0 wrote one
  /// sample late; P2-a). A rep I3 marks unclean is null; live compare drops
  /// a prior with a null among reps 1..r.
  final List<double?> repPacesSecPerKm;

  /// Cooper: cumulative distance at each whole minute 1..12 of the test,
  /// from [CooperProjection.minuteDistances] (the one implementation the
  /// personal fade curve also uses). Always 12 values or empty: a paused,
  /// short or unusable test gives none (LC1 requires 12 points).
  final List<double> cooperMinuteM;

  /// Mean HR over each whole km from the Start press, aligned with
  /// [RunBestEfforts.fromStartSplitsMs] (same length; null for a km with no
  /// HR). Empty without from-start splits. For the HR-drift nudge (CR1).
  final List<double?> kmHr;

  static LiveFigures of(
    RunFile run,
    RunAnalysis a, {
    List<int> fromStartSplitsMs = const [],
  }) {
    if (a.indoor || a.noisy) return none;
    final trace = Trace(run.samples);
    return LiveFigures(
      repPacesSecPerKm: a.mode == RunMode.intervals && a.intervals != null
          ? [
              for (final r in a.intervals!.reps)
                r.clean ? _lapPace(run, trace, r.lap.t0Ms, r.lap.t1Ms) : null,
            ]
          : const [],
      cooperMinuteM: a.mode == RunMode.cooper
          ? CooperProjection.minuteDistances(run) ?? const []
          : const [],
      kmHr: run.hasHr
          ? [
              for (var k = 0; k < fromStartSplitsMs.length; k++)
                _kmHr(
                  trace,
                  k == 0 ? 0 : fromStartSplitsMs[k - 1],
                  fromStartSplitsMs[k],
                ),
            ]
          : const [],
    );
  }

  /// Mean HR over one km, the rule native mirrors live (CR1, shared with
  /// rs-native-opus): the plain mean of the 1 Hz samples with `t` in
  /// `[aMs, bMs)` that carry HR, null when fewer than half of the samples
  /// in the km carry HR (a strap dropout says nothing about drift).
  static double? _kmHr(Trace trace, int aMs, int bMs) {
    var n = 0;
    var withHr = 0;
    var sum = 0.0;
    for (final s in trace.between(aMs, bMs)) {
      n++;
      if (s.hr == null) continue;
      withHr++;
      sum += s.hr!;
    }
    if (n == 0 || withHr * 2 < n) return null;
    return sum / withHr;
  }

  static double? _lapPace(RunFile run, Trace trace, int t0, int t1) {
    final metres = trace.distAt(t1) - trace.distAt(t0);
    var paused = 0;
    for (final p in run.pauses) {
      final lo = p.t0Ms > t0 ? p.t0Ms : t0;
      final hi = p.t1Ms < t1 ? p.t1Ms : t1;
      if (hi > lo) paused += hi - lo;
    }
    final seconds = (t1 - t0 - paused) / 1000;
    if (metres <= 0 || seconds <= 0) return null;
    return seconds / metres * 1000;
  }

  Map<String, Object?> toJson() => {
    'rep_paces_s_per_km': [
      for (final p in repPacesSecPerKm)
        p == null ? null : double.parse(p.toStringAsFixed(2)),
    ],
    'cooper_minute_m': [
      for (final m in cooperMinuteM) double.parse(m.toStringAsFixed(1)),
    ],
    'km_hr': [
      for (final h in kmHr)
        h == null ? null : double.parse(h.toStringAsFixed(1)),
    ],
  };

  factory LiveFigures.fromJson(Map<String, Object?> j) => LiveFigures(
    repPacesSecPerKm: [
      for (final p in (j['rep_paces_s_per_km'] as List? ?? const []))
        (p as num?)?.toDouble(),
    ],
    cooperMinuteM: [
      for (final m in (j['cooper_minute_m'] as List? ?? const []))
        (m as num).toDouble(),
    ],
    kmHr: [
      for (final h in (j['km_hr'] as List? ?? const []))
        (h as num?)?.toDouble(),
    ],
  );
}

/// Everything Phase 4 derives per run for the index (plan §3.1 data model):
/// best efforts and from-start splits, live figures and the nudges the run
/// fired. Rebuilt with the entry; an `engineVersion` bump rebuilds it.
class RunDerived {
  const RunDerived({
    required this.bestEfforts,
    this.live = LiveFigures.none,
    this.nudgesFired = const [],
  });

  final RunBestEfforts bestEfforts;
  final LiveFigures live;
  final List<FiredNudge> nudgesFired;

  static RunDerived of(
    RunFile run,
    RunAnalysis a, {
    List<FiredNudge> nudgesFired = const [],
    BestEffortFinder finder = const BestEffortFinder(),
  }) {
    final efforts = finder.find(run, a);
    return RunDerived(
      bestEfforts: efforts,
      live: LiveFigures.of(
        run,
        a,
        fromStartSplitsMs: efforts.fromStartSplitsMs,
      ),
      nudgesFired: nudgesFired,
    );
  }

  Map<String, Object?> toJson() => {
    'best_efforts': bestEfforts.toJson(),
    'live': live.toJson(),
    'nudges_fired': [for (final n in nudgesFired) n.toJson()],
  };

  factory RunDerived.fromJson(Map<String, Object?> j) => RunDerived(
    bestEfforts: RunBestEfforts.fromJson(
      j['best_efforts']! as Map<String, Object?>,
    ),
    live: LiveFigures.fromJson(
      (j['live'] as Map<String, Object?>?) ?? const {},
    ),
    nudgesFired: [
      for (final n in (j['nudges_fired'] as List? ?? const []))
        FiredNudge.fromJson(n),
    ],
  );
}
