import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/live_route.dart';

void main() {
  test('elevations follow the points; old payloads (no elevM) give nulls', () {
    final r = LiveRouteTrack();
    expect(r.apply(0, [1, 2, 3, 4], [10.5, null]), isTrue);
    expect(r.elevations, [10.5, null]);
    // A delta from the old shape: no elevM at all.
    expect(r.apply(2, [5, 6]), isTrue);
    expect(r.elevations, [10.5, null, null]);
    // Overlap skips the points already held, elevations stay aligned.
    expect(r.apply(2, [5, 6, 7, 8], [99, 12.0]), isTrue);
    expect(r.count, 4);
    expect(r.elevations, [10.5, null, null, 12.0]);
    expect(r.elevations.length, r.points.length);
    r.clear();
    expect(r.elevations, isEmpty);
  });
}
