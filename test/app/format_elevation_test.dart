import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/format.dart';
import 'package:run_solo/platform/gateway.dart';

void main() {
  test('elevation: metres with km, feet with miles, -- without a value', () {
    expect(Fmt.elevation(124.4, Units.km), '124 m');
    expect(Fmt.elevation(0, Units.km), '0 m');
    expect(Fmt.elevation(100, Units.mi), '328 ft');
    expect(Fmt.elevation(null, Units.km), '--');
  });

  test('grade: signed whole percent, never -0%', () {
    expect(Fmt.grade(3.2), '+3%');
    expect(Fmt.grade(-2.4), '-2%');
    expect(Fmt.grade(0.4), '0%');
    expect(Fmt.grade(-0.4), '0%');
    expect(Fmt.grade(null), '--');
  });
}
