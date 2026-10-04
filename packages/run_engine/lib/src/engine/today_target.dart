import '../weather/heat_model.dart';

/// "Today's target" on Start: what the heat does to a True Pace aim.
///
/// True Pace takes heat out of a run, so holding [trueSecPerKm] in the
/// heat means running [actualSecPerKm] on the watch (the whole-run Hadley
/// fraction; the short-run ramp is left out so the line never promises more
/// than the table says). No line below [minFraction]: a cool day has
/// nothing to say.
class TodayTarget {
  const TodayTarget._({
    required this.tempC,
    required this.fraction,
    required this.trueSecPerKm,
    required this.actualSecPerKm,
    required this.word,
  });

  /// Below this slowdown (0.5%) there is no line.
  static const double minFraction = 0.005;

  final double tempC;

  /// The heat slowdown (0.047 = 4.7%); null when too hot to compare.
  final double? fraction;
  final double trueSecPerKm;

  /// The pace to run to hold [trueSecPerKm]; null when too hot to compare.
  final double? actualSecPerKm;

  /// "Warm", "Hot" or "Very hot".
  final String word;

  bool get tooHot => fraction == null;

  /// Null when it is cool enough that the heat changes nothing.
  static TodayTarget? of({
    required double tempC,
    required double dewPointC,
    required double aimTrueSecPerKm,
  }) {
    final heat = HeatModel.of(tempC: tempC, dewPointC: dewPointC);
    final f = heat.fraction;
    if (f != null && f < minFraction) return null;
    return TodayTarget._(
      tempC: tempC,
      fraction: f,
      trueSecPerKm: aimTrueSecPerKm,
      actualSecPerKm: f == null ? null : aimTrueSecPerKm / (1 - f),
      word: f == null || f >= 0.08
          ? 'Very hot'
          : f >= 0.06
          ? 'Hot'
          : 'Warm',
    );
  }
}
