import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  SavedRoute route({bool ele = true}) => RouteBuilder.build(
    id: 'r1',
    name: 'River loop & back',
    raw: [
      for (var i = 0; i < 40; i++)
        RoutePoint(-33.9 + i * 0.001, 18.4 + i * 0.0005, ele ? 10.0 + i : null),
    ],
    source: RouteSource.gpx,
    createdAt: DateTime.utc(2026, 10, 4),
  );

  test('course GPX re-imports as the same route', () {
    final r = route();
    final text = const GpxCourseExporter().export(r);
    expect(text, contains('<trk>'));
    expect(text, contains('River loop &amp; back'));
    final back = const RouteImporter().fromGpx(text);
    expect(back.name, 'River loop & back');
    expect(back.points.length, r.points.length);
    expect(back.distanceM, closeTo(r.distanceM, 5));
    expect(back.hasElevation, isTrue);
  });

  test('no elevation, no <ele> tags; no times or heart rate ever', () {
    final text = const GpxCourseExporter().export(route(ele: false));
    expect(text, isNot(contains('<ele>')));
    expect(text, isNot(contains('<time>')));
    expect(text, isNot(contains('hr')));
  });
}
