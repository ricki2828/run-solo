import '../model/run_file.dart';
import 'elevation.dart';
import 'metrics.dart';
import 'run_times.dart';
import '../weather/heat_model.dart';
import 'true_pace.dart';

/// True Pace for a whole run: moving pace x hills x heat. See [TruePace].
class RunTruePace {
  const RunTruePace({required this.rawSecPerKm, required this.factors});

  /// The actual moving pace (pauses left out), s/km.
  final double rawSecPerKm;
  final TruePaceFactors factors;

  /// The flat, cool-day pace, s/km.
  double get trueSecPerKm => factors.apply(rawSecPerKm);

  /// Under this much distance a whole-run figure is noise (the same floor
  /// as `RunElevation.minGapDistanceM`).
  static const double minDistanceM = RunElevation.minGapDistanceM;

  /// Null for a run too short (or with no moving time) to have one. [slowdown]
  /// is the run's heat slowdown fraction (null without usable weather).
  static RunTruePace? of(
    RunFile run, {
    RunElevation? elevation,
    double? slowdown,
  }) {
    final movingS = RunTimes.movingMs(run) / 1000;
    if (run.distanceM < minDistanceM || movingS <= 0) return null;
    return RunTruePace(
      rawSecPerKm: movingS / (run.distanceM / 1000),
      factors: TruePace.factors(
        gradeFactor: elevation?.gradeFactor,
        slowdown: slowdown,
      ),
    );
  }

  /// TRUE PACE live, for the Free and Trail pace group: the current pace
  /// [paceSecPerKm] on the live grade [gradePct] (percent, + uphill), with
  /// the start-of-run heat [slowdown] taken out. The heat share ramps in over
  /// the distance so far ([distanceM], `HeatModel.distanceRamp`, a display
  /// figure like the per-split heat). Null without a pace; with no grade yet
  /// (the first 50 m) only the heat applies.
  static double? live({
    required double? paceSecPerKm,
    double? gradePct,
    double? slowdown,
    double distanceM = 0,
  }) {
    if (paceSecPerKm == null) return null;
    final grade = gradePct == null ? null : 1 / Gap.ratio(gradePct / 100);
    return TruePace.factors(
      gradeFactor: grade,
      slowdown: slowdown,
      midpointM: distanceM,
      ramp: HeatModel.distanceRamp,
    ).apply(paceSecPerKm);
  }

  /// The factors for a session's work pace: the hills over the clean reps'
  /// trimmed windows (weighted by distance, the way the work pace itself
  /// is) and the run's whole-run heat.
  static TruePaceFactors forWork(
    RunElevation? elevation,
    IntervalMetrics metrics, {
    double? slowdown,
  }) {
    double? grade;
    if (elevation != null) {
      var plain = 0.0, eq = 0.0;
      for (final r in metrics.reps) {
        if (!r.clean) continue;
        final (p, e) = elevation.flatEquivalentBetweenMs(
          r.trimmedT0Ms,
          r.trimmedT1Ms,
        );
        plain += p;
        eq += e;
      }
      if (plain >= RunElevation.minGradeStretchM && eq > 0) grade = plain / eq;
    }
    return TruePace.factors(gradeFactor: grade, slowdown: slowdown);
  }
}
