import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/true_pace_smoother.dart';

void main() {
  final t0 = DateTime(2026, 10, 7, 8);

  test('no value until enough readings, then the mean', () {
    final s = TruePaceSmoother();
    for (var i = 0; i < 4; i++) {
      s.add(t0.add(Duration(seconds: i)), 300);
    }
    expect(s.value(t0.add(const Duration(seconds: 4))), isNull);
    s.add(t0.add(const Duration(seconds: 4)), 290);
    expect(s.value(t0.add(const Duration(seconds: 5))), closeTo(298, 0.001));
  });

  test('readings older than the window drop out; null adds nothing', () {
    final s = TruePaceSmoother();
    for (var i = 0; i < 6; i++) {
      s.add(t0.add(Duration(seconds: i)), 300);
    }
    s.add(t0.add(const Duration(seconds: 6)), null);
    expect(s.value(t0.add(const Duration(seconds: 7))), 300);
    expect(s.value(t0.add(const Duration(seconds: 60))), isNull);
  });

  test('reset starts the window afresh', () {
    final s = TruePaceSmoother();
    for (var i = 0; i < 6; i++) {
      s.add(t0.add(Duration(seconds: i)), 300);
    }
    s.reset();
    expect(s.value(t0.add(const Duration(seconds: 6))), isNull);
  });
}
