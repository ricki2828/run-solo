import 'package:test/test.dart';
import 'package:run_engine/run_engine.dart';

void main() {
  test('table endpoints, interpolated midpoints and boundaries', () {
    expect(
      FriendFitnessNorms.comparison(46.5, 25, female: false),
      'about 50th',
    );
    expect(FriendFitnessNorms.comparison(36.6, 29, female: true), 'about 50th');
    expect(
      FriendFitnessNorms.comparison(38.35, 35, female: false),
      'about 45th',
    );
    expect(FriendFitnessNorms.comparison(12, 85, female: false), 'below 10th');
    expect(FriendFitnessNorms.comparison(80, 85, female: true), 'above 90th');
    expect(FriendFitnessNorms.comparison(45, 19, female: true), isNull);
    expect(FriendFitnessNorms.comparison(45, 90, female: true), isNull);
  });
}
