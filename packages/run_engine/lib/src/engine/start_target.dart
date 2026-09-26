import '../model/session_spec.dart';
import 'event_names.dart';
import 'goal.dart';
import 'leaderboards.dart';
import 'live_plan.dart';
import 'predictor.dart';

/// Every prediction input the index holds (PD2): one run's inputs from its
/// board input and derived data, never its run file. The local date is the
/// run's start in the phone's time zone ("from your 5K on Sat 12 Sep").
List<PredictionInput> predictionInputsOf(Iterable<LiveCandidate> runs) => [
  for (final c in runs)
    ...PredictionInput.ofDerived(
      runId: c.input.runId,
      localDate: c.input.date.toLocal(),
      mode: c.input.mode,
      comparisonKey: c.input.comparisonKey,
      efforts: c.derived.bestEfforts,
      heatFraction: c.input.heatFraction,
    ),
];

/// The target a Start card shows and the live compare races (plan §3.4,
/// §G; PD2): the event's prediction or fresh course PB (switchable), or a
/// goal's target. [liveDistanceM] and [liveTargetMs] are what native gets
/// as `LiveTarget` (even splits); null for a time goal, which has a line
/// but no time-for-distance target.
class StartTarget {
  const StartTarget({
    required this.line,
    this.alternativeLine,
    this.liveDistanceM,
    this.liveTargetMs,
    this.predicted = true,
    this.alternative,
  });

  /// "Target 24:30 (predicted)", "Target 24:12 (your PB)", "Target about
  /// 1:39:17 (1:38:33 to 1:40:47), estimate", "Target 5.94 km (predicted)".
  final String line;

  /// The other choice when both a prediction and a fresh PB exist (A10.10:
  /// switchable); tap swaps to [alternative].
  final String? alternativeLine;
  final StartTarget? alternative;

  final double? liveDistanceM;
  final int? liveTargetMs;

  /// True for an estimate, false for "your PB".
  final bool predicted;

  /// The target for a Start with [spec] (the event or a goal) over the
  /// runs the index holds, or null (other sessions, no qualifying run).
  static StartTarget? forSession(
    SessionSpec? spec, {
    required Iterable<LiveCandidate> runs,
    required DateTime now,
    required EventNames names,
    String? courseKey,
  }) {
    if (spec == null) return null;
    final inputs = predictionInputsOf(runs);
    final predictor = Predictor(names: names);
    if (spec.templateId == SessionSpec.parkrunId) {
      final prediction = predictor.predict(
        PredictionTarget.parkrun,
        inputs,
        now: now,
      );
      BoardRun? pb;
      if (courseKey != null) {
        final board = Leaderboards.fold([
          for (final c in runs)
            if (c.input.comparisonKey == courseKey) c.input,
        ])[courseKey];
        pb = board?.pb;
      }
      final pbMs = pb == null ? null : (pb.metric * 1000).round();
      final chosen = ParkrunTarget.choose(
        prediction: prediction,
        coursePbMs: pbMs,
        coursePbDate: pb?.date,
        now: now,
      );
      if (chosen == null) return null;
      StartTarget of(double seconds, bool fromPb) => StartTarget(
        line: fromPb
            ? 'Target ${Prediction.clock(seconds)} (your PB)'
            : prediction!.targetLine,
        liveDistanceM: 5000,
        liveTargetMs: (seconds * 1000).round(),
        predicted: !fromPb,
      );
      final main = of(chosen.seconds, chosen.fromPb);
      // Both exist: the other one is a tap away (A10.10).
      final other = chosen.fromPb
          ? (prediction == null ? null : of(prediction.seconds, false))
          : (pbMs != null && pb != null ? of(pbMs / 1000, true) : null);
      return StartTarget(
        line: main.line,
        liveDistanceM: main.liveDistanceM,
        liveTargetMs: main.liveTargetMs,
        predicted: main.predicted,
        alternativeLine: other?.line,
        alternative: other,
      );
    }
    if (spec.isGoal) {
      final t = predictor.goalTarget(spec, inputs, now: now);
      if (t == null) return null;
      return StartTarget(
        line: t.line,
        liveDistanceM: t.kind == GoalKind.distance
            ? spec.workSteps.single.value.toDouble()
            : null,
        liveTargetMs: t.kind == GoalKind.distance
            ? (t.value * 1000).round()
            : null,
      );
    }
    return null;
  }
}

/// The Home ESTIMATED TIMES card (design A10.4; PD2): rows, the source
/// line, and the empty or stale line when there is nothing current.
class HomeEstimates {
  const HomeEstimates._({
    this.rows = const [],
    this.sourceLines = const [],
    this.message,
  });

  static const String title = 'ESTIMATED TIMES';
  static const String emptyLine =
      'Run 3 km or more to see your estimated times.';

  /// "Run 3 km or more to refresh your estimated times. The last one was 8
  /// weeks ago." No stale number is shown.
  static String staleLine(int weeks) =>
      'Run 3 km or more to refresh your estimated times. The last one was '
      '$weeks weeks ago.';

  final List<HomeEstimateRow> rows;

  /// "From your 5K on Sat 12 Sep · in cool conditions"; one line per
  /// distinct source (usually one).
  final List<String> sourceLines;

  /// The empty or stale line, instead of rows.
  final String? message;

  static HomeEstimates of(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    required EventNames names,
    bool includeEvent = false,
  }) {
    final inputs = predictionInputsOf(runs);
    final predictor = Predictor(names: names);
    final all = predictor.predictAll(
      inputs,
      now: now,
      includeParkrun: includeEvent,
    );
    if (all.isEmpty) {
      final qualifying = inputs.where(
        (i) => i.distanceM >= Predictor.minInputM,
      );
      if (qualifying.isEmpty) {
        return const HomeEstimates._(message: emptyLine);
      }
      final last = qualifying
          .map((i) => i.date)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      return HomeEstimates._(
        message: staleLine(now.difference(last).inDays ~/ 7),
      );
    }
    final order = [
      PredictionTarget.k5,
      PredictionTarget.k10,
      PredictionTarget.parkrun,
    ];
    final rows = [
      for (final t in order)
        if (all[t] case final p?) HomeEstimateRow.of(p, names),
    ];
    final sources = <String>[];
    for (final t in order) {
      final p = all[t];
      if (p == null) continue;
      final s = homeSourceLine(p);
      if (!sources.contains(s)) sources.add(s);
    }
    return HomeEstimates._(rows: rows, sourceLines: sources);
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "From your 5K on Sat 12 Sep", plus " · in cool conditions" when the
  /// input was heat-adjusted.
  static String homeSourceLine(Prediction p) {
    final d = p.source.date;
    final name = p.sourceName;
    final when = '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
    return 'From your $name on $when'
        '${p.source.heatAdjusted ? ' · in cool conditions' : ''}';
  }
}

/// One ESTIMATED TIMES row: "5K   24:30", read as "Estimated 5K 24:30",
/// with the band on tap.
class HomeEstimateRow {
  const HomeEstimateRow({
    required this.label,
    required this.time,
    required this.semantics,
    required this.band,
  });

  factory HomeEstimateRow.of(Prediction p, EventNames names) => HomeEstimateRow(
    label: p.target == PredictionTarget.parkrun
        ? 'Your ${names.parkrun}'
        : p.target.labelFor(names),
    time: Prediction.clock(p.seconds),
    semantics: p.headline,
    band: p.band,
  );

  final String label;
  final String time;

  /// "Estimated 5K 24:30".
  final String semantics;

  /// "24:10 to 24:55".
  final String band;
}
