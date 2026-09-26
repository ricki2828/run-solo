import '../model/run_file.dart';
import '../weather/cooper_heat.dart';
import '../weather/weather.dart';
import 'cooper_projection.dart';
import 'trace.dart';

/// Why a 12-minute test gives no VO2 estimate (A5: "a paused test gives
/// no estimate").
enum CooperInvalid {
  /// Paused inside the 12:00: the test is over.
  paused,

  /// Stopped before 12:00 (1 s grace).
  short,

  /// No usable GPS for the distance.
  indoor,

  /// GPS too noisy to trust the distance.
  noisy,
}

/// The 12-minute test's result (Phase 3 C1, v1 plan §18.4, Phase 4 CO2):
/// the distance in the 12:00, and when the test is valid its VO2 estimate
/// with the likely range ([CooperEstimate]) and the HV1 heat twin. The raw
/// estimate is always the headline; the heat figure is its own line.
class CooperResult {
  const CooperResult._({
    required this.testDistanceM,
    required this.minuteM,
    required this.invalid,
    required this.heat,
  });

  /// Reads [run]'s test window (the lap [CooperProjection.testStartMs]
  /// finds). [indoor] and [noisy] come from the analysis' GPS checks.
  factory CooperResult.of(
    RunFile run, {
    required bool indoor,
    required bool noisy,
    WeatherRecord? weather,
  }) {
    final start = CooperProjection.testStartMs(run);
    final end = start + CooperProjection.testSeconds * 1000;
    final trace = Trace(run.samples);
    final reachedMs = run.elapsedMs < end ? run.elapsedMs : end;
    final covered = reachedMs <= start
        ? 0.0
        : trace.distAt(reachedMs) - trace.distAt(start);
    final paused = run.pauses.any((p) => p.t0Ms < end && p.t1Ms > start);
    final minuteM = CooperProjection.minuteDistances(run);
    final invalid = indoor
        ? CooperInvalid.indoor
        : paused
        ? CooperInvalid.paused
        : run.elapsedMs < end - 1000
        ? CooperInvalid.short
        : noisy || minuteM == null
        ? CooperInvalid.noisy
        : null;
    return CooperResult._(
      testDistanceM: invalid == null ? minuteM!.last : covered,
      minuteM: invalid == null ? minuteM : null,
      invalid: invalid,
      heat: invalid == null ? CooperHeat.of(weather) : null,
    );
  }

  /// Metres run in the 12:00 (as far as the test got when it is invalid).
  final double testDistanceM;

  /// Cumulative metres at each whole minute 1..12; null when invalid.
  final List<double>? minuteM;
  final CooperInvalid? invalid;

  /// HV1 adjustment for the hour's weather; null without `ok` weather.
  final CooperHeatAdjustment? heat;

  bool get valid => invalid == null;

  /// The raw estimate and its range; null when the test is invalid.
  CooperEstimate? get estimate => valid ? CooperEstimate(testDistanceM) : null;

  /// The heat-adjusted VO2 estimate (HV1: the distance cool conditions
  /// would have given, through the Cooper formula); null when the heat
  /// changed nothing or there is no weather.
  double? get vo2Adjusted {
    final h = heat;
    if (h == null || !h.adjusts || !valid) return null;
    return CooperProjection.vo2(h.distance(testDistanceM)!);
  }

  /// "Heat-adjusted estimate 52.8 · 22 °C, dew point 14", or the too-hot
  /// line; null without weather or when the heat changed nothing.
  String? get heatLine => valid ? heat?.line(vo2Adjusted) : null;

  /// Why there is no estimate, as the result screen says it.
  String? get invalidLine => switch (invalid) {
    CooperInvalid.paused => 'Paused during the test, so there is no estimate.',
    CooperInvalid.short => 'Stopped before 12:00, so there is no estimate.',
    CooperInvalid.indoor => 'No GPS, so there is no estimate.',
    CooperInvalid.noisy => 'GPS was too noisy for an estimate.',
    null => null,
  };

  /// Under every result (v1 plan §18.4).
  static const String disclaimer = 'Estimate. Not a medical measurement.';

  /// "How this is estimated" (§18.4, Phase 4 §3.3). Every sentence with a
  /// number says it is an estimate or research-based.
  static const List<String> method = [
    'The estimate comes from how far you ran in 12 minutes, using '
        "Cooper's 1968 formula: (metres minus 504.9) divided by 44.73.",
    'In studies the 12-minute run tracks lab VO2 max fairly well, but '
        'any one person can be a few points off, so the likely range is '
        'about 5 either way (research-based).',
    'GPS distance can be about 2% out, which is part of that range.',
    'A pause, or stopping before 12:00, gives no estimate.',
  ];

  /// "VO2 est. +1.4 since June": this estimate against the previous valid
  /// test, shown only with at least two prior tests (Phase 4 §3.3).
  /// [prior] holds the earlier valid tests (date, raw VO2), oldest first.
  static String? changeLine(
    double vo2,
    DateTime date,
    List<(DateTime, double)> prior,
  ) {
    if (prior.length < 2) return null;
    final (prevDate, prevVo2) = prior.last;
    final d = vo2 - prevVo2;
    final sign = d >= 0 ? '+' : '-';
    final when = prevDate.year == date.year && prevDate.month == date.month
        ? '${prevDate.day} ${_months[prevDate.month - 1]}'
        : _longMonths[prevDate.month - 1];
    return 'VO2 est. $sign${d.abs().toStringAsFixed(1)} since $when';
  }

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const List<String> _longMonths = [
    'January', 'February', 'March', 'April', 'May', 'June', //
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
}
