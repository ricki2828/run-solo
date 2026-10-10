import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The shared Dart/Kotlin vectors (core-jvm RetraceParityTest replays the
/// same file): every field of every state, to 0.5 m. Regenerate only with
/// `dart run tool/gen_retrace_vectors.dart` after a deliberate change to
/// both detectors.
void main() {
  test('the detector reproduces every state in the shared vectors', () {
    final doc = jsonDecode(
      File('test/fixtures/retrace/vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final vectors = doc['vectors'] as List;
    expect(vectors.length, greaterThanOrEqualTo(4));
    var retracing = 0;
    for (final v in vectors.cast<Map<String, dynamic>>()) {
      final name = v['name'] as String;
      final points = v['points'] as List;
      final states = v['states'] as List;
      expect(states.length, points.length, reason: name);
      final d = RetraceDetector();
      for (var i = 0; i < points.length; i++) {
        final p = points[i] as List;
        final s = d.add(
          lat: (p[0] as num).toDouble(),
          lon: (p[1] as num).toDouble(),
          elevM: (p[2] as num?)?.toDouble(),
          distM: p.length > 3 ? (p[3] as num?)?.toDouble() : null,
        );
        final e = states[i] as List;
        final at = '$name #$i';
        expect(s.retracing, e[0], reason: '$at retracing');
        expect(s.direction?.name, e[1], reason: '$at direction');
        void near(String f, Object? want, double? got) {
          if (want == null) {
            expect(got, isNull, reason: '$at $f');
          } else {
            expect(got, isNotNull, reason: '$at $f');
            expect(
              got,
              closeTo((want as num).toDouble(), 0.5),
              reason: '$at $f',
            );
          }
        }

        near('distanceToStartM', e[2], s.distanceToStartM);
        near('climbAheadM', e[3], s.climbAheadM);
        near('descentAheadM', e[4], s.descentAheadM);
        near('heightVsStartM', e[5], s.heightVsStartM);
        if (s.retracing) retracing++;
      }
    }
    expect(retracing, greaterThan(100));
  });
}
