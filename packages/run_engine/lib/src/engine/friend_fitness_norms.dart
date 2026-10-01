/// Context for run-derived VDOT, compared cautiously with measured treadmill
/// VO2peak in the 2022 FRIEND US registry. Not a clinical VO2 measurement,
/// race placing, or a percentile of Run Solo's 0-99 display score.
///
/// Kaminsky et al., Mayo Clin Proc. 2022;97(2):285-293, Table 3 (treadmill,
/// RER >= 1.0): https://doi.org/10.1016/j.mayocp.2021.08.020
/// Values are ml/kg/min. Columns are age decades 20-29 through 80-89.
abstract final class FriendFitnessNorms {
  static const source = 'FRIEND 2022, US treadmill lab VO2peak (Table 3)';
  static const caveat =
      'This is a rough comparison. Your number comes from your running; '
      'the research measured US adults on a lab treadmill. '
      'Not a race result or a medical test.';

  // Rows correspond to percentiles 10,20,...90; columns to age decades.
  static const men = <List<double>>[
    [28.6, 24.9, 22.1, 18.6, 15.8, 13.6, 12.9],
    [35.2, 29.8, 26.7, 22.2, 18.5, 15.9, 14.8],
    [40.0, 33.5, 29.7, 24.5, 20.7, 17.3, 16.1],
    [43.6, 37.0, 32.4, 26.9, 22.8, 19.1, 16.6],
    [46.5, 39.7, 35.3, 29.2, 24.6, 20.6, 17.6],
    [49.0, 43.4, 37.9, 31.8, 26.5, 22.2, 18.4],
    [51.9, 46.4, 40.9, 34.3, 28.7, 23.8, 20.0],
    [54.5, 50.0, 45.2, 38.3, 32.0, 25.9, 21.4],
    [58.6, 55.5, 50.8, 43.4, 37.1, 29.4, 22.8],
  ];
  static const women = <List<double>>[
    [22.5, 18.6, 17.2, 16.5, 13.4, 12.3, 11.4],
    [27.2, 21.9, 19.7, 18.5, 15.4, 14.0, 12.6],
    [30.8, 24.2, 21.8, 20.1, 17.0, 15.2, 13.7],
    [34.0, 26.4, 23.9, 21.5, 18.3, 16.2, 14.7],
    [36.6, 28.3, 25.7, 22.9, 19.6, 17.2, 15.4],
    [39.0, 31.0, 27.7, 24.6, 20.9, 18.3, 16.0],
    [41.8, 33.6, 30.0, 26.3, 22.4, 19.6, 17.3],
    [44.8, 37.0, 33.0, 28.4, 24.3, 20.8, 18.4],
    [49.0, 42.1, 37.8, 32.4, 27.3, 22.8, 20.8],
  ];

  /// Estimate only between tabulated 10th and 90th percentiles. Outside
  /// the table, return a bound instead of fabricating an exact percentile.
  static String? comparison(double vdot, int age, {required bool female}) {
    if (!vdot.isFinite || age < 20 || age > 89) return null;
    final decade = (age - 20) ~/ 10;
    final table = female ? women : men;
    if (vdot < table.first[decade]) return 'below 10th';
    if (vdot > table.last[decade]) return 'above 90th';
    for (var i = 0; i < 8; i++) {
      final lower = table[i][decade];
      final upper = table[i + 1][decade];
      if (vdot <= upper) {
        final fraction = upper == lower ? 0 : (vdot - lower) / (upper - lower);
        final rounded = ((10 + i * 10 + fraction * 10) / 5).round() * 5;
        return 'about ${rounded}th';
      }
    }
    return 'about 90th';
  }
}
