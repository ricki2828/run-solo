import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test('5K and 10K estimates invert fastest-finisher tables', () {
    expect(
      RacePercentileNorms.comparison(
        FitnessHero.vdot(5000, 1888 * 1000),
        IdentityLane.mid,
        '5K',
        female: false,
      ),
      'about 50th',
    );
    expect(
      RacePercentileNorms.comparison(
        FitnessHero.vdot(10000, 4014 * 1000),
        IdentityLane.mid,
        '10K',
        female: true,
      ),
      'about 50th',
    );
  });

  test('half and marathon tables remain distance and sex specific', () {
    expect(
      RacePercentileNorms.comparison(
        FitnessHero.vdot(21097.5, 8643 * 1000),
        IdentityLane.long,
        '15K+ run',
        female: true,
      ),
      'about 50th',
    );
    expect(
      RacePercentileNorms.comparison(
        FitnessHero.vdot(42195, 15269 * 1000),
        IdentityLane.long,
        'Marathon',
        female: false,
      ),
      'about 50th',
    );
  });

  test(
    'outside reference table is a flagged fit and invalid evidence is hidden',
    () {
      expect(
        RacePercentileNorms.comparison(
          100,
          IdentityLane.mid,
          '5K',
          female: false,
        ),
        'about 99th',
      );
      expect(
        RacePercentileNorms.comparison(
          12,
          IdentityLane.long,
          'Marathon',
          female: true,
        ),
        'about 1st',
      );
      expect(
        RacePercentileNorms.comparison(
          45,
          IdentityLane.speed,
          '1K',
          female: true,
        ),
        isNull,
      );
      expect(
        RacePercentileNorms.comparison(
          double.nan,
          IdentityLane.mid,
          '5K',
          female: true,
        ),
        isNull,
      );
    },
  );
}
