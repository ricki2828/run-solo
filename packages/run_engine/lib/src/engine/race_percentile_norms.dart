import 'fitness_hero.dart';
import 'identity_scores.dart';

/// Recreational race finisher reference, NOT all people of the same age.
/// RunRepeat's published finish-time tables (updated 2024):
/// https://runrepeat.com/how-do-you-masure-up-the-runners-percentile-calculator
/// Table rows are fastest 10%, 20%, ... 90%. These tables do not stratify age.
/// MID/LONG use VDOT to estimate an equivalent race time, so a training run
/// is not misrepresented as an actual race placing. Bound rather than invent
/// percentiles beyond the tabulated range.
abstract final class RacePercentileNorms {
  static const source = 'RunRepeat recreational race finishers';
  static const _female5k = [
    1704,
    1869,
    1999,
    2121,
    2248,
    2387,
    2556,
    2783,
    3144,
  ];
  static const _male5k = [1406, 1564, 1678, 1781, 1888, 2008, 2155, 2361, 2743];
  static const _female10k = [
    3215,
    3481,
    3662,
    3830,
    4014,
    4238,
    4536,
    4966,
    5594,
  ];
  static const _male10k = [
    2711,
    2977,
    3148,
    3290,
    3435,
    3602,
    3823,
    4153,
    4761,
  ];
  static const _femaleHalf = [
    7021,
    7558,
    7945,
    8290,
    8643,
    9044,
    9545,
    10231,
    11301,
  ];
  static const _maleHalf = [
    6035,
    6553,
    6903,
    7096,
    7188,
    7798,
    8191,
    8757,
    9768,
  ];
  static const _femaleMarathon = [
    13762,
    14818,
    15624,
    16281,
    16929,
    17617,
    18456,
    19600,
    21391,
  ];
  static const _maleMarathon = [
    12160,
    13213,
    13987,
    14627,
    15269,
    15933,
    16706,
    17733,
    19526,
  ];

  /// Run-derived VDOT to equivalent race time. The input is a capacity proxy
  /// selected by the lane's evidence rules, not a prediction guarantee.
  static double? equivalentSeconds(double vdot, double metres) {
    if (!vdot.isFinite || vdot <= 0) return null;
    var low = 1.0;
    var high = 24 * 3600.0;
    for (var i = 0; i < 60; i++) {
      final mid = (low + high) / 2;
      final estimate = FitnessHero.vdot(metres, (mid * 1000).round());
      if (estimate > vdot) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (low + high) / 2;
  }

  /// Null for lanes whose evidence cannot be compared with these race tables.
  static String? comparison(
    double vdot,
    IdentityLane lane,
    String evidence, {
    required bool female,
  }) {
    if (lane != IdentityLane.mid && lane != IdentityLane.long) return null;
    final isMarathon = evidence == 'Marathon';
    final is10k = evidence == '10K';
    final metres = lane == IdentityLane.long
        ? (isMarathon ? 42195.0 : 21097.5)
        : (is10k ? 10000.0 : 5000.0);
    final table = lane == IdentityLane.long
        ? (isMarathon
              ? (female ? _femaleMarathon : _maleMarathon)
              : (female ? _femaleHalf : _maleHalf))
        : (is10k
              ? (female ? _female10k : _male10k)
              : (female ? _female5k : _male5k));
    final seconds = equivalentSeconds(vdot, metres);
    if (seconds == null) return null;
    if (seconds < table.first) return 'above 90th';
    if (seconds > table.last) return 'below 10th';
    for (var i = 0; i < table.length - 1; i++) {
      if (seconds <= table[i + 1]) {
        final fraction = (seconds - table[i]) / (table[i + 1] - table[i]);
        final mark = ((90 - i * 10 - fraction * 10) / 5).round() * 5;
        return 'about ${mark}th';
      }
    }
    return 'about 10th';
  }

  static String referenceDistance(IdentityLane lane, String evidence) =>
      lane == IdentityLane.mid
      ? (evidence == '10K' ? '10K' : '5K')
      : (evidence == 'Marathon' ? 'marathon' : 'half marathon');
}
