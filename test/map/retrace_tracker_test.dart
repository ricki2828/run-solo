import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/gradient.dart';
import 'package:run_solo/map/retrace_tracker.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/topo/topo_style.dart';

/// North along a line, 10 m a step.
GeoPoint _at(int i, [double? ele]) =>
    GeoPoint(1.0 + i * 10 / 111320, 103.0, ele);

const _on = RetraceInput(retracing: true);

/// An out-and-back as the recorder would report it: out 0..59, back down to
/// [turn]; the native state flips to retracing 12 points into the way back.
RetraceTracker _outAndBack(
  double Function(int i) ele, {
  int turn = 25,
  bool flip = true,
}) {
  final t = RetraceTracker();
  t.add([for (var i = 0; i < 60; i++) _at(i, ele(i))]);
  final back = [for (var i = 58; i >= turn; i--) _at(i, ele(i))];
  t.add(back.take(12));
  if (flip) t.update(_on);
  t.add(back.skip(12));
  return t;
}

void main() {
  test('a one-way run has no retraced section', () {
    final t = RetraceTracker();
    t.add([for (var i = 0; i < 80; i++) _at(i)]);
    expect(t.retracing, isFalse);
    expect(t.sections, isEmpty);
    expect(t.ahead(), isEmpty);
  });

  test('the map never decides: no native retrace, no section', () {
    final t = _outAndBack((i) => 100.0, flip: false);
    expect(t.retracing, isFalse);
    expect(t.sections, isEmpty);
  });

  test('a native retrace opens a section, backdated, ending at the runner', () {
    final t = _outAndBack((i) => 100.0);
    expect(t.retracing, isTrue);
    final s = t.sections.single;
    // Backdated about 100 m (10 points) before the flip.
    expect(s.length, greaterThan(10 + 20));
    expect(s.last.lat, _at(25).lat);
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

  group('jitter at a turnaround', () {
    test('off and on again within the gap is ONE section', () {
      final t = _outAndBack((i) => 100.0, turn: 40);
      t.update(RetraceInput.none); // native wobbles off
      t.add([_at(39), _at(38)]); // 20 m, under the 30 m gap
      t.update(_on); // and back on
      t.add([_at(37), _at(36)]);
      expect(t.sections.length, 1);
      expect(t.retracing, isTrue);
    });

    test('rapid toggling never produces a flurry of sections', () {
      final t = _outAndBack((i) => 100.0, turn: 45);
      var at = 44;
      for (var k = 0; k < 10; k++) {
        t.update(RetraceInput.none);
        t.add([_at(at--)]);
        t.update(_on);
        t.add([_at(at--)]);
      }
      expect(t.sections.length, 1);
    });

    test('off for longer than the gap closes the section and keeps it', () {
      final t = _outAndBack((i) => 100.0, turn: 40);
      t.update(RetraceInput.none);
      t.add([for (var i = 39; i >= 30; i--) _at(i)]); // 90 m
      expect(t.retracing, isFalse);
      expect(t.sections.length, 1); // closed, still drawn
      expect(t.ahead(), isEmpty);
      // A later retrace is a second section.
      t.update(_on);
      t.add([for (var i = 29; i >= 15; i--) _at(i)]);
      expect(t.sections.length, 2);
    });
  });

  test(
    'the recorder clearing its retrace (20k cap, #232) ends the stretch',
    () {
      final t = _outAndBack((i) => 100.0 + i);
      expect(t.ahead(), isNotEmpty);
      t.update(RetraceInput.none); // native clears retrace at the cap
      t.add([for (var i = 24; i >= 10; i--) _at(i, 100.0 + i)]);
      expect(t.retracing, isFalse);
      expect(t.ahead(), isEmpty);
    },
  );

  test('a long run stays bounded and keeps working', () {
    final t = RetraceTracker(maxPoints: 500);
    t.add([for (var i = 0; i < 5000; i++) _at(i, 100.0 + (i % 50))]);
    expect(t.length, lessThanOrEqualTo(500));
    // Back along the end of the route.
    t.add([for (var i = 4998; i >= 4900; i--) _at(i, 100.0 + (i % 50))]);
    t.update(_on);
    t.add([for (var i = 4899; i >= 4880; i--) _at(i, 100.0 + (i % 50))]);
    expect(t.length, lessThanOrEqualTo(500));
    expect(t.retracing, isTrue);
    expect(t.ahead(), isNotEmpty);
  });

  group('colours follow the direction you run', () {
    Set<GradientClass> classesAhead(RetraceTracker t) => {
      for (final r in gradientRuns(t.ahead())!) r.cls,
    };

    test(
      'a hill run up on the way out reads as DOWN ahead on the way back',
      () {
        final t = _outAndBack((i) => 100.0 + i);
        expect(t.retracing, isTrue);
        final ahead = t.ahead();
        expect(ahead, isNotEmpty);
        // Ahead is the old track toward the start, in running order, from the
        // point nearest the runner.
        expect(ahead.first.lat, closeTo(_at(25).lat, 3e-5));
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
        final t = _outAndBack((i) => 300.0 - i);
        expect(t.retracing, isTrue);
        final cls = classesAhead(t);
        expect(cls, contains(GradientClass.steep));
        expect(cls, isNot(contains(GradientClass.down)));
      },
    );

    test('a lap in the same direction shows the old track as recorded', () {
      final t = RetraceTracker();
      t.add([for (var i = 0; i < 60; i++) _at(i, 100.0 + i)]);
      // Same direction: the runner starts again from the start.
      t.add([for (var i = 0; i < 15; i++) _at(i, 100.0 + i)]);
      t.update(const RetraceInput(retracing: true, same: true));
      t.add([for (var i = 15; i < 25; i++) _at(i, 100.0 + i)]);
      final ahead = t.ahead();
      expect(ahead, isNotEmpty);
      expect(ahead.last.lat, greaterThan(ahead.first.lat));
      final cls = {for (final r in gradientRuns(ahead)!) r.cls};
      expect(cls, contains(GradientClass.steep));
    });

    test('ahead is capped in length', () {
      final t = RetraceTracker();
      t.add([for (var i = 0; i < 400; i++) _at(i, 100.0)]);
      t.add([for (var i = 398; i >= 350; i--) _at(i, 100.0)]);
      t.update(_on);
      t.add([for (var i = 349; i >= 340; i--) _at(i, 100.0)]);
      expect(t.ahead(maxM: 500).length, lessThan(60));
    });
  });

  group('polish', () {
    test('after a shortcut the match finds the right spot, not the window', () {
      // A loop out 0..199 north then back south 199..100 as a parallel line
      // 5 m east; the runner first retraces near 190, then jumps to ~40.
      final t = RetraceTracker();
      GeoPoint east(int i) => GeoPoint(_at(i).lat, 103.0 + 5 / 111320);
      t.add([for (var i = 0; i < 200; i++) _at(i)]);
      t.add([for (var i = 199; i >= 180; i--) east(i)]);
      t.update(_on);
      t.add([for (var i = 179; i >= 170; i--) east(i)]);
      final before = t.ahead();
      expect(before.first.lat, closeTo(_at(170).lat, 1e-4));
      // Shortcut: far along the old line (130 points = 1.3 km away).
      t.add([east(40), east(39)]);
      final after = t.ahead();
      expect(after, isNotEmpty);
      expect(after.first.lat, closeTo(_at(39).lat, 2e-5));
    });

    test('a reopened section does not overlap the closed one', () {
      final t = _outAndBack((i) => 100.0, turn: 40);
      t.update(RetraceInput.none);
      // Well past the gap: the first section closes.
      t.add([for (var i = 39; i >= 36; i--) _at(i)]);
      t.update(_on);
      final closed = t.sections.first;
      t.add([_at(35)]);
      final s = t.sections;
      expect(s.length, 2);
      final closedEndLat = closed.last.lat;
      // Without the clamp it would start ~60 m before the closed end.
      expect(s.last.first.lat, lessThanOrEqualTo(closedEndLat + 1e-9));
    });

    test('repeated thinning keeps old and recent density similar', () {
      final t = RetraceTracker(maxPoints: 200);
      t.add([for (var i = 0; i < 20000; i++) _at(i)]);
      expect(t.length, lessThanOrEqualTo(200));
      // Back along the end of the route, then read the whole old track.
      t.add([for (var i = 19998; i >= 19900; i--) _at(i)]);
      t.update(_on);
      t.add([for (var i = 19899; i >= 19880; i--) _at(i)]);
      final a = t.ahead(maxM: 1e9);
      expect(a.length, greaterThan(20));
      final gaps = [
        for (var i = 1; i < a.length; i++) (a[i - 1].lat - a[i].lat).abs(),
      ];
      final old = gaps.skip(gaps.length - 20).reduce((x, y) => x + y) / 20;
      final recent = gaps.take(20).reduce((x, y) => x + y) / 20;
      expect(old / recent, inInclusiveRange(0.33, 3));
    });
  });
}
