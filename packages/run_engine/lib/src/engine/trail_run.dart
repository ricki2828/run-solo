import '../model/run_file.dart';
import '../model/verdict.dart';
import '../run_mode.dart';

/// Whether a finished Free run looks like a trail run, so the result screen
/// can offer to save it as Trail. The one place the rule lives: when the
/// barometer PR lands, [gainM] switches its source and nothing else changes.
abstract final class TrailSuggestion {
  /// Climb per kilometre at or above which a run looks like a trail run.
  static const double gainPerKmThreshold = 25;

  /// Under this distance a run is too short to judge (one bridge is not a hill).
  static const double minDistanceM = 1500;

  /// At least this share of samples must carry an altitude, or the run is
  /// not judged at all (indoor, or a phone that reported none).
  static const double minAltitudeShare = 0.6;

  /// Median filter width over the 1 Hz altitude, samples (odd).
  static const int medianWindow = 9;

  /// A climb counts only once the smoothed altitude is this far above the last
  /// reference, metres. Wobble inside the band adds nothing.
  static const double deadbandM = 4;

  /// Whether the run looks like a trail run. Free runs only: a Laps, Intervals
  /// or test run, or one already saved as Trail, is never offered.
  static bool suggests(RunFile run, {RunMode? mode}) {
    if ((mode ?? run.mode) != RunMode.free) return false;
    final perKm = gainPerKm(run);
    return perKm != null && perKm >= gainPerKmThreshold;
  }

  /// Metres climbed per kilometre, or null when the run cannot be judged.
  static double? gainPerKm(RunFile run) {
    if (run.distanceM < minDistanceM) return null;
    final gain = gainM(run);
    return gain == null ? null : gain / (run.distanceM / 1000);
  }

  /// Total climb in metres from the GPS altitude, noise filtered (median, then
  /// a deadband); null when too few samples carry an altitude. TODO(barometer):
  /// read the barometric altitude here once the recorder writes it.
  static double? gainM(RunFile run) {
    final alts = <double>[
      for (final s in run.samples)
        if (s.altM != null) s.altM!,
    ];
    if (run.samples.isEmpty ||
        alts.length < run.samples.length * minAltitudeShare) {
      return null;
    }
    final smooth = _median(alts);
    var ref = smooth.first;
    var gain = 0.0;
    for (final a in smooth) {
      if (a > ref + deadbandM) {
        gain += a - ref;
        ref = a;
      } else if (a < ref - deadbandM) {
        ref = a;
      }
    }
    return gain;
  }

  static List<double> _median(List<double> v) {
    final half = medianWindow ~/ 2;
    return [
      for (var i = 0; i < v.length; i++)
        (() {
          final w = v.sublist(
            i - half < 0 ? 0 : i - half,
            i + half + 1 > v.length ? v.length : i + half + 1,
          )..sort();
          return w[w.length ~/ 2];
        })(),
    ];
  }
}

/// Seam for the Trail result. A Trail run has no pace verdict for now (a
/// hilly pace says little); its result screen is a neutral summary.
/// TODO(TrailVerdict): the same-trail / grade-adjusted-pace verdict plugs in
/// here; until then [verdictFor] is always null and no screen invents one.
abstract final class TrailVerdict {
  static Verdict? verdictFor(RunFile run) => null;
}
