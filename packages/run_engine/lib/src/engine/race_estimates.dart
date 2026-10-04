import '../model/run_file.dart';
import 'event_names.dart';
import 'fitness_hero.dart';
import 'predictor.dart';
import 'start_target.dart';
import 'live_plan.dart';

/// One distance on the Progress race-times table: a time and range, or the
/// reason there is none.
class RaceEstimateRow {
  const RaceEstimateRow._({
    required this.label,
    required this.metres,
    this.time,
    this.range,
    this.source,
    this.whyNot,
    this.seconds,
  });

  final String label;
  final double metres;

  /// "24:30" or "1:52:10"; null when there is no estimate.
  final String? time;

  /// "24:10 to 24:55".
  final String? range;

  /// "From your 5K on 12 Sep", plus " · flat, cool day" when the run was
  /// taken to True Pace.
  final String? source;

  /// Why there is no time: "Needs a run of 10 km or more in the last 6 weeks."
  final String? whyNot;
  final double? seconds;

  bool get hasTime => time != null;

  /// "Estimated 5K 24:30 (24:10 to 24:55)" for a screen reader.
  String get semantics => hasTime
      ? 'Estimated $label $time${range == null ? '' : ' ($range)'}'
      : '$label: $whyNot';
}

/// Race times (5K, 10K, half, marathon) and the VO2 reading, on True Pace
/// (hills and heat out: a flat, cool day), from the runner's best recent run.
///
/// 5K and 10K are the Home card's prediction. The half and marathon need a
/// run of at least [longInputM] in the last 6 weeks and use the wider-band
/// exponents the Goal target uses beyond 10 km ([GoalTarget.exponentsFor]),
/// so the three screens never disagree. VO2 is the fitness hero's.
class RaceEstimates {
  const RaceEstimates._({required this.rows, this.vo2});

  final List<RaceEstimateRow> rows;
  final FitnessHero? vo2;

  /// Half and marathon only count a run this long.
  static const double longInputM = GoalTarget.minLongInputM;

  static const String shortWhyNot =
      'Needs a run of 3 km or more in the last 6 weeks.';
  static const String longWhyNot =
      'Needs a run of 10 km or more in the last 6 weeks.';

  /// The method, shown in the detail view only (research-based wording).
  static const List<String> method = [
    'Times come from your best run in the last 6 weeks (3 km or more), '
        'taken to true pace: hills and heat out, so they are for a flat, cool '
        'day. The Riegel formula stretches that run to each distance, and the '
        'range covers how differently runners fade.',
    'Half and marathon need a run of 10 km or more in that window. The '
        'marathon is the least reliable: most people fade more than the '
        'formula allows.',
    'VO2 max is an estimate from the same runs with the Daniels-Gilbert '
        'formula, and a 12-minute test counts when it is your best. A lab or '
        'a watch will give different numbers. Research-based, not a promise.',
  ];

  static const double _halfM = 21097.5;
  static const double _marathonM = 42195;

  static RaceEstimates of(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    EventNames names = EventNames.generic,
  }) {
    final inputs = predictionInputsOf(runs);
    final predictor = Predictor(names: names);
    final since = DateTime(now.year, now.month, now.day - Predictor.windowDays);
    final recent = [
      for (final i in inputs)
        if (i.distanceM >= Predictor.minInputM &&
            !DateTime(i.date.year, i.date.month, i.date.day).isBefore(since) &&
            !i.date.isAfter(now))
          i,
    ];
    RaceEstimateRow short(PredictionTarget t, String label) {
      final p = predictor.predict(t, inputs, now: now);
      if (p == null) {
        return RaceEstimateRow._(
          label: label,
          metres: t.metres,
          whyNot: shortWhyNot,
        );
      }
      final one =
          Prediction.clock(p.lowSeconds) == Prediction.clock(p.highSeconds);
      return RaceEstimateRow._(
        label: label,
        metres: t.metres,
        seconds: p.seconds,
        time: Prediction.clock(p.seconds),
        range: one ? null : p.band,
        source: HomeEstimates.homeSourceLine(p),
      );
    }

    RaceEstimateRow long(String label, double metres) {
      final pool = [
        for (final i in recent)
          if (i.distanceM >= longInputM) i,
      ];
      if (pool.isEmpty) {
        return RaceEstimateRow._(
          label: label,
          metres: metres,
          whyNot: recent.isEmpty ? shortWhyNot : longWhyNot,
        );
      }
      final (e, lo, hi) = GoalTarget.exponentsFor(metres);
      PredictionInput? best;
      double? bestT;
      for (final i in pool) {
        final t = Predictor.riegel(
          i.effectiveMs / 1000,
          i.distanceM,
          metres,
          e,
        );
        if (bestT == null || t < bestT - 1e-9) {
          best = i;
          bestT = t;
        }
      }
      final t1 = best!.effectiveMs / 1000;
      final a = Predictor.riegel(t1, best.distanceM, metres, lo);
      final b = Predictor.riegel(t1, best.distanceM, metres, hi);
      final low = a < b ? a : b, high = a < b ? b : a;
      final p = Prediction(
        target: PredictionTarget.k10,
        seconds: bestT!,
        lowSeconds: low,
        highSeconds: high,
        source: best,
        units: Units.km,
        names: names,
      );
      return RaceEstimateRow._(
        label: label,
        metres: metres,
        seconds: bestT,
        time: Prediction.clock(bestT),
        range: '${Prediction.clock(low)} to ${Prediction.clock(high)}',
        source: HomeEstimates.homeSourceLine(p),
      );
    }

    return RaceEstimates._(
      rows: [
        short(PredictionTarget.k5, '5K'),
        short(PredictionTarget.k10, '10K'),
        long('Half', _halfM),
        long('Marathon', _marathonM),
      ],
      vo2: FitnessHero.of(runs, now: now, names: names),
    );
  }

  /// Nothing to show at all: no run to estimate from and no VO2.
  bool get isEmpty => vo2 == null && rows.every((r) => !r.hasTime);

  RaceEstimateRow row(String label) => rows.firstWhere((r) => r.label == label);

  /// "VO2 max 47.3", with how it was set.
  String? get vo2Text =>
      vo2 == null ? null : 'VO2 max ${vo2!.vo2.toStringAsFixed(1)}';

  /// The Home line: only what the Home table does not already show (the
  /// half and marathon when there is a long enough run, and VO2), or null
  /// with none of them.
  String? get homeLine {
    final parts = [
      for (final r in rows)
        if (r.hasTime && (r.label == 'Half' || r.label == 'Marathon'))
          '${r.label} ${r.time}',
      ?(vo2 == null ? null : 'VO2 ${vo2!.vo2.round()}'),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
