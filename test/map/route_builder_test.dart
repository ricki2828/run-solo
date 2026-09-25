import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/map/route_builder.dart';

import '../run_fixtures.dart';

void main() {
  final start = DateTime.utc(2026, 9, 20, 6);

  test('4x4: accepted samples only, work / recovery markers, bounds', () {
    final run = fourByFourFile(n: 1, start: start);
    final analysis = const engine.RunEngine().analyze(run);
    final g = RouteBuilder.build(run, detection: analysis.detection);
    expect(g.isEmpty, isFalse);
    expect(g.points.length, lessThanOrEqualTo(run.samples.length));
    expect(g.markers.first.kind, RouteMarkerKind.start);
    expect(g.markers.last.kind, RouteMarkerKind.finish);
    final work = g.markers
        .where((m) => m.kind == RouteMarkerKind.work)
        .toList();
    expect(work.map((m) => m.label).toList(), ['1', '2', '3', '4']);
    expect(
      g.markers.where((m) => m.kind == RouteMarkerKind.recovery).length,
      4,
    );
    final b = g.bounds!;
    expect(b.north, greaterThanOrEqualTo(b.south));
    expect(b.east, greaterThanOrEqualTo(b.west));
    for (final p in g.points) {
      expect(p.lat, inInclusiveRange(b.south, b.north));
      expect(p.lon, inInclusiveRange(b.west, b.east));
    }
  });

  test('laps run: numbered lap markers', () {
    final run = lapsRunFile(n: 2, start: start);
    final g = RouteBuilder.build(run);
    final laps = g.markers.where((m) => m.kind == RouteMarkerKind.lap).toList();
    expect(laps.map((m) => m.label).toList(), ['1', '2', '3']);
  });

  test('samples above 25 m accuracy are dropped', () {
    final run = freeRunFile(n: 3, start: start, hr: false);
    final noisy = run.copyWith(
      samples: [
        for (var i = 0; i < run.samples.length; i++)
          i.isEven ? run.samples[i].copyWith(accM: 40.0) : run.samples[i],
      ],
    );
    final g = RouteBuilder.build(noisy);
    expect(g.points.length, run.samples.length ~/ 2);
  });

  test('indoor (no fix): empty geometry, no bounds', () {
    final run = fourByFourFile(n: 4, start: start, indoor: true);
    final g = RouteBuilder.build(run);
    expect(g.isEmpty, isTrue);
    expect(g.bounds, isNull);
    expect(g.markers, isEmpty);
  });

  test('a still route still gets an area to fit', () {
    final b = RouteBuilder.boundsOf(const [
      GeoPoint(-33.86, 151.21),
      GeoPoint(-33.86, 151.21),
    ]);
    expect(b.north - b.south, greaterThan(0));
    expect(b.east - b.west, greaterThan(0));
  });
}
