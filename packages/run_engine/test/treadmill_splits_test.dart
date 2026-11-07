import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test('no marks gives no speeds', () {
    expect(TreadmillSplits.currentMps(const []), isNull);
    expect(TreadmillSplits.averageMps(const []), isNull);
  });

  test('first stretch runs from zero', () {
    // 500 m in 3:00 -> 2.777 m/s -> 10 km/h
    const marks = [TreadmillMark(180000, 500)];
    expect(
      TreadmillSplits.mpsToKmh(TreadmillSplits.currentMps(marks)!),
      closeTo(10, 0.001),
    );
    expect(
      TreadmillSplits.mpsToKmh(TreadmillSplits.averageMps(marks)!),
      closeTo(10, 0.001),
    );
  });

  test('current is the last stretch and average is the whole run', () {
    const marks = [TreadmillMark(180000, 500), TreadmillMark(330000, 1000)];
    // last 500 m in 2:30 -> 12 km/h; average 1000 m in 5:30 -> 10.909 km/h
    expect(
      TreadmillSplits.mpsToKmh(TreadmillSplits.currentMps(marks)!),
      closeTo(12, 0.001),
    );
    expect(
      TreadmillSplits.mpsToKmh(TreadmillSplits.averageMps(marks)!),
      closeTo(10.909, 0.001),
    );
  });

  test('a skipped marker makes one long stretch', () {
    const marks = [TreadmillMark(180000, 500), TreadmillMark(540000, 1500)];
    final s = TreadmillSplits.of(marks);
    expect(s.length, 2);
    expect(s.last.distanceM, 1000);
    expect(s.last.ms, 360000);
    expect(TreadmillSplits.mpsToKmh(s.last.mps!), closeTo(10, 0.001));
  });

  test('miles and pace conversions', () {
    expect(TreadmillSplits.mpsToMph(2.68224), closeTo(6, 0.001));
    expect(TreadmillSplits.secPerKm(1000 / 300), closeTo(300, 0.001));
  });
}
