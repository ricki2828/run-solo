import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test('a cool day has no line', () {
    expect(
      TodayTarget.of(tempC: 12, dewPointC: 6, aimTrueSecPerKm: 310),
      isNull,
    );
  });

  test('28 C, dew point 21 C: about 4.7% slower, actual pace is slower', () {
    final t = TodayTarget.of(tempC: 28, dewPointC: 21, aimTrueSecPerKm: 310)!;
    expect(t.fraction, closeTo(0.047, 0.0005));
    expect(t.actualSecPerKm, closeTo(310 / (1 - t.fraction!), 1e-9));
    expect(t.actualSecPerKm, greaterThan(310));
    expect(t.word, 'Warm');
  });

  test('wording steps up with the slowdown', () {
    String w(double temp, double dew) =>
        TodayTarget.of(tempC: temp, dewPointC: dew, aimTrueSecPerKm: 300)!.word;
    expect(w(24, 15), 'Warm');
    expect(w(30, 24), 'Hot');
    expect(w(34, 27), 'Very hot');
  });

  test('too hot to compare has no actual pace', () {
    final t = TodayTarget.of(tempC: 45, dewPointC: 30, aimTrueSecPerKm: 300)!;
    expect(t.tooHot, isTrue);
    expect(t.actualSecPerKm, isNull);
    expect(t.word, 'Very hot');
  });
}
