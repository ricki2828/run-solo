import '../model/run_file.dart';
import 'trace.dart';

/// Cooper 12-minute test projection (Phase 4 plan §3.3, B1 / CO1).
///
/// `F(t)` is the fraction of the final 12-minute distance typically covered
/// by minute `t` (12 points, `F(12) = 1`). Mid-test, the projected distance
/// is `d(t) / F(t)` and the VO2 estimate `(d − 504.9) / 44.73` (Cooper
/// 1968). Replaces the Phase 3 linear `d / elapsed × 720`, which
/// over-projects after a fast start. Mirrored in Kotlin `CooperProjection.kt`
/// from the shared fixture table `test/fixtures/cooper/cooper_projection.json`.
abstract final class CooperProjection {
  static const int testSeconds = 720;
  static const int minutes = 12;

  /// No projection before this: one minute of data says little.
  static const int firstProjectionSeconds = 60;

  /// The likely range on the result, ± this many ml/kg/min (plan §3.3, §4
  /// R2: r = 0.78 → about ±4.4, plus ~2% GPS distance error). Derived,
  /// needs verification.
  static const double rangeHalfWidth = 5;

  /// Valid prior tests needed before the personal curve replaces the
  /// default (founder decision: switch after 2, so from test 3 on).
  static const int personalAfterTests = 2;

  /// The personal curve averages at most this many recent valid tests.
  static const int personalWindow = 3;

  /// Cooper 1968. An estimate, never a measurement.
  static double vo2(double metres) => (metres - 504.9) / 44.73;

  /// Projection at [elapsedSeconds] into the test with [distanceM] covered
  /// so far; null before [firstProjectionSeconds] or with no distance.
  static CooperEstimate? project(
    CooperCurve curve, {
    required double elapsedSeconds,
    required double distanceM,
  }) {
    if (elapsedSeconds < firstProjectionSeconds || distanceM <= 0) {
      return null;
    }
    final f = curve.fractionAt(elapsedSeconds / 60);
    return CooperEstimate(distanceM / f);
  }

  /// The curve for a runner's next test: their own once they have
  /// [personalAfterTests] valid tests, else the default. [validTests] holds
  /// each valid test's `cooperMinuteM` (paused and noisy tests already left
  /// out by the caller), oldest first.
  static CooperCurve curveFor(List<List<double>> validTests) {
    final curves = [
      for (final m in validTests) ?CooperCurve.fromMinuteDistances(m),
    ];
    if (curves.length < personalAfterTests) return CooperCurve.defaultCurve;
    return CooperCurve.mean(
      curves.sublist(
        curves.length > personalWindow ? curves.length - personalWindow : 0,
      ),
    );
  }

  /// When the test itself started, in ms since the run start. The test is
  /// one lap of 12:00 (± 5 s), found in this order:
  /// 1. the lap right after the warm-up lap ("Start reps" ends the warm-up,
  ///    I2), so a warm-up that itself lasted about 12:00 is never taken;
  /// 2. a 12:00 lap the recorder ended itself (auto: the step's own end);
  /// 3. any 12:00 lap (a pre-I2 file: one manual lap).
  /// With none: the end of the first lap when there are several, else 0.
  static int testStartMs(RunFile run) {
    final laps = [
      for (final l in run.laps)
        if (l.kind != LapKind.pause) l,
    ];
    bool twelve(Lap l) => (l.durationMs - testSeconds * 1000).abs() <= 5000;
    if (laps.length >= 2 && twelve(laps[1])) return laps[1].t0Ms;
    final candidates = laps.where(twelve).toList();
    final auto = candidates.where((l) => l.kind == LapKind.auto);
    if (auto.isNotEmpty) return auto.first.t0Ms;
    if (candidates.isNotEmpty) return candidates.first.t0Ms;
    return laps.length >= 2 ? laps.first.t1Ms : 0;
  }

  /// `cooperMinuteM[]`: cumulative distance at each whole minute of the
  /// test (12 values). Null when the test was paused, never reached 12:00
  /// (1 s grace), or the distances are not usable.
  static List<double>? minuteDistances(RunFile run) {
    final start = testStartMs(run);
    final end = start + testSeconds * 1000;
    if (run.elapsedMs < end - 1000) return null;
    for (final p in run.pauses) {
      if (p.t0Ms < end && p.t1Ms > start) return null;
    }
    final trace = Trace(run.samples);
    final d0 = trace.distAt(start);
    final out = [
      for (var m = 1; m <= minutes; m++) trace.distAt(start + m * 60000) - d0,
    ];
    return CooperCurve.fromMinuteDistances(out) == null ? null : out;
  }
}

/// A projected 12-minute distance and its VO2 estimate.
class CooperEstimate {
  const CooperEstimate(this.distanceM);

  final double distanceM;
  double get vo2 => CooperProjection.vo2(distanceM);
  double get vo2Low => vo2 - CooperProjection.rangeHalfWidth;
  double get vo2High => vo2 + CooperProjection.rangeHalfWidth;

  /// Spoken each minute from 2:00 to 11:00: "5 minutes. Heading for about
  /// 2,740. VO2 about 50." Rounded to 10 m and a whole VO2 here only.
  String cue(int minute) {
    final m = minute == 1 ? '1 minute' : '$minute minutes';
    return '$m. Heading for about ${_thousands(_round10(distanceM))}. '
        'VO2 about ${vo2.round()}.';
  }

  /// Label the result screen renders [rangeText] under (plan §3.3, WARN-4:
  /// the number never appears without it).
  static const String rangeLabel = 'VO2 estimate';

  /// "VO2 estimate 50 (45 to 55)": the range as a runner reads it, label
  /// included; what the string lint checks.
  String get rangeLine => '$rangeLabel $rangeText';

  /// "50 (45 to 55)": only ever shown under [rangeLabel].
  String get rangeText =>
      '${vo2.round()} (${vo2Low.round()} to ${vo2High.round()})';

  static int _round10(double m) => (m / 10).round() * 10;

  static String _thousands(int n) {
    final s = n.abs().toString();
    final b = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

/// Cumulative fraction of the 12-minute distance at minutes 1..12.
class CooperCurve {
  CooperCurve._(List<double> fractions)
    : fractions = List.unmodifiable(fractions);

  /// `F(1)..F(12)`; `F(12) == 1`, strictly increasing.
  final List<double> fractions;

  /// Tests 1 and 2 (plan §3.3, science review): an asymmetric U, minute 1
  /// at 1.05 × mean speed, minutes 2–11 easing linearly 0.99 → 0.97
  /// (average 0.98), minute 12 at 1.03, normalised so `F(12) = 1`.
  /// Placeholder magnitudes shaped by the Augmented Cooper test (Frontiers
  /// 2022, Fig. 5B) and 5K/10K pacing: needs verification; the personal
  /// curve replaces it from test 3.
  static final CooperCurve defaultCurve = CooperCurve.fromMinuteSpeeds([
    1.05,
    for (var i = 0; i < 10; i++) 0.99 - 0.02 * i / 9,
    1.03,
  ]);

  /// From 12 relative per-minute speeds (any scale).
  factory CooperCurve.fromMinuteSpeeds(List<double> speeds) {
    if (speeds.length != CooperProjection.minutes) {
      throw ArgumentError('a Cooper curve needs 12 minutes');
    }
    final total = speeds.fold<double>(0, (a, b) => a + b);
    var acc = 0.0;
    return CooperCurve._(
      [for (final s in speeds) (acc += s) / total]
        ..[CooperProjection.minutes - 1] = 1,
    );
  }

  /// One test's curve from its 12 cumulative minute distances; null unless
  /// they strictly increase from a positive first minute.
  static CooperCurve? fromMinuteDistances(List<double> m) {
    if (m.length != CooperProjection.minutes || m.first <= 0) return null;
    for (var i = 1; i < m.length; i++) {
      if (!(m[i] > m[i - 1])) return null;
    }
    final total = m.last;
    return CooperCurve._([
      for (var i = 0; i < m.length - 1; i++) m[i] / total,
      1,
    ]);
  }

  /// Point-wise mean (plan: mean of the runner's cumulative fraction
  /// curves).
  factory CooperCurve.mean(List<CooperCurve> curves) {
    if (curves.isEmpty) throw ArgumentError('no curves');
    return CooperCurve._([
      for (var i = 0; i < CooperProjection.minutes; i++)
        curves.fold<double>(0, (a, c) => a + c.fractions[i]) / curves.length,
    ]);
  }

  /// `F` at any time in minutes, linear between the whole minutes with
  /// `F(0) = 0`; clamped to 0–12.
  double fractionAt(double minute) {
    if (minute <= 0) return 0;
    if (minute >= CooperProjection.minutes) return 1;
    final i = minute.floor();
    final lo = i == 0 ? 0.0 : fractions[i - 1];
    final hi = fractions[i];
    return lo + (hi - lo) * (minute - i);
  }

  /// `files/state/cooper-curve.json` and the LiveContext `cooperCurve`.
  List<double> toJson() => fractions;

  static CooperCurve? fromJson(Object? j) {
    if (j is! List || j.length != CooperProjection.minutes) return null;
    final f = [
      for (final v in j)
        if (v is num) v.toDouble() else double.nan,
    ];
    if (f.any((v) => v.isNaN) || f.first <= 0 || (f.last - 1).abs() > 1e-9) {
      return null;
    }
    for (var i = 1; i < f.length; i++) {
      if (!(f[i] > f[i - 1])) return null;
    }
    return CooperCurve._(f);
  }
}
