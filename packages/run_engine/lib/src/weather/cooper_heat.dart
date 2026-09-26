import 'dart:math' as math;

import 'heat_model.dart';
import 'weather.dart';

/// Heat and humidity for a Cooper 12-minute test (Phase 4 HV1, plan §3.3).
///
/// The Hadley table (§18.5, [HeatModel]) is built for steady runs and
/// over-corrects a 12-minute maximal effort, so the Cooper uses the
/// Mantzios et al. 2022 per-discipline slope for 5000 m instead: about
/// 0.3% per °C WBGT above 15 °C WBGT, capped at 3% (reached at WBGT 25 °C).
/// Never a cold bonus. When the Hadley table says "too hot to compare"
/// there is no adjustment at all.
///
/// Sources (RV4 C6, plan §4 R3):
/// - The slope and the 15 °C optimum are **verified** from the full text,
///   and the optimum is the 5000 m's own (Fig. S12), not a cross-event
///   average. Carrying it over to a 12-minute test is needs verification.
/// - Mantzios computed full outdoor WBGT with sun (Liljegren), so the
///   blend below aims at the same quantity.
/// - Mantzios analysed elite and well-trained racers. Slower runners are
///   hit harder by heat (Ely 2007), so this probably under-corrects for
///   most people: the conservative side for a VO2 bonus.
///
/// Open-Meteo gives no WBGT, so it is estimated from the hour's air, dew
/// point, sun and wind (WARN-10, plan v2.2): a no-sun estimate
/// `WBGT_0 = 0.7·Tw + 0.3·T` blended towards the Australian Bureau of
/// Meteorology approximation `WBGT_bom = 0.567·T + 0.393·e + 3.94` by
/// `w = w_sun · w_wind`, so two near-identical mornings never get visibly
/// different lines (no hard switch).
/// - BoM: formula and bias **verified** on the BoM page (it assumes a
///   moderately high radiation level in light wind, and reads high when
///   cloudy or windy, at night and early morning).
/// - `Tw` is Stull 2011's wet bulb (primary not readable, needs
///   verification). It is the psychrometric wet bulb, which reads a
///   little below WBGT's natural wet bulb in sun or still air, so the
///   no-sun branch errs low.
/// - The 0.7 / 0.3 weights are ISO 7243's indoor form with the globe
///   temperature taken as the air temperature, not Stull's.
///
/// Still needs verification: the blend bands and their linear shape, and
/// the 3% cap (health-endurance signed off the approach and the cap
/// 26-Sep). The adjusted value is always a separate "heat-adjusted
/// estimate" line; the raw VO2 stays the headline, board value, trend and
/// rank.
abstract final class CooperHeat {
  /// Mantzios 2022, 5000 m: fraction per °C WBGT above [optimumTopC].
  static const double slopePerC = 0.003;
  static const double optimumTopC = 15;
  static const double cap = 0.03;

  /// Sun band (W/m²): no BoM weight at or below the low edge, full at or
  /// above the high edge, linear between.
  /// Open-Meteo `shortwave_radiation` is the mean over the preceding hour,
  /// so it lags at sunrise: a dawn run reads less sun than it had. That
  /// errs towards the no-sun estimate, the conservative side.
  static const double sunLowWm2 = 150;
  static const double sunHighWm2 = 350;

  /// Wind band (10 m, m/s): full BoM weight at or below the low edge, none
  /// at or above the high edge, linear between.
  static const double windLowMs = 2;
  static const double windHighMs = 6;

  /// Disclosure under the heat line (plan §3.3).
  static const String disclosure =
      'Heat estimate from temperature, humidity, sun and wind. It can be off '
      'on patchy-cloud days.';

  /// ⓘ copy under the heat line (plan §3.3, Science 6).
  static const String caveat =
      'Based on 5K race data in the heat. It may not fit a 12-minute test '
      'exactly, so treat it as a rough estimate.';

  /// Replaces the heat line above the Hadley "too hot" edge.
  static const String tooHotLine = 'Too hot to compare, raw only';

  /// The adjustment for a run's weather; null unless the weather is `ok`.
  static CooperHeatAdjustment? of(WeatherRecord? w) {
    if (w == null || !w.isOk || w.tempC == null || w.dewPointC == null) {
      return null;
    }
    return adjust(
      tempC: w.tempC!,
      dewPointC: w.dewPointC!,
      shortwaveWm2: w.shortwaveWm2,
      windMs: w.windMs,
    );
  }

  /// `cooperAdjust()` of the plan: the blended WBGT, then
  /// `adj = min(0.003 × max(0, WBGT − 15), 0.03)`. Nothing is rounded here
  /// (P3-b: round only at display).
  static CooperHeatAdjustment adjust({
    required double tempC,
    required double dewPointC,
    double? shortwaveWm2,
    double? windMs,
  }) {
    final w = bomWeight(shortwaveWm2: shortwaveWm2, windMs: windMs);
    final noSun = wbgtNoSun(tempC, dewPointC);
    final bom = wbgtBom(tempC, dewPointC);
    final wbgt = noSun + w * (bom - noSun);
    final tooHot = HeatModel.of(tempC: tempC, dewPointC: dewPointC).tooHot;
    return CooperHeatAdjustment._(
      tempC: tempC,
      dewPointC: dewPointC,
      bomWeight: w,
      wbgtNoSunC: noSun,
      wbgtBomC: bom,
      wbgtC: wbgt,
      fraction: tooHot ? null : fractionForWbgt(wbgt),
    );
  }

  /// The slope with its floor (never a cold bonus) and its cap.
  static double fractionForWbgt(double wbgtC) =>
      math.min(slopePerC * math.max(0, wbgtC - optimumTopC), cap);

  /// `w = w_sun · w_wind`, each clamped to 0–1. Missing sun or wind
  /// gives 0 (no-sun estimate).
  static double bomWeight({double? shortwaveWm2, double? windMs}) {
    if (shortwaveWm2 == null || windMs == null) return 0;
    final sun = ((shortwaveWm2 - sunLowWm2) / (sunHighWm2 - sunLowWm2)).clamp(
      0.0,
      1.0,
    );
    final still = ((windHighMs - windMs) / (windHighMs - windLowMs)).clamp(
      0.0,
      1.0,
    );
    return sun * still;
  }

  /// Saturation vapour pressure (hPa), Magnus with the Alduchov & Eskridge
  /// coefficients (the same as [HeatModel.dewPointFromRh]).
  /// Deliberate: BoM fitted its WBGT with (6.105, 17.27, 237.7); the
  /// difference is under 0.01 °C WBGT across the running range, and one
  /// Magnus form keeps the dew point and both WBGT branches consistent.
  static double vapourPressureHpa(double tempC) =>
      6.1094 * math.exp(17.625 * tempC / (243.04 + tempC));

  /// BoM: `0.567·T + 0.393·e + 3.94`, e the actual vapour pressure (the
  /// saturation pressure at the dew point).
  static double wbgtBom(double tempC, double dewPointC) =>
      0.567 * tempC + 0.393 * vapourPressureHpa(dewPointC) + 3.94;

  /// No sun: `0.7·Tw + 0.3·T`. Relative humidity comes from the same air
  /// and dew point as the BoM branch, so both read one input pair.
  static double wbgtNoSun(double tempC, double dewPointC) {
    final rh = (100 * vapourPressureHpa(dewPointC) / vapourPressureHpa(tempC))
        .clamp(1.0, 100.0);
    return 0.7 * wetBulbStull(tempC, rh) + 0.3 * tempC;
  }

  /// Stull 2011 wet bulb (°C) from air temperature and relative humidity
  /// (%); stated good to about ±1 °C for RH 5–99% and −20 to 50 °C.
  static double wetBulbStull(double tempC, double rhPercent) {
    final t = tempC;
    final rh = rhPercent;
    return t * math.atan(0.151977 * math.sqrt(rh + 8.313659)) +
        math.atan(t + rh) -
        math.atan(rh - 1.676331) +
        0.00391838 * math.pow(rh, 1.5) * math.atan(0.023101 * rh) -
        4.686035;
  }
}

/// One Cooper test's heat adjustment. [fraction] null = too hot to compare.
class CooperHeatAdjustment {
  const CooperHeatAdjustment._({
    required this.tempC,
    required this.dewPointC,
    required this.bomWeight,
    required this.wbgtNoSunC,
    required this.wbgtBomC,
    required this.wbgtC,
    required this.fraction,
  });

  final double tempC;
  final double dewPointC;

  /// 0 = no-sun estimate only, 1 = BoM only.
  final double bomWeight;
  final double wbgtNoSunC;
  final double wbgtBomC;

  /// The blended estimate the slope is applied to.
  final double wbgtC;
  final double? fraction;

  bool get tooHot => fraction == null;

  /// True when the heat changed the result (worth a line of its own).
  bool get adjusts => fraction != null && fraction! > 0;

  /// The 12-minute distance cool conditions would have given,
  /// `distance / (1 − adj)`; the Cooper formula then turns it into the
  /// heat-adjusted VO2 estimate.
  double? distance(double metres) =>
      fraction == null ? null : metres / (1 - fraction!);

  /// "Heat-adjusted estimate 52.8 · 22 °C, dew point 14" under the raw
  /// VO2; the too-hot copy above the Hadley edge; null when the heat did
  /// not change anything. [vo2Adjusted] is the Cooper formula applied to
  /// [distance].
  String? line(double? vo2Adjusted) {
    if (tooHot) return CooperHeat.tooHotLine;
    if (!adjusts || vo2Adjusted == null) return null;
    return 'Heat-adjusted estimate ${vo2Adjusted.toStringAsFixed(1)} · '
        '${tempC.round()} °C, dew point ${dewPointC.round()}';
  }
}
