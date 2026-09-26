import 'dart:math' as math;

/// Heat and humidity adjustment (v1 plan §18.5), the one model every score
/// uses: interval paces and rep times now, the Cooper VO2 (Phase 3 C1) and
/// the Phase 4 VO2 work later. Humidity enters through the dew point, which
/// is what the table is built on; [dewPointFromRh] covers a source that only
/// gives relative humidity.
///
/// Source: Hadley's temperature + dew point table (both °F, summed;
/// Maximum Performance Running, 2013, popularised by Runners Connect). The
/// table gives a RANGE per band; the adjustment interpolates linearly from a
/// band's low edge to its high edge (plan W1), so it is continuous:
///
/// | sum (°F) | slowdown |
/// |---|---|
/// | ≤ 100 | 0 |
/// | 101–110 | 0–0.5% |
/// | 111–120 | 0.5–1% |
/// | 121–130 | 1–2% |
/// | 131–140 | 2–3% |
/// | 141–150 | 3–4.5% |
/// | 151–160 | 4.5–6% |
/// | 161–170 | 6–8% |
/// | 171–180 | 8–10% |
/// | > 180 | too hot to compare: shown, never adjusted |
///
/// Never a cold bonus. The table is for steady running (4-minute reps are
/// probably less heat-sensitive) and Ely et al. 2007 supports the direction
/// only: both caveats belong in the ⓘ copy.
///
/// The table is the only model for steady runs. A short maximal effort (the
/// Cooper, Phase 4 HV1) uses the Mantzios 2022 5000 m WBGT slope instead
/// and only borrows [HeatAdjustment.tooHot] from here as its cut-off; its
/// inputs (sun and wind at the hour) are stored beside the temperature by
/// `WeatherRecord`.
abstract final class HeatModel {
  /// Sums above this are shown but not adjusted.
  static const double tooHotAboveF = 180;

  /// (sum °F, slowdown fraction) knots; linear between them.
  static const List<(double, double)> _knots = [
    (100, 0),
    (101, 0),
    (110, 0.005),
    (111, 0.005),
    (120, 0.01),
    (121, 0.01),
    (130, 0.02),
    (131, 0.02),
    (140, 0.03),
    (141, 0.03),
    (150, 0.045),
    (151, 0.045),
    (160, 0.06),
    (161, 0.06),
    (170, 0.08),
    (171, 0.08),
    (180, 0.10),
  ];

  static double cToF(double c) => c * 9 / 5 + 32;

  /// Slowdown fraction for a temperature + dew point sum in °F; null above
  /// [tooHotAboveF] ("too hot to compare").
  static double? fractionForSumF(double sumF) {
    if (sumF > tooHotAboveF) return null;
    if (sumF <= _knots.first.$1) return 0;
    for (var i = 1; i < _knots.length; i++) {
      final (x1, y1) = _knots[i];
      if (sumF <= x1) {
        final (x0, y0) = _knots[i - 1];
        return y0 + (y1 - y0) * (sumF - x0) / (x1 - x0);
      }
    }
    return _knots.last.$2;
  }

  static HeatAdjustment of({required double tempC, required double dewPointC}) {
    final sum = cToF(tempC) + cToF(dewPointC);
    return HeatAdjustment._(
      tempC: tempC,
      dewPointC: dewPointC,
      sumF: sum,
      fraction: fractionForSumF(sum),
    );
  }

  /// Dew point (°C) from temperature and relative humidity (%), Magnus
  /// formula (Alduchov & Eskridge coefficients); good to ~0.4 °C in the
  /// running range.
  static double dewPointFromRh(double tempC, double rhPercent) {
    const a = 17.625;
    const b = 243.04;
    final rh = rhPercent.clamp(1, 100) / 100;
    final g = math.log(rh) + a * tempC / (b + tempC);
    return b * g / (a - g);
  }
}

/// One run's heat adjustment. [fraction] is the slowdown the heat caused
/// (0.047 = 4.7%); null when it was too hot to compare.
class HeatAdjustment {
  const HeatAdjustment._({
    required this.tempC,
    required this.dewPointC,
    required this.sumF,
    required this.fraction,
  });

  final double tempC;
  final double dewPointC;
  final double sumF;
  final double? fraction;

  bool get tooHot => fraction == null;
  bool get adjusts => fraction != null && fraction! > 0;

  /// What the pace would have been in cool conditions:
  /// `raw × (1 − adj)` (plan §18.5). Same for a duration (rep time,
  /// finish time).
  double? pace(double secPerKm) =>
      fraction == null ? null : secPerKm * (1 - fraction!);
  double? duration(double seconds) =>
      fraction == null ? null : seconds * (1 - fraction!);

  /// A fixed-time score (Cooper 12 minutes): the distance cool conditions
  /// would have given, `distance / (1 − adj)`, which then feeds the score's
  /// own formula (Cooper VO2 → `vo2_adjusted`).
  double? distance(double metres) =>
      fraction == null ? null : metres / (1 - fraction!);
}
