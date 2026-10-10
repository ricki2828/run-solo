import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/gradient.dart';
import 'package:run_solo/map/retrace_tracker.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/topo/topo_style.dart';

/// North along a line, 10 m a step.
GeoPoint _at(int i, [double? ele]) =>
    GeoPoint(1.0 + i * 10 / 111320, 103.0, ele);

void main() {
  test('a one-way run has no retraced section', () {
    final t = RetraceTracker();
    t.add([for (var i = 0; i < 80; i++) _at(i)]);
    expect(t.retracing, isFalse);
    expect(t.sections, isEmpty);
  });

  test('out and back opens a retraced section that starts before the flip', () {
    final t = RetraceTracker();
    t.add([for (var i = 0; i < 60; i++) _at(i)]);
    t.add([for (var i = 58; i >= 20; i--) _at(i)]);
    expect(t.retracing, isTrue);
    final s = t.sections.single;
    expect(s.length, greaterThan(10));
    // The tail of the section is where the runner is now.
    expect(s.last, _at(20));
  });

  test('retraceLines drops one-point sections', () {
    final f = TopoStyle.retraceLines(
      [
        [_at(0)],
        [_at(0), _at(1)],
      ],
      rim: const Color(0xFF000000),
      halo: const Color(0xFFFFFFFF),
    );
    expect((f['features'] as List).length, 1);
  });

  group('colours follow the direction you run', () {
    Set<GradientClass> classesAhead(RetraceTracker t) => {
      for (final r in gradientRuns(t.ahead())!) r.cls,
    };

    test(
      'a hill run up on the way out reads as DOWN ahead on the way back',
      () {
        final t = RetraceTracker();
        // Out: +1 m per 10 m (10 %, steep) for 60 points.
        t.add([for (var i = 0; i < 60; i++) _at(i, 100.0 + i)]);
        // Back: down to the 25th point.
        t.add([for (var i = 58; i >= 25; i--) _at(i, 100.0 + i)]);
        expect(t.retracing, isTrue);
        final ahead = t.ahead();
        expect(ahead, isNotEmpty);
        // Ahead is the old track toward the start, in running order: it
        // begins near the runner and ends toward point 0.
        expect(ahead.first.lat, closeTo(_at(25).lat, 3e-4));
        expect(ahead.last.lat, lessThan(ahead.first.lat));
        final cls = classesAhead(t);
        expect(cls, contains(GradientClass.down));
        expect(cls, isNot(contains(GradientClass.steep)));
        expect(cls, isNot(contains(GradientClass.up)));
      },
    );

    test(
      'a descent run on the way out reads as a CLIMB ahead on the way back',
      () {
        final t = RetraceTracker();
        t.add([for (var i = 0; i < 60; i++) _at(i, 300.0 - i)]);
        t.add([for (var i = 58; i >= 25; i--) _at(i, 300.0 - i)]);
        expect(t.retracing, isTrue);
        final cls = classesAhead(t);
        expect(cls, contains(GradientClass.steep));
        expect(cls, isNot(contains(GradientClass.down)));
      },
    );

    test('ahead is empty when not retracing, and capped in length', () {
      final t = RetraceTracker();
      t.add([for (var i = 0; i < 40; i++) _at(i, 100.0 + i)]);
      expect(t.ahead(), isEmpty);
      final long = RetraceTracker();
      long.add([for (var i = 0; i < 400; i++) _at(i, 100.0)]);
      long.add([for (var i = 398; i >= 100; i--) _at(i, 100.0)]);
      final ahead = long.ahead(maxM: 500);
      // 500 m is about 50 points at 10 m.
      expect(ahead.length, lessThan(60));
    });
  });
}
