import '../model/run_file.dart';

/// Number formatting shared by verdict copy and the UI. Paces are stored in
/// s/km and converted at the edge (plan §4: units only affect display).
class PaceFormat {
  const PaceFormat._();

  static const double metresPerMile = 1609.344;

  static String unitLabel(Units units) => units == Units.mi ? 'mi' : 'km';

  /// s/km → s/unit.
  static double toUnit(double secPerKm, Units units) =>
      units == Units.mi ? secPerKm * metresPerMile / 1000 : secPerKm;

  /// "4:44" from seconds; rounds to the nearest second.
  static String mmss(double seconds) {
    final total = seconds.round();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// "4:44/km".
  static String pace(double secPerKm, Units units) =>
      '${mmss(toUnit(secPerKm, units))}/${unitLabel(units)}';

  /// "4:44" without the unit suffix (for "4:44 vs 4:58/km").
  static String paceBare(double secPerKm, Units units) =>
      mmss(toUnit(secPerKm, units));

  /// "14 s/km" from a delta in s/km (absolute value).
  static String delta(double secPerKm, Units units) =>
      '${toUnit(secPerKm.abs(), units).round()} s/${unitLabel(units)}';

  /// "5 s" (absolute value).
  static String seconds(double s) => '${s.abs().round()} s';

  /// "Three" for the interrupted subline; digits past ten.
  static String countWord(int n) => switch (n) {
    0 => 'No',
    1 => 'One',
    2 => 'Two',
    3 => 'Three',
    4 => 'Four',
    5 => 'Five',
    6 => 'Six',
    7 => 'Seven',
    8 => 'Eight',
    9 => 'Nine',
    10 => 'Ten',
    _ => '$n',
  };
}
