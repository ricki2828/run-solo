import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  group('week boundaries', () {
    test('Monday starts a week, Sunday ends it', () {
      // 2026-10-05 is a Monday.
      final mon = ProgressMath.weekIndex(DateTime(2026, 10, 5));
      expect(ProgressMath.weekIndex(DateTime(2026, 10, 11, 23, 59)), mon);
      expect(ProgressMath.weekIndex(DateTime(2026, 10, 12)), mon + 1);
      expect(ProgressMath.weekIndex(DateTime(2026, 10, 4)), mon - 1);
      expect(ProgressMath.weekStart(mon), DateTime(2026, 10, 5));
    });

    test('weekStart round-trips across a year end', () {
      final i = ProgressMath.weekIndex(DateTime(2027, 1, 1));
      final s = ProgressMath.weekStart(i);
      expect(s.weekday, DateTime.monday);
      expect(s, DateTime(2026, 12, 28));
    });
  });

  group('streak', () {
    test('no runs: nothing, eight misses', () {
      final s = ProgressMath.streak({}, 100);
      expect(s.weeks, 0);
      expect(s.thisWeekDone, isFalse);
      expect(s.freezesReady, 0);
      expect(s.recent, List.filled(8, false));
    });

    test('current week in progress does not break the streak', () {
      final s = ProgressMath.streak({97, 98, 99}, 100);
      expect(s.weeks, 3);
      expect(s.thisWeekDone, isFalse);
      expect(s.recent.last, isFalse);
    });

    test('a freeze is earned every 4 weeks, max 2', () {
      expect(ProgressMath.streak({1, 2, 3, 4}, 4).freezesReady, 1);
      expect(ProgressMath.streak({1, 2, 3, 4, 5, 6, 7, 8}, 8).freezesReady, 2);
      expect(
        ProgressMath.streak({for (var i = 1; i <= 16; i++) i}, 16).freezesReady,
        2,
      );
    });

    test('a single missed week is frozen, streak survives', () {
      // Weeks 1-4 earn a freeze, week 5 missed, week 6 ran.
      final s = ProgressMath.streak({1, 2, 3, 4, 6}, 6);
      expect(s.weeks, 5);
      expect(s.freezesReady, 0);
      expect(s.recent[7], isTrue);
      expect(s.recent[6], isNull);
    });

    test('a miss with no freeze breaks it', () {
      final s = ProgressMath.streak({1, 2, 4}, 4);
      expect(s.weeks, 1);
      expect(s.recent[6], isFalse);
    });

    test('two missed weeks in a row break it even with a freeze', () {
      final s = ProgressMath.streak({1, 2, 3, 4, 7}, 7);
      expect(s.weeks, 1);
    });

    test('week just missed with a freeze held stays alive in progress', () {
      final s = ProgressMath.streak({1, 2, 3, 4}, 5);
      expect(s.weeks, 4);
      expect(s.thisWeekDone, isFalse);
    });
  });

  group('age grade', () {
    test('open-class standard 5K is 100%', () {
      final v = FitnessHero.vdot(5000, 755000);
      expect(
        ProgressMath.ageGradePct(vdot: v, age: 30, female: false),
        closeTo(100, 0.5),
      );
    });

    test('older age grades higher for the same time', () {
      final v = FitnessHero.vdot(5000, 25 * 60000);
      final a30 = ProgressMath.ageGradePct(vdot: v, age: 30, female: false)!;
      final a50 = ProgressMath.ageGradePct(vdot: v, age: 50, female: false)!;
      expect(a50, greaterThan(a30));
      expect(a30, closeTo(50.3, 1.0));
    });

    test('women are graded against a slower standard', () {
      final v = FitnessHero.vdot(5000, 25 * 60000);
      expect(
        ProgressMath.ageGradePct(vdot: v, age: 40, female: true)!,
        greaterThan(ProgressMath.ageGradePct(vdot: v, age: 40, female: false)!),
      );
    });

    test('age factor falls monotonically', () {
      var prev = 1.0;
      for (var a = 35; a < 90; a++) {
        final f = ProgressMath.ageFactor(a);
        expect(f, lessThanOrEqualTo(prev));
        prev = f;
      }
    });
  });

  group('level', () {
    test('zero runs is level 0', () {
      expect(ProgressMath.level(runs: 0, ageGrade: 50), 0);
    });

    test('rises fast over runs 1 to 5 then slowly', () {
      final l = [
        for (var r = 1; r <= 5; r++) ProgressMath.level(runs: r, ageGrade: 40),
      ];
      expect(l, orderedEquals([...l]..sort()));
      expect(l.last - l.first, greaterThanOrEqualTo(4));
      final l50 = ProgressMath.level(runs: 50, ageGrade: 40);
      expect(l50 - l.last, lessThanOrEqualTo(6));
    });

    test('monotonic in run count and in age grade', () {
      var prev = 0;
      for (var r = 0; r < 120; r++) {
        final x = ProgressMath.level(runs: r, ageGrade: 45);
        expect(x, greaterThanOrEqualTo(prev));
        prev = x;
      }
      prev = 0;
      for (var g = 0; g <= 100; g++) {
        final x = ProgressMath.level(runs: 30, ageGrade: g.toDouble());
        expect(x, greaterThanOrEqualTo(prev));
        prev = x;
      }
    });

    test('never falls more than one a month', () {
      expect(ProgressMath.smoothedLevel(9, 14), 13);
      expect(ProgressMath.smoothedLevel(15, 14), 15);
      expect(ProgressMath.smoothedLevel(9, null), 9);
    });
  });

  group('pack', () {
    test('band labels and range', () {
      expect(ProgressMath.band(age: 44, female: false), 'M40-49');
      expect(ProgressMath.band(age: 31, female: true), 'F30-39');
      expect(ProgressMath.band(age: 19, female: false), isNull);
      expect(ProgressMath.band(age: 90, female: false), isNull);
    });

    test('histogram has 20 bins in 0..1 and youBin tracks percentile', () {
      final lo = ProgressMath.packShape(10);
      final mid = ProgressMath.packShape(50);
      final hi = ProgressMath.packShape(90);
      expect(mid.bins.length, 20);
      expect(mid.bins.reduce((a, b) => a > b ? a : b), closeTo(1, 1e-9));
      expect(mid.bins.every((b) => b >= 0 && b <= 1), isTrue);
      expect(lo.youBin, lessThan(mid.youBin));
      expect(mid.youBin, lessThan(hi.youBin));
      expect([9, 10], contains(mid.youBin));
    });
  });
}
