import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/widgets/activity_map.dart';

RouteGeometry _route(List<GeoPoint> pts) =>
    RouteGeometry(points: pts, markers: const [], bounds: null);

void main() {
  test('a route needs two distinct points to be drawn', () {
    expect(routeHasShape(_route(const [])), isFalse);
    expect(routeHasShape(_route(const [GeoPoint(1, 1)])), isFalse);
    expect(
      routeHasShape(_route(const [GeoPoint(1, 1), GeoPoint(1, 1)])),
      isFalse,
    );
    expect(
      routeHasShape(_route(const [GeoPoint(1, 1), GeoPoint(1.001, 1)])),
      isTrue,
    );
  });
}
