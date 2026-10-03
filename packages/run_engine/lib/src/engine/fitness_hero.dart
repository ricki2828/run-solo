import 'dart:math' as math;

import '../model/session_spec.dart';
import 'run_identity.dart';
import 'event_names.dart';
import 'live_plan.dart';
import 'predictor.dart';
import 'start_target.dart';

/// The Home fitness hero (product call 27-Sep: "VO2 max as the hero,
/// Cooper should be the gold standard for how we measure it but should be
/// updated by other run types").
///
/// Observations feed in from two sources:
/// - every valid Cooper test, at its prime figure (the heat-adjusted
///   estimate when it exists, the raw one otherwise);
/// - every prediction input a run offers (5K / 10K / parkrun best efforts,
///   whole Free or Laps runs of 3 km or more, heat-adjusted time when
///   available), converted with the Daniels-Gilbert VDOT formula.
///
/// The headline is the best observation in the trailing [windowDays]: a
/// Cooper test sets it when the test is the best evidence, a strong run
/// raises it between tests, and without a new best the figure steps down
/// when the old one leaves the window. The delta compares today's reading
/// with the same rule applied six weeks ago.
class FitnessHero {
  const FitnessHero._({
    required this.vo2,
    required this.asOf,
    required this.sourceLabel,
    required this.runId,
    this.deltaVs6wks,
    this.spark = const [],
  });

  /// The headline estimate, ml/kg/min, one decimal when shown.
  final double vo2;

  /// The date of the observation that set the headline.
  final DateTime asOf;

  /// What set it: "Cooper test", "5K", "10K", "parkrun", "run", "21K",
  /// "marathon" or "trail run" (counted at its true pace).
  final String sourceLabel;

  /// The run behind this reading; the Home score opens that run.
  final String runId;

  /// Headline minus the same reading six weeks ago; null when either side
  /// has no observation.
  final double? deltaVs6wks;

  /// Every observation in the trailing twelve weeks, oldest first - the
  /// hero sparkline.
  final List<double> spark;

  /// The headline window: the best observation in this many trailing days
  /// is the current reading.
  static const int windowDays = 42;

  /// The reading, or null when no observation sits in the window (the app
  /// shows the baseline prompt).
  static FitnessHero? of(
    Iterable<LiveCandidate> runs, {
    required DateTime now,
    EventNames names = EventNames.generic,
  }) {
    final obs = _observations(runs, names);
    if (obs.isEmpty) return null;
    final hero = _best(
      obs,
      now.subtract(const Duration(days: windowDays)),
      now,
    );
    if (hero == null) return null;
    final prior = _best(
      obs,
      now.subtract(const Duration(days: windowDays * 2)),
      now.subtract(const Duration(days: windowDays)),
    );
    return FitnessHero._(
      vo2: hero.vo2,
      asOf: hero.date,
      sourceLabel: hero.label,
      runId: hero.runId,
      deltaVs6wks: prior == null ? null : hero.vo2 - prior.vo2,
      spark: [
        for (final o in obs)
          if (o.date.isAfter(
            now.subtract(const Duration(days: windowDays * 2)),
          ))
            o.vo2,
      ],
    );
  }

  static _Obs? _best(List<_Obs> obs, DateTime from, DateTime to) {
    _Obs? best;
    for (final o in obs) {
      if (o.date.isBefore(from) || !o.date.isBefore(to)) continue;
      if (best == null || o.vo2 > best.vo2) best = o;
    }
    return best;
  }

  static List<_Obs> _observations(
    Iterable<LiveCandidate> runs,
    EventNames names,
  ) {
    final out = <_Obs>[];
    for (final c in runs) {
      final raw = c.input.cooperVo2;
      if (c.input.comparisonKey == ComparisonKey.cooper && raw != null) {
        out.add(
          _Obs(
            RunIdentity.localStart(c.input.date, c.input.utcOffsetMin),
            c.input.cooperVo2Adj ?? raw,
            'Cooper test',
            c.input.runId,
          ),
        );
      }
    }
    for (final c in runs) {
      // A qualifying Trail run counts at its true pace (see TrailScore).
      final d = c.input.trailDistanceM, ms = c.input.trailMovingMs;
      if (d != null && ms != null) {
        out.add(
          _Obs(
            RunIdentity.localStart(c.input.date, c.input.utcOffsetMin),
            vdot(d, c.input.factorsFor().apply(ms.toDouble()).round()),
            'trail run',
            c.input.runId,
          ),
        );
      }
    }
    for (final i in predictionInputsOf(runs)) {
      out.add(
        _Obs(
          i.date,
          vdot(i.distanceM, i.effectiveMs),
          _label(i.kind, names),
          i.runId,
        ),
      );
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  static String _label(PredictionSourceKind kind, EventNames names) =>
      switch (kind) {
        PredictionSourceKind.bestEffort5k => '5K',
        PredictionSourceKind.bestEffort10k => '10K',
        PredictionSourceKind.parkrun => names.parkrun,
        PredictionSourceKind.wholeRun => 'run',
        PredictionSourceKind.bestEffortHalf => '21K',
        PredictionSourceKind.bestEffortMarathon => 'marathon',
      };

  /// Daniels-Gilbert VDOT for an even effort: the velocity in m/min and
  /// duration in minutes give the oxygen cost over the fraction of VO2max
  /// a runner sustains for that duration.
  static double vdot(double distanceM, int elapsedMs) {
    final t = elapsedMs / 60000.0;
    final v = distanceM / t;
    final cost = -4.60 + 0.182258 * v + 0.000104 * v * v;
    final fraction =
        0.8 +
        0.1894393 * math.exp(-0.012778 * t) +
        0.2989558 * math.exp(-0.1932605 * t);
    return cost / fraction;
  }
}

class _Obs {
  const _Obs(this.date, this.vo2, this.label, this.runId);
  final DateTime date;
  final double vo2;
  final String label;
  final String runId;
}
