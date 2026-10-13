/// Reference 5K paces for the Progress "Your pack" table, from the published
/// RunRepeat recreational finisher deciles (the same tables the engine uses
/// for MID percentiles). Norms only: no other runner's data is involved.
library;

/// 5K finish seconds at the 90th, 80th ... 10th percentile (fastest first).
const List<int> _male5k = [
  1406,
  1564,
  1678,
  1781,
  1888,
  2008,
  2155,
  2361,
  2743,
];
const List<int> _female5k = [
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

abstract final class PackNorms {
  /// Seconds per km for a 5K at [percentile] (0..100, higher is faster),
  /// linear between deciles and held flat beyond the 10th and 90th.
  static double paceSecPerKm(int percentile, {required bool female}) {
    final table = female ? _female5k : _male5k;
    final idx = ((90 - percentile) / 10).clamp(0.0, 8.0);
    final lo = idx.floor();
    final hi = idx.ceil();
    final sec = table[lo] + (table[hi] - table[lo]) * (idx - lo);
    return sec / 5;
  }

  /// "5:19" from seconds per km.
  static String pace(double secPerKm) {
    final s = secPerKm.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Female bands start with F ("F30-39").
  static bool isFemaleBand(String band) => band.startsWith('F');
}
