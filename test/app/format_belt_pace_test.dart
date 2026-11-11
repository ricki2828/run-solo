import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/format.dart';
import 'package:run_solo/platform/gateway.dart';

void main() {
  test('belt speed shows as min:ss per km', () {
    expect(Fmt.beltPace(12 / 3.6, Units.km), '5:00');
    expect(Fmt.beltPace(10 / 3.6, Units.km), '6:00');
    expect(Fmt.beltPace(11.5 / 3.6, Units.km), '5:13');
  });

  test('miles show min:ss per mile', () {
    expect(Fmt.beltPace(2.68224, Units.mi), '10:00'); // 6 mph
  });

  test('unknown or zero speed is --:--', () {
    expect(Fmt.beltPace(null, Units.km), '--:--');
    expect(Fmt.beltPace(0, Units.km), '--:--');
    expect(Fmt.beltPace(-1, Units.km), '--:--');
    expect(Fmt.beltPace(double.nan, Units.km), '--:--');
  });
}
