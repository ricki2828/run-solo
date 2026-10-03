import '../model/run_file.dart';
import 'format.dart';

/// TRUE PACE: your pace adjusted for hills AND heat, i.e. what it would have
/// been on flat ground on a cool day. The one fair pace every comparison,
/// score, board and trend uses; raw pace is always shown beside it.
///
///     truePace = rawMovingPace x gradeFactor x heatFactor
///
/// Both factors multiply a PACE (s/km) or a TIME over the same stretch, so
/// below 1 means "faster than the clock says":
///
/// - gradeFactor = distance / flat-equivalent distance over the stretch,
///   where each metre at grade i counts C(i) / C(0) flat metres. C is the
///   Minetti et al. (2002) energy cost of running, J/(kg m) (J Appl Physiol
///   93(3):1039-1046; see `Gap` in elevation.dart for the polynomial). Climbs
///   give a factor under 1, a net descent over 1. Worked per segment where
///   elevation exists (a rep, a best-effort window, the whole run) and 1
///   where it does not, and 1 for GPS-only elevation, which is too noisy
///   for the grade model (the rule the old effort pace credit already had).
///   Clamped to [minGrade] .. [maxGrade], so one wild grade estimate cannot
///   mint a fantasy pace.
/// - heatFactor = 1 - slowdown, the slowdown taken from the temperature +
///   dew point table (Hadley, Maximum Performance Running, 2013; see
///   `HeatModel`): up to 10 %, never a cold bonus. 1 without weather, on a
///   cool day, and when it was too hot to adjust at all. Whole-run figures
///   use the full slowdown; a split or rep inside a long run uses
///   `HeatModel.distanceRamp` (display only, as for the old per-split heat).
///
/// Both models are lab and field averages, not promises: user copy calls the
/// figure an estimate wherever it is explained (detail views).
abstract final class TruePace {
  /// Hills: at most 25 % faster (a very hilly run) or 15 % slower (a long
  /// net descent) than the clock.
  static const double minGrade = 0.75;
  static const double maxGrade = 1.15;

  /// Heat: the model's own ceiling is a 10 % slowdown.
  static const double minHeat = 0.90;

  /// Below this slowdown or hill effect the breakdown names no reason.
  static const double reasonThreshold = 0.01;

  /// Barometer noise on a road run reads as a tiny grade; inside this the
  /// hills factor is exactly 1, so a flat run's true pace stays its actual
  /// pace.
  static const double gradeDeadband = 0.005;

  /// For SCORING (identity lanes, the Home hero, predictions) hills and heat
  /// together never count a run more than 20% faster than its clock; the
  /// display keeps the wider [minGrade] x [minHeat] range.
  static const double minScoringFactor = 0.80;

  static double clampGrade(double f) =>
      (f - 1).abs() < gradeDeadband ? 1.0 : f.clamp(minGrade, maxGrade);

  /// The heat factor for a whole-run [slowdown] fraction (0.047 = 4.7 %);
  /// 1 when null (no weather, too hot to adjust).
  static double heatFactor(double? slowdown) =>
      slowdown == null ? 1.0 : (1 - slowdown).clamp(minHeat, 1.0);

  /// The factors for a stretch: [gradeFactor] (null = no elevation) and the
  /// run's heat [slowdown], at [midpointM] metres into the run for a split
  /// or rep (null = the whole-run figure).
  static TruePaceFactors factors({
    double? gradeFactor,
    double? slowdown,
    double? midpointM,
    double Function(double metres)? ramp,
  }) {
    final heat = heatFactor(
      slowdown == null || midpointM == null || ramp == null
          ? slowdown
          : slowdown * ramp(midpointM),
    );
    return TruePaceFactors(
      grade: gradeFactor == null ? 1.0 : clampGrade(gradeFactor),
      heat: heat,
    );
  }
}

/// The hill and heat multipliers of one stretch of running.
class TruePaceFactors {
  const TruePaceFactors({this.grade = 1, this.heat = 1});

  static const TruePaceFactors none = TruePaceFactors();

  /// Hills, on pace and time (under 1 = climbing made it slower than flat).
  final double grade;

  /// Heat, on pace and time (under 1 = the heat slowed it).
  final double heat;

  double get combined => grade * heat;

  /// Neither factor moves the pace by a visible amount.
  bool get neutral => (grade - 1).abs() < 0.0005 && (heat - 1).abs() < 0.0005;

  bool get hilly => (grade - 1).abs() >= TruePace.reasonThreshold;
  bool get hot => (1 - heat) >= TruePace.reasonThreshold;

  /// The flat, cool-day pace for a raw [secPerKm] (or time over the stretch).
  double apply(double raw) => raw * combined;

  /// [apply] for scores: never more than 20% faster than [raw]
  /// ([TruePace.minScoringFactor]).
  double applyForScore(double raw) =>
      raw *
      (combined < TruePace.minScoringFactor
          ? TruePace.minScoringFactor
          : combined);

  /// "hilly", "hot day", "hilly, hot day"; null when neither is worth
  /// naming.
  String? get reason {
    final parts = [
      if (hilly) grade < 1 ? 'hilly' : 'downhill',
      if (hot) 'hot day',
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  @override
  bool operator ==(Object other) =>
      other is TruePaceFactors && other.grade == grade && other.heat == heat;

  @override
  int get hashCode => Object.hash(grade, heat);
}

/// The words for a True Pace beside its raw pace.
abstract final class TruePaceText {
  /// "4:22 true pace (4:31 actual, hot day)"; just "4:22 true pace" when
  /// the factors change nothing visible. A rep-time session ([repMetres],
  /// 400s and the like) reads as the time for the rep: "1:28 true time
  /// (1:30 actual, hot day)".
  static String headline(
    double rawSecPerKm,
    TruePaceFactors f,
    Units units, {
    double? repMetres,
  }) {
    final noun = repMetres == null ? 'pace' : 'time';
    String show(double secPerKm) => repMetres == null
        ? PaceFormat.paceBare(secPerKm, units)
        : PaceFormat.mmss(secPerKm * repMetres / 1000);
    final truePace = show(f.apply(rawSecPerKm));
    final raw = show(rawSecPerKm);
    if (truePace == raw && f.reason == null) return '$truePace true $noun';
    final why = f.reason == null ? '' : ', ${f.reason}';
    return '$truePace true $noun ($raw actual$why)';
  }

  /// "True pace 4:58/km = actual 5:21, hills -0:18, heat -0:05"; the parts
  /// add up exactly on the rounded seconds shown. Null when the factors
  /// change nothing (a flat, cool run needs no breakdown).
  static String? breakdown(
    double rawSecPerKm,
    TruePaceFactors f,
    Units units, {
    String label = 'True pace',
  }) {
    if (f.neutral) return null;
    final raw = PaceFormat.toUnit(rawSecPerKm, units);
    final afterHills = PaceFormat.toUnit(rawSecPerKm * f.grade, units);
    final truePace = PaceFormat.toUnit(f.apply(rawSecPerKm), units);
    final r = raw.round(), h = afterHills.round(), t = truePace.round();
    String part(String label, int sec) =>
        '$label ${sec < 0 ? '-' : '+'}${PaceFormat.mmss(sec.abs().toDouble())}';
    final parts = [
      if (f.grade != 1 && h != r)
        part(f.grade > 1 ? 'downhill' : 'hills', h - r),
      if (f.heat != 1 && t != h) part('heat', t - h),
    ];
    final unit = PaceFormat.unitLabel(units);
    return '$label ${PaceFormat.mmss(t.toDouble())}/$unit = actual '
        '${PaceFormat.mmss(r.toDouble())}'
        '${parts.isEmpty ? '' : ', ${parts.join(', ')}'}';
  }
}
