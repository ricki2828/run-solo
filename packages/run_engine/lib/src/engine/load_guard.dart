import 'dart:math' as math;

import 'block_plan.dart';

/// "Don't overdo it": a plain check of this week against the runner's usual.
/// Pure maths and wording; the app decides where to show it. It never blocks
/// a run and never claims more than the numbers say.
///
/// Load is moving minutes times an intensity weight from 1 (very easy) to 5
/// (very hard), the same idea as Edwards' zone-weighted training load. The
/// weight comes from average heart rate against max HR when the run has a
/// strap, otherwise from True Pace against the runner's threshold estimate.

/// One finished run, reduced to what the load check needs.
class LoadRun {
  const LoadRun({
    required this.start,
    required this.movingMin,
    required this.distanceM,
    this.truePaceSecPerKm,
    this.workTruePaceSecPerKm,
    this.isIntervals = false,
    this.avgHr,
    this.hrCoverage,
  });
  final DateTime start;
  final double movingMin;
  final double distanceM;
  final double? truePaceSecPerKm;
  final double? workTruePaceSecPerKm;
  final bool isIntervals;
  final double? avgHr;

  /// Share of moving time that had a heart rate, 0 to 1.
  final double? hrCoverage;
}

enum LoadBasis { heartRate, pace, assumed }

enum LoadTrigger { load, distance }

/// Why the check flagged this week.
class LoadFlag {
  const LoadFlag({
    required this.trigger,
    required this.loadRatio,
    required this.distanceRatio,
  });
  final LoadTrigger trigger;

  /// This week's load over the usual week (28-day average).
  final double loadRatio;

  /// This week's distance over the usual week.
  final double distanceRatio;

  /// Well past the line: the plan eases two sessions, not one.
  bool get high => loadRatio >= LoadGuard.highRatio;

  int get easeCount => high ? 2 : 1;

  /// The ratio of the number that tripped the flag.
  double get ratio => trigger == LoadTrigger.load ? loadRatio : distanceRatio;

  /// Whole percent above usual for the number that tripped the flag.
  int get percent => ((ratio - 1) * 100).round();

  /// "15% more than usual", or for a ratio of 1.9 or more a multiple ("about
  /// double your usual", "about 2.5 times your usual"). "115% above" read as
  /// either 2.15x or 1.15x (design review S13). [usual] ends the percent
  /// form, [your] the multiple form.
  String _phrase(String usual, String your) {
    final r = ratio;
    if (r < 1.9) return '$percent% more than $usual';
    if (r < 2.25) return 'about double $your';
    final half = (r * 2).round() / 2;
    final n = half == half.roundToDouble()
        ? '${half.round()}'
        : half.toStringAsFixed(1);
    return 'about $n times $your';
  }

  String get message => trigger == LoadTrigger.load
      ? 'This week is ${_phrase('usual', 'your usual')}. '
            'An easy run today is the safer choice.'
      : 'You are running ${_phrase('your usual week', 'your usual week')} '
            'in distance. An easy run today is the safer choice.';

  /// A short reason for a session the plan eased.
  String get planReason => trigger == LoadTrigger.load
      ? 'This week is ${_phrase('usual', 'your usual')}, so this one is easy.'
      : 'Your distance is ${_phrase('your usual week', 'your usual week')}, '
            'so this one is easy.';
}

enum LoadState { notEnoughData, ok, flagged }

class LoadCheck {
  const LoadCheck({
    required this.state,
    this.acute = 0,
    this.chronicWeekly = 0,
    this.loadRatio,
    this.distanceRatio,
    this.flag,
  });
  final LoadState state;

  /// Load units over the last 7 days.
  final double acute;

  /// Load units in an average week of the last 28 days.
  final double chronicWeekly;
  final double? loadRatio;
  final double? distanceRatio;
  final LoadFlag? flag;
}

abstract final class LoadGuard {
  /// Acute (7 days) over chronic (28 day weekly average), flagged above this.
  static const double loadRatio = 1.3;

  /// Two sessions eased, not one.
  static const double highRatio = 1.5;

  /// This week's distance over the usual week, flagged above this.
  static const double distanceRatio = 1.25;

  static const int acuteDays = 7;
  static const int chronicDays = 28;

  /// Needs this many runs in the 28 days, the oldest at least this old, or
  /// the usual week is not a usual week yet.
  static const int minRuns = 3;
  static const int minHistoryDays = 14;

  /// Below this much load in an average week the ratio is noise.
  static const double minChronicWeekly = 60;

  /// Shown when the runner asks why: the rules, stated.
  static const String rules =
      'We compare your last 7 days with your average week over the last 28. '
      'A warning shows when your training load is more than 30% above it, or '
      'your weekly distance is more than 25% above. Load is time running '
      'weighted by how hard it was (heart rate if you wear a strap, else '
      'pace against your threshold estimate). These lines come from sports '
      'science research on training load and injury (the acute to chronic '
      'workload ratio). They are an estimate and not medical advice, and '
      'Run Supreme never blocks a run.';

  /// Weight 1 to 5 for a minute of this run, and where it came from. The same
  /// slope for heart rate and pace: easy (about 65% of max HR, 0.8 of
  /// threshold pace) is 2, threshold (about 85%, 1.0) is 4.
  static (double, LoadBasis) weight(
    LoadRun r, {
    required double? maxHr,
    required double? vdot,
  }) {
    double clamp(double w) => w.clamp(1.0, 5.0).toDouble();
    final hr = r.avgHr;
    if (hr != null &&
        maxHr != null &&
        maxHr > 0 &&
        (r.hrCoverage ?? 0) >= 0.8) {
      return (clamp(2 + (hr / maxHr - 0.65) * 10), LoadBasis.heartRate);
    }
    double? fromPace(double? pace) {
      final i = BlockPaces.intensity(pace, vdot);
      return i == null ? null : clamp(2 + (i - 0.8) * 10);
    }

    final all = fromPace(r.truePaceSecPerKm);
    if (r.isIntervals) {
      final work = fromPace(r.workTruePaceSecPerKm);
      // About half the time is the work reps, the rest easy jogging.
      if (work != null) return (clamp(0.5 * work + 0.5 * 2), LoadBasis.pace);
    }
    if (all != null) return (all, LoadBasis.pace);
    return (2.5, LoadBasis.assumed);
  }

  static double load(LoadRun r, {double? maxHr, double? vdot}) =>
      r.movingMin * weight(r, maxHr: maxHr, vdot: vdot).$1;

  /// This week against the usual one, as of [now]. [maxHr] and [vdot] size
  /// each run's intensity; either may be null.
  static LoadCheck check(
    List<LoadRun> runs, {
    required DateTime now,
    double? maxHr,
    double? vdot,
  }) {
    final today = dateOnly(now);
    // A "day" is a calendar day, the acute window is today and the 6 before.
    final acuteFrom = addDays(today, -(acuteDays - 1));
    final chronicFrom = addDays(today, -(chronicDays - 1));
    final end = addDays(today, 1);
    final inChronic = [
      for (final r in runs)
        if (!r.start.isBefore(chronicFrom) && r.start.isBefore(end)) r,
    ];
    if (inChronic.length < minRuns) {
      return const LoadCheck(state: LoadState.notEnoughData);
    }
    final oldest = inChronic
        .map((r) => r.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final oldestDay = dateOnly(oldest);
    if (today.difference(oldestDay).inDays < minHistoryDays) {
      return const LoadCheck(state: LoadState.notEnoughData);
    }
    // A returner has no usual week: if any whole week before this one, inside
    // the history, had no run at all, the average would be dragged down by the
    // break and a normal first week back would read as a spike.
    for (var k = 1; ; k++) {
      final from = addDays(acuteFrom, -7 * k);
      if (from.isBefore(oldestDay)) break;
      final to = addDays(from, 7);
      if (!inChronic.any(
        (r) => !r.start.isBefore(from) && r.start.isBefore(to),
      )) {
        return const LoadCheck(state: LoadState.notEnoughData);
      }
    }
    var acute = 0.0, chronic = 0.0, acuteKm = 0.0, chronicKm = 0.0;
    for (final r in inChronic) {
      final l = load(r, maxHr: maxHr, vdot: vdot);
      chronic += l;
      chronicKm += r.distanceM / 1000;
      if (!r.start.isBefore(acuteFrom)) {
        acute += l;
        acuteKm += r.distanceM / 1000;
      }
    }
    // The usual week is averaged over the history there is, up to 4 weeks, so
    // 15 days of steady running reads as steady, not as half a month.
    final historyDays = today.difference(oldestDay).inDays + 1;
    final weeks = math.min(chronicDays / acuteDays, historyDays / acuteDays);
    final chronicWeekly = chronic / weeks;
    if (chronicWeekly < minChronicWeekly || chronicKm <= 0) {
      return LoadCheck(
        state: LoadState.notEnoughData,
        acute: acute,
        chronicWeekly: chronicWeekly,
      );
    }
    final lr = acute / chronicWeekly;
    final dr = acuteKm / (chronicKm / weeks);
    final trigger = lr > loadRatio
        ? LoadTrigger.load
        : dr > distanceRatio
        ? LoadTrigger.distance
        : null;
    return LoadCheck(
      state: trigger == null ? LoadState.ok : LoadState.flagged,
      acute: acute,
      chronicWeekly: chronicWeekly,
      loadRatio: lr,
      distanceRatio: dr,
      flag: trigger == null
          ? null
          : LoadFlag(trigger: trigger, loadRatio: lr, distanceRatio: dr),
    );
  }

  /// The calendar week a dismissal belongs to: the Monday's date, `2026-10-05`.
  static String weekKey(DateTime now) {
    final d = dateOnly(now);
    final monday = addDays(d, -(d.weekday - 1));
    return '${monday.year.toString().padLeft(4, '0')}-'
        '${monday.month.toString().padLeft(2, '0')}-'
        '${monday.day.toString().padLeft(2, '0')}';
  }
}
