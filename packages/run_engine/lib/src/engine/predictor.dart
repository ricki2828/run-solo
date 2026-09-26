import 'dart:math' as math;

import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../run_mode.dart';
import 'analysis.dart';
import 'best_efforts.dart';
import 'event_names.dart';
import 'goal.dart';

/// Words that mark a research-derived number as an estimate (Phase 4 plan
/// §2, WARN-4). Every engine string carrying such a number contains one;
/// the string-lint test enforces it.
const List<String> estimateMarkers = [
  'estimate',
  'estimated',
  'estimates',
  'est.',
  'about',
  'research-based',
  'predicted',
];

/// Whole words only: "est." inside "best." or "fastest." is no marker.
final RegExp _estimateMarker = RegExp(
  r'(?<![a-z])(estimate[sd]?|est\.|about|research-based|predicted)(?![a-z])',
  caseSensitive: false,
);

bool carriesEstimateMarker(String s) => _estimateMarker.hasMatch(s);

/// Where a prediction input came from, for the source line.
enum PredictionSourceKind {
  bestEffort5k,
  bestEffort10k,
  parkrun,
  wholeRun,
  bestEffortHalf,
  bestEffortMarathon,
}

/// One continuous effort of 3 km or more that can seed a prediction.
class PredictionInput {
  const PredictionInput({
    required this.runId,
    required this.date,
    required this.distanceM,
    required this.elapsedMs,
    required this.kind,
    this.adjElapsedMs,
  });

  final String runId;

  /// The run's local start date (the caller's time zone).
  final DateTime date;
  final double distanceM;
  final int elapsedMs;
  final PredictionSourceKind kind;

  /// The time in cool conditions (§18.5 heat model, steady effort); null
  /// without weather or when it was too hot to compare.
  final int? adjElapsedMs;

  /// The time predictions use: heat-adjusted when available.
  int get effectiveMs => adjElapsedMs ?? elapsedMs;
  bool get heatAdjusted => adjElapsedMs != null;

  /// The inputs one run offers (plan §3.4): its 5K and 10K best efforts,
  /// and the whole run when it is a Free or Laps run of 3 km or more with
  /// no pause or gap. A parkrun offers its 5K. No other interval session,
  /// no Cooper, nothing indoor or noisy. [heatFraction] is the run's
  /// steady-effort slowdown (0.047 = 4.7%), applied as `t × (1 − adj)`.
  static List<PredictionInput> ofRun(
    RunFile run,
    RunAnalysis analysis,
    RunBestEfforts efforts, {
    required DateTime localDate,
    double? heatFraction,
  }) => analysis.indoor || analysis.noisy
      ? const []
      : ofDerived(
          runId: run.id,
          localDate: localDate,
          mode: analysis.mode,
          comparisonKey: analysis.comparisonKey,
          efforts: efforts,
          heatFraction: heatFraction,
        );

  /// The same inputs from what the index keeps per run (PD2: the Home card
  /// never decodes a run file). Indoor and noisy runs have no efforts and
  /// no whole run in the index, so they offer nothing here either.
  static List<PredictionInput> ofDerived({
    required String runId,
    required DateTime localDate,
    required RunMode mode,
    required String? comparisonKey,
    required RunBestEfforts efforts,
    double? heatFraction,
  }) {
    final parkrun =
        mode == RunMode.intervals &&
        comparisonKey != null &&
        ComparisonKey.isParkrun(comparisonKey);
    final freeOrLaps = mode == RunMode.free || mode == RunMode.laps;
    // A GOAL run (§G) offers its 5K and 10K windows like a Free run; never
    // the whole run (it carries an open cool-down after the goal).
    final goal =
        mode == RunMode.intervals &&
        comparisonKey != null &&
        ComparisonKey.isGoal(comparisonKey);
    if (!parkrun && !freeOrLaps && !goal) return const [];
    int? adj(int ms) =>
        heatFraction == null ? null : (ms * (1 - heatFraction)).round();
    PredictionInput of(double metres, int ms, PredictionSourceKind kind) =>
        PredictionInput(
          runId: runId,
          date: localDate,
          distanceM: metres,
          elapsedMs: ms,
          kind: kind,
          adjElapsedMs: adj(ms),
        );
    final k5 = efforts.efforts[BestEffortDistance.k5];
    final k10 = efforts.efforts[BestEffortDistance.k10];
    final wholeM = efforts.wholeRunM;
    final wholeMs = efforts.wholeRunMs;
    return [
      if (k5 != null)
        of(
          k5.distance.metres,
          k5.elapsedMs,
          parkrun
              ? PredictionSourceKind.parkrun
              : PredictionSourceKind.bestEffort5k,
        ),
      if (k10 != null && (freeOrLaps || goal))
        of(
          k10.distance.metres,
          k10.elapsedMs,
          PredictionSourceKind.bestEffort10k,
        ),
      for (final (d, kind) in [
        (BestEffortDistance.half, PredictionSourceKind.bestEffortHalf),
        (BestEffortDistance.marathon, PredictionSourceKind.bestEffortMarathon),
      ])
        if (efforts.efforts[d] case final e?)
          if (freeOrLaps || goal) of(d.metres, e.elapsedMs, kind),
      if (freeOrLaps &&
          wholeM != null &&
          wholeMs != null &&
          wholeM >= Predictor.minInputM)
        of(wholeM, wholeMs, PredictionSourceKind.wholeRun),
    ];
  }
}

/// A distance the Home card predicts (plan §3.4). The Saturday event and
/// 5K share one distance but are labelled apart; the event's label is the
/// injected [EventNames.parkrun], never a literal.
enum PredictionTarget {
  parkrun(null, 5000),
  k5('5K', 5000),
  k10('10K', 10000);

  const PredictionTarget(this._label, this.metres);
  final String? _label;
  final double metres;

  String labelFor(EventNames names) => _label ?? names.parkrun;
}

/// One predicted time with its exponent band and source.
class Prediction {
  const Prediction({
    required this.target,
    required this.seconds,
    required this.lowSeconds,
    required this.highSeconds,
    required this.source,
    required this.units,
    required this.names,
  });

  final PredictionTarget target;
  final EventNames names;

  /// Riegel with the headline exponent.
  final double seconds;

  /// Fastest and slowest over the exponent band.
  final double lowSeconds;
  final double highSeconds;
  final PredictionInput source;
  final Units units;

  /// "Estimated 5K 24:30".
  String get headline =>
      'Estimated ${target.labelFor(names)} ${clock(seconds)}';

  /// "24:10 to 24:55" (shown on tap).
  String get band => '${clock(lowSeconds)} to ${clock(highSeconds)}';

  /// "from your 5K on 12 Sep".
  String get sourceLine => 'from your $sourceName on ${_date()}';

  /// "Estimated 5K 24:30 (24:10 to 24:55) · from your 5K on 12 Sep". The
  /// band is left out when it rounds to one time (same distance as the
  /// input).
  String get cardLine => clock(lowSeconds) == clock(highSeconds)
      ? '$headline · $sourceLine'
      : '$headline ($band) · $sourceLine';

  /// Shown under the card when the input was heat-adjusted.
  String? get conditionsNote => source.heatAdjusted
      ? 'Estimate for a cool day, from a heat-adjusted run.'
      : null;

  /// "Target 24:30 (predicted)" on the parkrun Start card.
  String get targetLine => 'Target ${clock(seconds)} (predicted)';

  /// "5K", "10K", the event name, "half", "8.2 km run".
  String get sourceName => switch (source.kind) {
    PredictionSourceKind.bestEffort5k => '5K',
    PredictionSourceKind.bestEffort10k => '10K',
    PredictionSourceKind.bestEffortHalf => 'half',
    PredictionSourceKind.bestEffortMarathon => 'marathon',
    PredictionSourceKind.parkrun => names.parkrun,
    PredictionSourceKind.wholeRun =>
      units == Units.mi
          ? '${(source.distanceM / 1609.344).toStringAsFixed(1)} mi run'
          : '${(source.distanceM / 1000).toStringAsFixed(1)} km run',
  };

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _date() => '${source.date.day} ${_months[source.date.month - 1]}';

  /// "24:30", or "1:02:05" past the hour.
  static String clock(double seconds) {
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }
}

/// Riegel predictions from the runner's recent efforts (Phase 4 plan §3.4,
/// PD1): `T2 = T1 × (D2/D1)^1.07`.
///
/// Sources (plan §4 R6): Riegel 1981 via secondary sources (NV); Vickers &
/// Vertosick 2016 (n = 2303 recreational runners, full text) used 1.07 as
/// the average and found Riegel well calibrated up to the half marathon.
/// Riegel cited 1.08 for elite runners and 1.05–1.06 for recreational men
/// aged 40–70 (via V&V; Riegel 1981 not read). The headline is 1.07, the
/// only value validated in recreational runners (RV4 C10, main's decision),
/// with the 1.05–1.08 band. Only up to 10K (Riegel is weaker at the
/// marathon).
class Predictor {
  const Predictor({required this.names});

  /// Flavour-dependent event names for the copy.
  final EventNames names;

  static const double exponent = 1.07;
  static const double exponentLow = 1.05;
  static const double exponentHigh = 1.08;

  /// Inputs must be at least this long (plan §3.4).
  static const double minInputM = 3000;

  /// Inputs older than this are ignored.
  static const int windowDays = 42;

  /// Home card copy with no qualifying run.
  static const String emptyLine = 'Run 3 km or more to see your predictions';

  static double riegel(double t1, double d1, double d2, double e) =>
      t1 * math.pow(d2 / d1, e);

  /// The prediction for [target] from [inputs], or null with none in the
  /// last 6 weeks. The fastest predicted time wins: easy runs predict slow,
  /// so the fastest recent effort is the best signal.
  Prediction? predict(
    PredictionTarget target,
    List<PredictionInput> inputs, {
    required DateTime now,
    Units units = Units.km,
  }) {
    PredictionInput? best;
    double? bestT;
    // Whole days: a run on day 42 counts all day.
    final today = DateTime(now.year, now.month, now.day);
    // Calendar days, not 42 × 24 h, so a DST change cannot move the edge.
    final since = DateTime(today.year, today.month, today.day - windowDays);
    for (final i in inputs) {
      final day = DateTime(i.date.year, i.date.month, i.date.day);
      if (i.distanceM < minInputM || day.isBefore(since)) continue;
      if (i.date.isAfter(now)) continue;
      final t = riegel(
        i.effectiveMs / 1000,
        i.distanceM,
        target.metres,
        exponent,
      );
      if (bestT == null || t < bestT - 1e-9) {
        best = i;
        bestT = t;
      }
    }
    if (best == null) return null;
    final t1 = best.effectiveMs / 1000;
    final a = riegel(t1, best.distanceM, target.metres, exponentLow);
    final b = riegel(t1, best.distanceM, target.metres, exponentHigh);
    return Prediction(
      target: target,
      seconds: bestT!,
      lowSeconds: math.min(a, b),
      highSeconds: math.max(a, b),
      source: best,
      units: units,
      names: names,
    );
  }

  /// Every Home-card target at once (parkrun only when the runner does
  /// parkrun, which the caller decides).
  Map<PredictionTarget, Prediction> predictAll(
    List<PredictionInput> inputs, {
    required DateTime now,
    Units units = Units.km,
    bool includeParkrun = false,
  }) => {
    for (final t in PredictionTarget.values)
      if (includeParkrun || t != PredictionTarget.parkrun)
        t: ?predict(t, inputs, now: now, units: units),
  };
}

/// The parkrun Start-card target (plan §3.4): the 5 km prediction, or the
/// course PB when it is faster and under 6 weeks old. The runner can switch
/// between the two on the card.
class ParkrunTarget {
  const ParkrunTarget._(this.seconds, this.fromPb, this.line);

  final double seconds;
  final bool fromPb;

  /// "Target 24:30 (predicted)" or "Target 24:12 (your PB)".
  final String line;

  static const int pbFreshDays = 42;

  static ParkrunTarget? choose({
    Prediction? prediction,
    int? coursePbMs,
    DateTime? coursePbDate,
    required DateTime now,
  }) {
    final pbFresh =
        coursePbMs != null &&
        coursePbDate != null &&
        !DateTime(
          coursePbDate.year,
          coursePbDate.month,
          coursePbDate.day,
        ).isBefore(DateTime(now.year, now.month, now.day - pbFreshDays));
    if (pbFresh &&
        (prediction == null || coursePbMs / 1000 < prediction.seconds)) {
      final s = coursePbMs / 1000;
      return ParkrunTarget._(
        s,
        true,
        'Target ${Prediction.clock(s)} (your PB)',
      );
    }
    if (prediction == null) return null;
    return ParkrunTarget._(prediction.seconds, false, prediction.targetLine);
  }
}

/// A GOAL run's target (plan §G, founder 26-Sep): the predicted finish (a
/// distance goal) or predicted distance (a time goal), from the runner's
/// fastest recent effort. Up to 10 km it is the §3.4 prediction ("Target
/// 49:30 (predicted)"). Beyond 10 km it is a wider-band estimate ("Target
/// about 1:52 (1:48 to 1:58), estimate"), only from an effort of 10 km or
/// more in the last 6 weeks, else no target.
class GoalTarget {
  const GoalTarget({
    required this.kind,
    required this.value,
    required this.low,
    required this.high,
    required this.long,
    required this.source,
  });

  final GoalKind kind;

  /// Seconds (distance goal) or metres (time goal).
  final double value;
  final double low;
  final double high;

  /// Beyond 10 km: the wider band and "about … estimate" wording.
  final bool long;
  final PredictionInput source;

  String _num(double v) => kind == GoalKind.distance
      ? Prediction.clock(v)
      : (v / 1000).toStringAsFixed(long ? 1 : 2);

  String get _unit => kind == GoalKind.distance ? '' : ' km';

  /// "Target about 1:52:10 (1:50:40 to 1:55:30), estimate",
  /// "Target about 13.1 km (13.1 to 13.2 km), estimate",
  /// "Target 49:30 (predicted)", "Target 5.93 km (predicted)".
  String get line => long
      ? 'Target about ${_num(value)}$_unit (${_num(low)} to ${_num(high)}$_unit), estimate'
      : 'Target ${_num(value)}$_unit (predicted)';

  /// Long efforts only use inputs at least this long.
  static const double minLongInputM = 10000;

  /// Where "long" starts (§3.4 keeps Riegel to 10K).
  static const double longFromM = 10000;

  /// Exponents beyond 10 km. Vickers & Vertosick 2016 (full text, §4 R6)
  /// report no per-runner exponent spread, so the band is set from what it
  /// does report (needs verification):
  /// - up to the half marathon (21.1 km): V&V found Riegel well calibrated
  ///   only this far, so the ≤ 10K headline 1.07 and band 1.05–1.08 stand;
  /// - beyond the half marathon (the marathon, and 1 hour goals that land
  ///   past 21.1 km): with 1.07 Riegel ran ≥ 10 min too fast for half of
  ///   runners and 1.08 still too fast for about 3 in 4 (RV4 C8, C9), so
  ///   the headline is 1.10 and the band 1.07–1.13.
  static (double, double, double) exponentsFor(double metres) =>
      metres > halfMarathonM
      ? (1.10, 1.07, 1.13)
      : (Predictor.exponent, Predictor.exponentLow, Predictor.exponentHigh);

  /// Where Riegel's calibration stops (V&V 2016, §4 R6): the half
  /// marathon as the goal catalogue spells it, so the Half itself stays on
  /// the calibrated band.
  static const double halfMarathonM = 21098;
}

extension GoalTargets on Predictor {
  /// The target for [spec] (a `goal` template) from [inputs], or null.
  GoalTarget? goalTarget(
    SessionSpec spec,
    List<PredictionInput> inputs, {
    required DateTime now,
  }) {
    if (!spec.isGoal || spec.workSteps.length != 1) return null;
    final w = spec.workSteps.single;
    final today = DateTime(now.year, now.month, now.day);
    final since = DateTime(
      today.year,
      today.month,
      today.day - Predictor.windowDays,
    );
    final recent = [
      for (final i in inputs)
        if (i.distanceM >= Predictor.minInputM &&
            !DateTime(i.date.year, i.date.month, i.date.day).isBefore(since) &&
            !i.date.isAfter(now))
          i,
    ];
    if (recent.isEmpty) return null;
    if (w.target == TargetKind.distance) {
      final d2 = w.value.toDouble();
      final long = d2 > GoalTarget.longFromM;
      final pool = long
          ? recent
                .where((i) => i.distanceM >= GoalTarget.minLongInputM)
                .toList()
          : recent;
      if (pool.isEmpty) return null;
      final (e, lo, hi) = GoalTarget.exponentsFor(d2);
      PredictionInput? best;
      double? bestT;
      for (final i in pool) {
        final t = Predictor.riegel(i.effectiveMs / 1000, i.distanceM, d2, e);
        if (bestT == null || t < bestT - 1e-9) {
          best = i;
          bestT = t;
        }
      }
      final t1 = best!.effectiveMs / 1000;
      final a = Predictor.riegel(t1, best.distanceM, d2, lo);
      final b = Predictor.riegel(t1, best.distanceM, d2, hi);
      return GoalTarget(
        kind: GoalKind.distance,
        value: bestT!,
        low: math.min(a, b),
        high: math.max(a, b),
        long: long,
        source: best,
      );
    }
    // Time goal: invert Riegel, D2 = D1 × (T2/T1)^(1/e); the farthest wins.
    final t2 = w.value.toDouble();
    double dist(PredictionInput i, double e) =>
        i.distanceM * math.pow(t2 / (i.effectiveMs / 1000), 1 / e);
    PredictionInput? best;
    double? bestD;
    for (final i in recent) {
      final d = dist(i, Predictor.exponent);
      if (bestD == null || d > bestD + 1e-9) {
        best = i;
        bestD = d;
      }
    }
    var long = bestD! > GoalTarget.longFromM;
    if (long) {
      final pool = recent.where((i) => i.distanceM >= GoalTarget.minLongInputM);
      if (pool.isEmpty) return null;
      best = null;
      bestD = null;
      final (e, _, _) = GoalTarget.exponentsFor(20000);
      for (final i in pool) {
        final d = dist(i, e);
        if (bestD == null || d > bestD + 1e-9) {
          best = i;
          bestD = d;
        }
      }
      long = true;
    }
    final (_, lo, hi) = GoalTarget.exponentsFor(bestD!);
    final a = dist(best!, lo);
    final b = dist(best, hi);
    return GoalTarget(
      kind: GoalKind.time,
      value: bestD,
      low: math.min(a, b),
      high: math.max(a, b),
      long: long,
      source: best,
    );
  }
}
