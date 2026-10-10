import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// At the point cap the detector cannot follow the runner any more, so it
/// must say "not retracing" instead of freezing the last answer.
void main() {
  test('past the 20k-point cap a retrace is cleared, not frozen', () {
    final d = RetraceDetector();
    const mPerDeg = 111320.0;
    RetraceState s = RetraceState.none;
    // Out for 19,900 points (3 m apart), then back along the same line.
    for (var i = 0; i < 19900; i++) {
      s = d.add(lat: i * 3 / mPerDeg, lon: 0, elevM: 100);
    }
    var retracingBeforeCap = false;
    var back = 0;
    while (d.length < RetraceDetector.maxPoints) {
      s = d.add(
        lat: (19899 - back) * 3 / mPerDeg,
        lon: 4 / mPerDeg,
        elevM: 100 + back * 0.1,
      );
      back++;
      if (s.retracing) retracingBeforeCap = true;
    }
    expect(
      retracingBeforeCap,
      isTrue,
      reason: 'the way back was recognised before the cap',
    );
    expect(d.length, RetraceDetector.maxPoints);
    // The next fixes are past the cap.
    for (var i = 0; i < 5; i++) {
      s = d.add(
        lat: (19899 - back) * 3 / mPerDeg,
        lon: 4 / mPerDeg,
        elevM: 100 + back * 0.1,
      );
      back++;
    }
    expect(s.retracing, isFalse);
    expect(s.direction, isNull);
    expect(s.distanceToStartM, isNull);
    expect(s.climbAheadM, isNull);
    expect(s.descentAheadM, isNull);
    // Height vs start still follows.
    expect(s.heightVsStartM, closeTo(100 + (back - 1) * 0.1 - 100, 1e-6));
    expect(d.length, RetraceDetector.maxPoints);
  });
}
