import 'dart:math' as math;

import 'package:run_engine/run_engine.dart' as engine;

/// Follow a route: routes for the app tests, drawn from the same start as the
/// fake recorder's scripted track (-33.8688, 151.2093, heading north), so a
/// route and a run share a map.
const double routeLat0 = -33.8688;
const double routeLon0 = 151.2093;

List<engine.RoutePoint> routePoints({
  double lengthM = 3000,
  double stepM = 10,
  double? Function(double distM)? ele,
}) => [
  for (var d = 0.0; d <= lengthM; d += stepM)
    engine.RoutePoint(
      routeLat0 + d / 111320,
      routeLon0 + math.sin(d / 24) * 0.0002,
      ele?.call(d),
    ),
];

/// A saved route 3 km long (about 100 m of climb when [climb] is true).
engine.SavedRoute testRoute({
  String id = 'route-1',
  String name = 'Hill loop',
  double lengthM = 3000,
  bool climb = true,
  engine.RouteSource source = engine.RouteSource.gpx,
}) => engine.RouteBuilder.build(
  id: id,
  name: name,
  raw: routePoints(
    lengthM: lengthM,
    ele: climb ? (d) => 20 + d * lengthM.sign * 100 / lengthM : null,
  ),
  source: source,
  createdAt: DateTime.utc(2026, 10, 1, 8),
);

/// GPX text for a route file the runner picked.
String gpxText({String name = 'Hill loop', double lengthM = 3000}) {
  final b = StringBuffer(
    '<?xml version="1.0"?><gpx version="1.1" creator="test"><rte><name>$name</name>',
  );
  for (final p in routePoints(
    lengthM: lengthM,
    ele: (d) => 20 + d * 100 / lengthM,
  )) {
    b.write('<rtept lat="${p.lat}" lon="${p.lon}"><ele>${p.ele}</ele></rtept>');
  }
  b.write('</rte></gpx>');
  return b.toString();
}
