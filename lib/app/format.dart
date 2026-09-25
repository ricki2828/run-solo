/// Display formatting at the edge (plan §4: units only affect display).
/// Pace maths lives in `run_engine`'s `PaceFormat`; this adds the timer and
/// distance shapes the screens need.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';

abstract final class Fmt {
  static engine.Units _u(Units units) =>
      units == Units.mi ? engine.Units.mi : engine.Units.km;

  /// "2:47" (or "1:02:47" past an hour). Floors so a countdown reaches 0:00
  /// exactly when the phase ends.
  static String clock(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// "4:41" or "--" without GPS.
  static String pace(double? secPerKm, Units units) =>
      secPerKm == null ? '--' : engine.PaceFormat.paceBare(secPerKm, _u(units));

  /// "4:41/km".
  static String paceUnit(double? secPerKm, Units units) =>
      secPerKm == null ? '--' : engine.PaceFormat.pace(secPerKm, _u(units));

  /// "0.62" (unit in the column header).
  static String distanceBare(double metres, Units units) {
    final v = units == Units.mi
        ? metres / engine.PaceFormat.metresPerMile
        : metres / 1000;
    return v.toStringAsFixed(2);
  }

  /// "0.62 km" / "0.39 mi".
  static String distance(double metres, Units units) {
    final v = units == Units.mi
        ? metres / engine.PaceFormat.metresPerMile
        : metres / 1000;
    return '${v.toStringAsFixed(2)} ${engine.PaceFormat.unitLabel(_u(units))}';
  }

  /// "5 s"; the arrow beside it is a `DeltaGlyph` (the bundled fonts carry
  /// no ▲▼▬ glyphs), direction from live minus last.
  static String deltaVsLast(double live, double last, Units units) {
    final d = engine.PaceFormat.toUnit(live - last, _u(units)).round();
    return '${d.abs()} s';
  }

  static String recovery(int seconds) => clock(seconds * 1000);

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// "Tue 24 Sep".
  static String dayDate(DateTime d) =>
      '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

  /// "September 2026".
  static String monthYear(DateTime d) {
    const full = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${full[d.month - 1]} ${d.year}';
  }

  /// "10:47".
  static String hhmm(DateTime d) =>
      '${d.hour}:${d.minute.toString().padLeft(2, '0')}';

  /// "3 days ago" / "today" / "yesterday".
  static String ago(DateTime then, DateTime now) {
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(then.year, then.month, then.day)).inDays;
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      _ => '$days days ago',
    };
  }
}
