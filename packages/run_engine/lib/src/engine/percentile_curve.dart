import 'dart:math' as math;

/// A percentile estimate for one score lane.
///
/// [percentile] is 1..99. [extrapolated] is true when the value lies outside
/// the published 10th-90th table range, so the number is a fit to the shape of
/// the table, not a table lookup.
class PercentileEstimate {
  const PercentileEstimate(this.percentile, {required this.extrapolated});

  final int percentile;
  final bool extrapolated;

  /// Same 'about 85th' shape the string comparison API has always returned.
  String get label => 'about $percentile${_suffix(percentile)}';

  static String _suffix(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return 'th';
    return switch (n % 10) {
      1 => 'st',
      2 => 'nd',
      3 => 'rd',
      _ => 'th',
    };
  }
}

/// Percentile lookup over a published 10th..90th table (nine points, steps of
/// 10), extended past both ends with a fitted normal tail.
///
/// Method. Work on a score axis `y` that rises with percentile (VO2peak
/// directly; for finish times, y = -ln(seconds), i.e. a log-normal on time).
/// Inside the published range the table is interpolated linearly and rounded
/// to 5, exactly as before, so no existing value moves. Outside it, the tail
/// is a normal curve: p = Phi(z0 + (y - y0) / sigma), anchored at the table
/// edge (z0 = Phi^-1(0.9) or Phi^-1(0.1), y0 = the edge value). Anchoring makes
/// the join continuous. sigma is the least-squares slope of y on Phi^-1(p)
/// through the anchor over the three published points nearest that edge (70th,
/// 80th, 90th; 10th, 20th, 30th), so it reflects local spread and a skewed row
/// gets a different sigma on each side (a two-piece normal). Fitting the whole
/// row instead leaves residuals of 3 to 5 points because the tables are not
/// normal across 10-90. Results are clamped to 1..99 and rounded to whole percentiles; the
/// tail is a shape estimate, so nothing finer than that is claimed.
///
/// Fit quality is checked in test/percentile_curve_test.dart: the tail model
/// evaluated at the published points it was fitted on lands within 1.0
/// percentile points of the table for most rows and within 1.6 for the worst
/// (FRIEND men 80-89 and women 70-89, the most skewed). The join has zero
/// residual at the 10th and 90th by construction.
class PercentileCurve {
  PercentileCurve(List<double> ys)
    : assert(ys.length == 9),
      _ys = List.unmodifiable(ys),
      _sigmaLow = _slope(ys, _z, [0, 1, 2], 0),
      _sigmaHigh = _slope(ys, _z, [6, 7, 8], 8);

  static const _z = <double>[
    -1.2815515655446004,
    -0.8416212335729143,
    -0.5244005101,
    -0.2533471031,
    0.0,
    0.2533471031,
    0.5244005101,
    0.8416212335729143,
    1.2815515655446004,
  ];

  final List<double> _ys;
  final double _sigmaLow;
  final double _sigmaHigh;

  /// Null when [y] is not finite.
  PercentileEstimate? at(double y) {
    if (!y.isFinite) return null;
    if (y < _ys.first) {
      final z = _z.first + (y - _ys.first) / _sigmaLow;
      return PercentileEstimate(_tail(z), extrapolated: true);
    }
    if (y > _ys.last) {
      final z = _z.last + (y - _ys.last) / _sigmaHigh;
      return PercentileEstimate(_tail(z), extrapolated: true);
    }
    for (var i = 0; i < 8; i++) {
      final lower = _ys[i];
      final upper = _ys[i + 1];
      if (y <= upper) {
        final fraction = upper == lower ? 0 : (y - lower) / (upper - lower);
        final rounded = ((10 + i * 10 + fraction * 10) / 5).round() * 5;
        return PercentileEstimate(rounded, extrapolated: false);
      }
    }
    return const PercentileEstimate(90, extrapolated: false);
  }

  /// Fitted percentile for the tail model at [y], unrounded, for tests.
  double tailPercentileAt(double y) {
    final high = y >= _ys[4];
    final z = high
        ? _z.last + (y - _ys.last) / _sigmaHigh
        : _z.first + (y - _ys.first) / _sigmaLow;
    return _phi(z) * 100;
  }

  static int _tail(double z) => (_phi(z) * 100).round().clamp(1, 99);

  /// Least-squares sigma for the line y = y[anchor] + sigma * (z - z[anchor])
  /// through the anchor, over [idx]. Floored so a flat or noisy row cannot
  /// divide by zero.
  static double _slope(
    List<double> y,
    List<double> z,
    List<int> idx,
    int anchor,
  ) {
    var num = 0.0, den = 0.0;
    for (final i in idx) {
      final dz = z[i] - z[anchor];
      num += dz * (y[i] - y[anchor]);
      den += dz * dz;
    }
    final s = num / den;
    return s > 1e-9 ? s : 1e-9;
  }

  /// Standard normal CDF (Abramowitz-Stegun 7.1.26 erf, error < 1.5e-7).
  static double _phi(double z) {
    final x = z.abs() / math.sqrt2;
    final t = 1 / (1 + 0.3275911 * x);
    final poly =
        ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t -
                    0.284496736) *
                t +
            0.254829592) *
        t;
    final erf = 1 - poly * math.exp(-x * x);
    return z >= 0 ? 0.5 * (1 + erf) : 0.5 * (1 - erf);
  }
}
