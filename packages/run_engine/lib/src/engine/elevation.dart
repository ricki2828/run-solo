import 'dart:math' as math;

import '../model/run_file.dart';
import 'run_times.dart';

/// Elevation analysis over a run file's fused elevation (`Sample.elevM`):
/// total climb and descent with a dead band, the profile against distance,
/// climb per lap and per unit, grade, and grade-adjusted pace (GAP).
///
/// The recorder fuses the barometer and GPS on the phone (Kotlin
/// `ElevationFuser`); this reads what it wrote. [ClimbTracker] and
/// [GradeWindow] are the same rules as their Kotlin twins, so the live
/// total on the run screen and the finished one agree.

/// Total ascent and descent with a dead band, so sensor noise is not counted
/// as hills. A turning point (the top of a hill, the bottom of a dip) is only
/// believed once the elevation has come back [thresholdM] from it; a move
/// from the last turning point only starts counting once it is [thresholdM]
/// long. After that every metre further along the same direction counts at
/// once, so a hill is booked right up to its top. A flat run wobbling by less
/// than the threshold books nothing. Same rule as the Kotlin `ClimbTracker`.
class ClimbTracker {
  ClimbTracker(this.thresholdM);

  final double thresholdM;

  /// Barometer: about 3 m, a little over the sensor's noise.
  static const double baroThresholdM = 3;

  /// GPS altitude alone is far noisier.
  static const double gpsThresholdM = 10;

  static double thresholdFor(ElevSource src) =>
      src == ElevSource.baro ? baroThresholdM : gpsThresholdM;

  double? _ref;
  double _ext = 0;
  int _dir = 0;
  double ascentM = 0;
  double descentM = 0;

  /// Feeds one elevation; returns what it added to the totals (+ climb,
  /// - descent, 0 for nothing). One offer adds to one side only.
  double offer(double elevM) {
    final r = _ref;
    if (r == null) {
      _ref = elevM;
      _ext = elevM;
      return 0;
    }
    switch (_dir) {
      case 0:
        if (elevM - r >= thresholdM) {
          ascentM += elevM - r;
          _dir = 1;
          _ext = elevM;
          return elevM - r;
        }
        if (r - elevM >= thresholdM) {
          descentM += r - elevM;
          _dir = -1;
          _ext = elevM;
          return elevM - r;
        }
      case 1:
        if (elevM > _ext) {
          final d = elevM - _ext;
          ascentM += d;
          _ext = elevM;
          return d;
        }
        if (_ext - elevM >= thresholdM) {
          final d = _ext - elevM;
          descentM += d;
          _dir = -1;
          _ref = _ext;
          _ext = elevM;
          return -d;
        }
      default:
        if (elevM < _ext) {
          final d = _ext - elevM;
          descentM += d;
          _ext = elevM;
          return -d;
        }
        if (elevM - _ext >= thresholdM) {
          final d = elevM - _ext;
          ascentM += d;
          _dir = 1;
          _ref = _ext;
          _ext = elevM;
          return d;
        }
    }
    return 0;
  }

  /// Follows [elevM] without booking it (paused: the walk to the cafe is
  /// not part of the run).
  void hold(double elevM) {
    _ref = elevM;
    _ext = elevM;
    _dir = 0;
  }
}

/// Grade (rise over run, 0.05 = 5%) over the last [windowM] metres of
/// distance: the elevation now against the elevation one window ago. Null
/// until a window of distance has been covered, so a few metres of noise
/// can never read as a wall. Clamped to +/-45%, the range the cost model
/// covers.
class GradeWindow {
  GradeWindow(this.windowM);

  final double windowM;
  static const double maxGrade = 0.45;
  static const double baroWindowM = 50;
  static const double gpsWindowM = 100;

  static double windowFor(ElevSource src) =>
      src == ElevSource.baro ? baroWindowM : gpsWindowM;

  final List<(double, double)> _pts = [];
  int _head = 0;

  double? offer(double distM, double elevM) {
    _pts.add((distM, elevM));
    // The anchor is the newest point at least one window back; everything
    // before it is dropped.
    while (_pts.length - _head > 1 && _pts[_head + 1].$1 <= distM - windowM) {
      _head++;
    }
    if (_head > 512) {
      _pts.removeRange(0, _head);
      _head = 0;
    }
    final a = _pts[_head];
    final span = distM - a.$1;
    if (span < windowM) return null;
    return ((elevM - a.$2) / span).clamp(-maxGrade, maxGrade);
  }
}

/// Grade-adjusted pace: the flat pace that would cost the same energy as
/// running this pace on this grade.
///
/// Model: Minetti, Moia, Roi, Susta and Ferretti (2002), "Energy cost of
/// walking and running at extreme uphill and downhill slopes", J Appl
/// Physiol 93(3):1039-1046. The metabolic cost of running per kg per metre,
/// as a fifth-order polynomial in the grade i (a fraction, valid -0.45 to
/// +0.45): C(i) = 155.4 i^5 - 30.4 i^4 - 43.3 i^3 + 46.3 i^2 + 19.5 i + 3.6
/// J/(kg m). The ratio C(i) / C(0) is how much harder than flat a metre at
/// grade i is, so a stretch run at pace p on grade i is worth p / ratio on
/// the flat. It is a lab-treadmill average, not a promise: always shown as
/// an estimate.
abstract final class Gap {
  static const double _flatCost = 3.6;

  /// Metabolic cost of a metre at [grade], J/(kg m).
  static double cost(double grade) {
    final i = grade.clamp(-GradeWindow.maxGrade, GradeWindow.maxGrade);
    return 155.4 * math.pow(i, 5) -
        30.4 * math.pow(i, 4) -
        43.3 * math.pow(i, 3) +
        46.3 * i * i +
        19.5 * i +
        _flatCost;
  }

  /// How many flat metres a metre at [grade] is worth (1 on the flat, about
  /// 1.66 at +10%, about 0.6 at -10%).
  static double ratio(double grade) => cost(grade) / _flatCost;

  /// The flat-equivalent pace (s/km) of [paceSecPerKm] run at [gradePct]
  /// (percent, + uphill); null without a pace or a grade.
  static double? paceSecPerKm(double? paceSecPerKm, double? gradePct) {
    if (paceSecPerKm == null || gradePct == null) return null;
    return paceSecPerKm / ratio(gradePct / 100);
  }
}

/// One point of the elevation profile.
class ElevPoint {
  const ElevPoint({
    required this.tMs,
    required this.distM,
    required this.elevM,
    this.grade,
  });
  final int tMs;
  final double distM;
  final double elevM;

  /// Rise over run (0.05 = 5%) over the trailing window; null at the start.
  final double? grade;
}

/// A step booked by the dead band: [deltaM] > 0 climb, < 0 descent, at the
/// sample at [tMs] / [distM].
class ClimbStep {
  const ClimbStep({
    required this.tMs,
    required this.distM,
    required this.deltaM,
  });
  final int tMs;
  final double distM;
  final double deltaM;
}

/// Climb and descent over some stretch (a lap, a km).
class Climb {
  const Climb(this.ascentM, this.descentM);
  final double ascentM;
  final double descentM;
}

/// Everything the elevation views and the index row read from a run.
class RunElevation {
  RunElevation._({
    required this.src,
    required this.points,
    required this.steps,
    required this.ascentM,
    required this.descentM,
    required this.gapSecPerKm,
  });

  final ElevSource src;
  final List<ElevPoint> points;
  final List<ClimbStep> steps;

  /// Total climb and descent, metres, by [ClimbTracker] at the source's
  /// threshold, pauses left out.
  final double ascentM;
  final double descentM;

  /// Grade-adjusted whole-run pace (s/km), an estimate (see [Gap]); null
  /// when the run is too short or has no distance.
  final double? gapSecPerKm;

  /// Under this much distance a GAP is noise.
  static const double minGapDistanceM = 500;

  /// The run's lowest and highest elevation.
  double get minElevM => points.map((p) => p.elevM).reduce(math.min);
  double get maxElevM => points.map((p) => p.elevM).reduce(math.max);

  /// Null when the run has no elevation, or too little of it to draw (under
  /// two points).
  static RunElevation? of(RunFile run) {
    final src = run.elevSrc;
    if (src == null) return null;
    final tracker = ClimbTracker(ClimbTracker.thresholdFor(src));
    final window = GradeWindow(GradeWindow.windowFor(src));
    final points = <ElevPoint>[];
    final steps = <ClimbStep>[];
    final dark = [...run.pauses, ...run.gaps];
    var eqM = 0.0;
    double? lastGrade;
    double? prevDist;
    for (final s in run.samples) {
      final dist = s.distM;
      final e = s.elevM;
      if (e == null) {
        if (prevDist != null && dist > prevDist) {
          eqM += (dist - prevDist) * Gap.ratio(lastGrade ?? 0);
        }
        prevDist = dist;
        continue;
      }
      // Samples inside a pause or a dark gap: the level is followed, the
      // climb is not booked.
      final inDark = dark.any((d) => s.tMs > d.t0Ms && s.tMs <= d.t1Ms);
      if (inDark) {
        tracker.hold(e);
      } else {
        final d = tracker.offer(e);
        if (d != 0) {
          steps.add(ClimbStep(tMs: s.tMs, distM: dist, deltaM: d));
        }
      }
      final g = window.offer(dist, e);
      if (g != null) lastGrade = g;
      points.add(ElevPoint(tMs: s.tMs, distM: dist, elevM: e, grade: g));
      if (prevDist != null && dist > prevDist) {
        eqM += (dist - prevDist) * Gap.ratio(lastGrade ?? 0);
      }
      prevDist = dist;
    }
    if (points.length < 2) return null;
    final movingS = RunTimes.movingMs(run) / 1000;
    final gap = run.distanceM >= minGapDistanceM && eqM > 0 && movingS > 0
        ? movingS / (eqM / 1000)
        : null;
    return RunElevation._(
      src: src,
      points: points,
      steps: steps,
      ascentM: tracker.ascentM,
      descentM: tracker.descentM,
      gapSecPerKm: gap,
    );
  }

  /// Climb booked inside each lap (t0 < step time <= t1; the last lap takes
  /// whatever is left), so the laps add up to the totals.
  List<Climb> lapClimbs(List<Lap> laps) {
    final out = <Climb>[];
    for (var i = 0; i < laps.length; i++) {
      var up = 0.0, down = 0.0;
      for (final s in steps) {
        final after = i == 0 || s.tMs > laps[i].t0Ms;
        final before = i == laps.length - 1 || s.tMs <= laps[i].t1Ms;
        if (!after || !before) continue;
        if (s.deltaM > 0) {
          up += s.deltaM;
        } else {
          down -= s.deltaM;
        }
      }
      out.add(Climb(up, down));
    }
    return out;
  }

  /// Climb and descent per [unitM] of distance (1000 for km, 1609.344 for
  /// mi): entry k is the stretch from k * unitM to (k + 1) * unitM, the last
  /// one partial. Adds up to the totals.
  List<Climb> unitClimbs(double unitM) {
    if (points.isEmpty) return const [];
    final total = points.last.distM;
    final n = math.max(1, (total / unitM).ceil());
    final up = List<double>.filled(n, 0);
    final down = List<double>.filled(n, 0);
    for (final s in steps) {
      final k = math.min(n - 1, (s.distM / unitM).floor());
      if (s.deltaM > 0) {
        up[k] += s.deltaM;
      } else {
        down[k] -= s.deltaM;
      }
    }
    return [for (var k = 0; k < n; k++) Climb(up[k], down[k])];
  }

  /// The profile point nearest [distM] (for tapping or scrubbing the chart).
  ElevPoint nearest(double distM) {
    var lo = 0, hi = points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (points[mid].distM <= distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (distM - points[lo].distM).abs() <= (points[hi].distM - distM).abs()
        ? points[lo]
        : points[hi];
  }
}
