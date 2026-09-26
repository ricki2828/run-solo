import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/widgets/vo2_trend.dart';

/// CO2 bars (A11 rules, compact): the cropped baseline and which bar is
/// the best.
void main() {
  test('baseline: 10% of the shown range below the lowest, whole VO2', () {
    expect(Vo2Bars.baselineOf([50, 52, 60]), 49); // 50 - 1.0
    expect(Vo2Bars.baselineOf([40, 60]), 38); // 40 - 2.0
    expect(Vo2Bars.baselineOf([51.3, 51.3]), 50); // flat: at least 1 below
  });

  test('best: the first bar at the best, none when the best is older', () {
    expect(const Vo2Bars(values: [50, 55, 55], best: 55).bestIndex, 1);
    expect(const Vo2Bars(values: [50, 52], best: 58).bestIndex, isNull);
    expect(Vo2Bars.maxBars, 10);
  });
}
