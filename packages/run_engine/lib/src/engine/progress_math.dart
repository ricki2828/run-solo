import 'dart:math' as math;

import 'friend_fitness_norms.dart';
import 'race_percentile_norms.dart';

/// One week in the 8-week strip.
enum StreakWeek {
  /// Ran at least once.
  ran,

  /// Missed, nothing covered it.
  missed,

  /// A freeze covered it.
  frozen,

  /// Paused (ill or sore): neither counts nor breaks, uses no freeze.
  paused,
}

/// A weekly streak worked out from the weeks a runner ran in.
class StreakResult {
  const StreakResult({
    required this.weeks,
    required this.thisWeekDone,
    required this.freezesReady,
    required this.recent,
  });

  final int weeks;
  final bool thisWeekDone;
  final int freezesReady;

  /// The last 8 weeks, oldest first.
  final List<StreakWeek> recent;
}

/// The shape of the age-band pack: 20 bins, slowest first, and the bin the
/// runner sits in.
class PackShape {
  const PackShape({required this.bins, required this.youBin});
  final List<double> bins;
  final int youBin;
}

/// Pure maths behind the Progress redesign (direction B): age grade, the
/// level ladder, the pack histogram and the weekly streak. No I/O, no clock.
abstract final class ProgressMath {
  // ---- Age grade (approximate) -------------------------------------------

  /// Open-class 5K standards, seconds: men 12:35, women 14:11. Rounded
  /// from the world-record-level times the WMA / parkrun age-grading tables
  /// use as their 100% line. Approximate: not the official WMA factor
  /// tables.
  static const double standard5kMaleSec = 755;
  static const double standard5kFemaleSec = 851;

  /// Age at which the age factor starts to fall; up to it the factor is 1.
  static const int peakUntilAge = 34;

  /// Approximate age factor (1 = peak). Up to 34 it is 1; past 34 it falls
  /// as `1 - 0.0065 * d - 0.00008 * d^2` with `d = age - 34`, a quadratic
  /// fitted by eye to the WMA 5K curve (about 0.875 at 50, 0.78 at 60,
  /// 0.66 at 70), floored at 0.4.
  static double ageFactor(int age) {
    if (age <= peakUntilAge) return 1;
    final d = (age - peakUntilAge).toDouble();
    return math.max(0.4, 1 - 0.0065 * d - 0.00008 * d * d);
  }

  /// Parkrun / WMA style age grade, percent, labelled approximate.
  ///
  /// The run-derived [vdot] becomes an equivalent 5K time
  /// ([RacePercentileNorms.equivalentSeconds]); the age grade is
  /// `standard5k / (ageFactor(age) * equivalent5kTime) * 100`, clamped 0..100.
  static double? ageGradePct({
    required double vdot,
    required int age,
    required bool female,
  }) {
    if (age < 5 || age > 110) return null;
    final secs = RacePercentileNorms.equivalentSeconds(vdot, 5000);
    if (secs == null || secs <= 0) return null;
    final std = female ? standard5kFemaleSec : standard5kMaleSec;
    return (std / (ageFactor(age) * secs) * 100).clamp(0.0, 100.0);
  }

  // ---- Level ladder -----------------------------------------------------

  /// Steep-early level from the run count and the fitness reading.
  ///
  /// `runLevel`: one level per run for runs 1..5, then one per 8 runs, to a
  /// cap of 12. `fitLevel`: age grade / 5 (so 58% is 11), scaled by
  /// `min(1, runs / 5)` so a first run cannot jump the ladder. Without an age
  /// grade a coarse proxy of `vdot / 80` stands in. Level = both, clamped
  /// 0..99.
  static int level({required int runs, double? ageGrade, double? vdot}) {
    if (runs <= 0) return 0;
    final runLevel = runs <= 5 ? runs : math.min(12, 5 + (runs - 5) ~/ 8);
    final pct = ageGrade ?? (vdot == null ? 0.0 : vdot / 80 * 100);
    final fit = (pct / 5 * math.min(1.0, runs / 5)).floor();
    return (runLevel + fit).clamp(0, 99);
  }

  /// A level may fall at most one a month: never below `levelMonthAgo - 1`.
  static int smoothedLevel(int raw, int? levelMonthAgo) =>
      levelMonthAgo == null ? raw : math.max(raw, levelMonthAgo - 1);

  // ---- Pack histogram ---------------------------------------------------

  static const int bins = 20;
  static const double _zSpan = 2.5;

  /// "M40-49" / "F30-39" for ages 20..89 (the FRIEND table range); null
  /// outside it.
  static String? band({required int age, required bool female}) {
    if (age < 20 || age > 89) return null;
    final lo = age ~/ 10 * 10;
    return '${female ? 'F' : 'M'}$lo-${lo + 9}';
  }

  /// Percentile 1..99 of [vdot] in the runner's age band (FRIEND 2022).
  static int? percentile({
    required double vdot,
    required int age,
    required bool female,
  }) => FriendFitnessNorms.estimate(vdot, age, female: female)?.percentile;

  /// Histogram of the band: a normal curve over z = -2.5..2.5 in 20 equal
  /// bins (the FRIEND tails are fitted as normal, see PercentileCurve),
  /// heights normalised so the tallest is 1. `youBin` is the bin holding the
  /// runner's [percentile]. It shows the shape of the band, never real
  /// runners.
  static PackShape packShape(int percentile) {
    const w = 2 * _zSpan / bins;
    final raw = [
      for (var i = 0; i < bins; i++)
        math.exp(-0.5 * math.pow(-_zSpan + (i + 0.5) * w, 2)),
    ];
    final top = raw.reduce(math.max);
    final heights = [for (final h in raw) h / top];
    final z = _invCdf(percentile.clamp(1, 99) / 100);
    final you = ((z + _zSpan) / w).floor().clamp(0, bins - 1);
    return PackShape(bins: heights, youBin: you);
  }

  static double _cdf(double z) {
    // Abramowitz and Stegun 7.1.26 erf approximation.
    final x = z.abs() / math.sqrt2;
    final t = 1 / (1 + 0.3275911 * x);
    final poly =
        ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t -
                    0.284496736) *
                t +
            0.254829592) *
        t;
    final y = 1 - poly * math.exp(-x * x);
    return z >= 0 ? 0.5 * (1 + y) : 0.5 * (1 - y);
  }

  static double _invCdf(double p) {
    var lo = -6.0, hi = 6.0;
    for (var i = 0; i < 50; i++) {
      final mid = (lo + hi) / 2;
      if (_cdf(mid) < p) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  // ---- Weeks and the streak ---------------------------------------------

  static final DateTime _epochMonday = DateTime.utc(1970, 1, 5);

  /// Monday-start week number of a local calendar date (only year, month and
  /// day are read, so a shifted wall clock is fine).
  static int weekIndex(DateTime local) =>
      DateTime.utc(
        local.year,
        local.month,
        local.day,
      ).difference(_epochMonday).inDays ~/
      7;

  /// Local midnight of the Monday that starts week [index].
  static DateTime weekStart(int index) => DateTime(1970, 1, 5 + index * 7);

  /// Weeks needed in a row to earn a freeze, and the most that can be held.
  static const int weeksPerFreeze = 4;
  static const int maxFreezes = 2;

  /// The streak over the weeks [ran] (Monday-start indices) up to and
  /// including [current].
  ///
  /// One run in a week keeps it. Every 4th week in a row earns a freeze
  /// (max 2). A single missed week is covered by a freeze automatically
  /// when the next week was run (or is the current one); two misses in a row
  /// end the streak. The current week is never counted as missed while it is
  /// still in progress.
  ///
  /// A [paused] week (ill or sore) neither counts nor breaks: it uses no
  /// freeze, earns toward none, and the streak number and the run of weeks in
  /// a row carry across it. A paused week that was run anyway counts as ran.
  static StreakResult streak(
    Set<int> ran,
    int current, {
    Set<int> paused = const {},
  }) {
    final past = {
      for (final w in ran)
        if (w <= current) w,
    };
    final status = <int, StreakWeek>{};
    var weeks = 0, consecutive = 0, freezes = 0;
    if (past.isNotEmpty) {
      for (var w = past.reduce(math.min); w <= current; w++) {
        if (past.contains(w)) {
          weeks++;
          consecutive++;
          status[w] = StreakWeek.ran;
          if (consecutive % weeksPerFreeze == 0) {
            freezes = math.min(maxFreezes, freezes + 1);
          }
        } else if (paused.contains(w)) {
          status[w] = StreakWeek.paused;
        } else if (w == current) {
          status[w] = StreakWeek.missed;
        } else if (freezes > 0 && _nextCovers(past, paused, w, current)) {
          freezes--;
          status[w] = StreakWeek.frozen;
        } else {
          weeks = 0;
          consecutive = 0;
          status[w] = StreakWeek.missed;
        }
      }
    }
    return StreakResult(
      weeks: weeks,
      thisWeekDone: past.contains(current),
      freezesReady: freezes,
      recent: [
        for (var w = current - 7; w <= current; w++)
          status[w] ??
              (paused.contains(w) ? StreakWeek.paused : StreakWeek.missed),
      ],
    );
  }

  /// A freeze on week [w] holds when the next week that is not paused was
  /// run, or is the current one.
  static bool _nextCovers(Set<int> past, Set<int> paused, int w, int current) {
    var n = w + 1;
    while (n < current && paused.contains(n) && !past.contains(n)) {
      n++;
    }
    return past.contains(n) || n == current;
  }
}
