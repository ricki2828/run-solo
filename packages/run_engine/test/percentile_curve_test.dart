import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  final rows = <String, List<double>>{
    for (final (sex, table) in [
      ('men', FriendFitnessNorms.men),
      ('women', FriendFitnessNorms.women),
    ])
      for (var c = 0; c < 7; c++) '$sex $c': [for (final r in table) r[c]],
  };

  test('tail fit reproduces published points within 2 percentile points', () {
    rows.forEach((name, ys) {
      final curve = PercentileCurve(ys);
      for (final i in [0, 1, 2, 6, 7, 8]) {
        expect(
          (curve.tailPercentileAt(ys[i]) - (10 + 10 * i)).abs(),
          lessThan(2.0),
          reason: '$name point $i',
        );
      }
    });
  });

  test('join is continuous and output is monotonic, capped 1..99', () {
    rows.forEach((name, ys) {
      final curve = PercentileCurve(ys);
      final lo = ys.first, hi = ys.last, span = hi - lo;
      // Just either side of each edge differ by at most one rounding step.
      final inEdge = curve.at(hi)!.percentile;
      final outEdge = curve.at(hi + span * 1e-6)!.percentile;
      expect((outEdge - inEdge).abs(), lessThanOrEqualTo(1), reason: name);
      expect(
        (curve.at(lo)!.percentile - curve.at(lo - span * 1e-6)!.percentile)
            .abs(),
        lessThanOrEqualTo(1),
        reason: name,
      );
      var last = 0;
      for (var y = lo - span; y <= hi + span; y += span / 200) {
        final e = curve.at(y)!;
        expect(e.percentile, inInclusiveRange(1, 99));
        expect(e.percentile, greaterThanOrEqualTo(last), reason: '$name $y');
        expect(e.extrapolated, y < lo || y > hi);
        last = e.percentile;
      }
      expect(curve.at(hi * 3)!.percentile, 99);
      expect(curve.at(lo / 3)!.percentile, 1);
    });
  });

  test('inside the table values are unchanged and not extrapolated', () {
    final curve = PercentileCurve(rows['men 0']!);
    final e = curve.at(46.5)!;
    expect(e.percentile, 50);
    expect(e.extrapolated, isFalse);
    expect(curve.at(double.nan), isNull);
  });

  test('FRIEND: fitter than the 90th row gives >90 and flagged', () {
    final e = FriendFitnessNorms.estimate(62, 25, female: false)!;
    expect(e.extrapolated, isTrue);
    expect(e.percentile, inInclusiveRange(91, 99));
    expect(e.label, 'about ${e.percentile}th');
    final low = FriendFitnessNorms.estimate(20, 25, female: false)!;
    expect(low.extrapolated, isTrue);
    expect(low.percentile, lessThan(10));
  });

  test('race tables: log-normal tail, monotonic in time', () {
    final a = RacePercentileNorms.estimate(
      FitnessHero.vdot(5000, 1300 * 1000),
      IdentityLane.mid,
      '5K',
      female: false,
    )!;
    final b = RacePercentileNorms.estimate(
      FitnessHero.vdot(5000, 1200 * 1000),
      IdentityLane.mid,
      '5K',
      female: false,
    )!;
    expect(a.extrapolated, isTrue);
    expect(a.percentile, inInclusiveRange(91, 99));
    expect(b.percentile, greaterThanOrEqualTo(a.percentile));
    final slow = RacePercentileNorms.estimate(
      FitnessHero.vdot(5000, 3600 * 1000),
      IdentityLane.mid,
      '5K',
      female: false,
    )!;
    expect(slow.extrapolated, isTrue);
    expect(slow.percentile, lessThan(10));
    // Published point inside the range is not flagged.
    expect(
      RacePercentileNorms.estimate(
        FitnessHero.vdot(5000, 1888 * 1000),
        IdentityLane.mid,
        '5K',
        female: false,
      )!.extrapolated,
      isFalse,
    );
    expect(math.log(1300), lessThan(math.log(1406)));
  });
}
