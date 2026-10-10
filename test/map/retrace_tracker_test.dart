import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/retrace_tracker.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/topo/topo_style.dart';

/// North along a line, 10 m a step.
GeoPoint _at(int i) => GeoPoint(1.0 + i * 10 / 111320, 103.0);

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
    final f = TopoStyle.retraceLines([
      [_at(0)],
      [_at(0), _at(1)],
    ], dash: const Color(0xFF000000));
    expect((f['features'] as List).length, 1);
  });
}
