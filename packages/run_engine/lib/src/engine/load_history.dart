import 'dart:math' as math;

import 'block_plan.dart';
import 'load_guard.dart';
import 'progress_math.dart';

/// Load by calendar week, month and year, and a finished week set against the
/// runner's usual. The one number is [LoadGuard.load], so the in-week warning
/// and the look back can never disagree. Pure maths and wording; the screens
/// and the Sunday recap decide where to show it.

/// Where this week sits against the usual week. The ratio is never shown as a
/// number, only these words.
enum LoadBand { lighter, usual, stepUp, bigJump }

enum LoadCompareState { ok, firstWeeks, returning }

/// One Monday-to-Sunday week of running, by local date.
class WeekLoad {
  const WeekLoad({
    required this.monday,
    this.load = 0,
    this.km = 0,
    this.minutes = 0,
    this.hardMinutes = 0,
    this.runs = 0,
    this.longestKm = 0,
    this.hrRuns = 0,
    this.zoneShare = const [0, 0, 0, 0, 0],
    this.noHrShare = 0,
    this.basisShare = const {},
    this.paused = false,
    this.beforeStart = false,
    this.partialStart = false,
    this.guardFlagged = false,
    this.current = false,
  });

  /// Local midnight of the Monday.
  final DateTime monday;
  final double load;
  final double km;

  /// Moving minutes.
  final double minutes;

  /// Minutes at zone 4 and 5 (heart rate runs), else half of an interval run,
  /// else 0. An estimate.
  final double hardMinutes;
  final int runs;
  final double longestKm;

  /// Runs whose weight came from the heart rate.
  final int hrRuns;

  /// Share of the week's moving time in zones 1-5 (index 0 is zone 1).
  final List<double> zoneShare;

  /// The rest of the moving time: no heart rate zone data. Zone shares plus
  /// this make 1 (all 0 for an empty week).
  final double noHrShare;

  /// Share of the week's load by where each run's weight came from.
  final Map<LoadBasis, double> basisShare;

  /// The runner's own pause or a coach care week.
  final bool paused;

  /// The week is before the runner's first run.
  final bool beforeStart;

  /// The week of the first run, when that run was after the Monday: a part
  /// week that says nothing about a usual one.
  final bool partialStart;

  /// The in-week warning (`LoadGuard.check`, the load trigger) was up on at
  /// least one day of the week. A big jump is only called when it was, so the
  /// weekly summary and the warning cannot contradict each other.
  final bool guardFlagged;

  /// The week that holds `now`: still being run, never banded.
  final bool current;

  /// Most of the load is a guess (no strap, no pace estimate).
  bool get mostlyAssumed => (basisShare[LoadBasis.assumed] ?? 0) > 0.5;

  /// Sunday of the week.
  DateTime get sunday => addDays(monday, 6);

  /// Eight fixed six-week fixtures for the goldens, oldest first, the last
  /// one the week being looked at (Monday 19 Oct 2026). Each satisfies
  /// `LoadCompare.of(sample(stage))` for the state its name says.
  static List<WeekLoad> sample(LoadSample stage) {
    final first = DateTime(2026, 9, 14);
    DateTime mon(int i) => addDays(first, 7 * i);
    WeekLoad w(
      int i,
      double load, {
      int runs = 4,
      double hard = 40,
      double longest = 12,
      bool paused = false,
      bool before = false,
      bool noHr = false,
      bool assumed = false,
      bool flagged = false,
    }) {
      if (load == 0 && !paused && !before) {
        return WeekLoad(monday: mon(i));
      }
      if (before) return WeekLoad(monday: mon(i), beforeStart: true);
      if (paused) return WeekLoad(monday: mon(i), paused: true);
      return WeekLoad(
        monday: mon(i),
        load: load,
        km: load / 12,
        minutes: load / 2.2,
        hardMinutes: hard,
        runs: runs,
        longestKm: longest,
        hrRuns: noHr ? 0 : runs,
        zoneShare: noHr ? const [0, 0, 0, 0, 0] : const [.1, .45, .3, .12, .03],
        noHrShare: noHr ? 1 : 0,
        basisShare: assumed
            ? const {LoadBasis.assumed: 1.0}
            : noHr
            ? const {LoadBasis.pace: 1.0}
            : const {LoadBasis.heartRate: 1.0},
        guardFlagged: flagged,
      );
    }

    final usual = [w(0, 330), w(1, 340), w(2, 350), w(3, 356)];
    switch (stage) {
      case LoadSample.usual:
        return [...usual, w(4, 350), w(5, 352)];
      case LoadSample.stepup:
        return [...usual, w(4, 350), w(5, 420, hard: 55, longest: 13)];
      case LoadSample.bigjump:
        return [
          ...usual,
          w(4, 350),
          w(5, 520, hard: 80, longest: 18, flagged: true),
        ];
      case LoadSample.lighter:
        return [...usual, w(4, 350), w(5, 240, runs: 3, hard: 15)];
      case LoadSample.first:
        return [
          w(0, 0, before: true),
          w(1, 0, before: true),
          w(2, 0, before: true),
          w(3, 0, before: true),
          w(4, 280, runs: 3, hard: 20, longest: 9),
          w(5, 300, runs: 3, hard: 25, longest: 10),
        ];
      case LoadSample.returning:
        return [
          w(0, 330),
          w(1, 360),
          w(2, 340),
          w(3, 0),
          w(4, 0),
          w(5, 200, runs: 3, hard: 10, longest: 8),
        ];
      case LoadSample.nohr:
        return [
          ...[for (var i = 0; i < 5; i++) w(i, 340 + 5.0 * i, noHr: true)],
          w(5, 350, noHr: true, assumed: true),
        ];
      case LoadSample.paused:
        return [
          w(0, 330),
          w(1, 360),
          w(2, 340),
          w(3, 0, paused: true),
          w(4, 350),
          w(5, 352),
        ];
    }
  }
}

enum LoadSample {
  usual,
  stepup,
  bigjump,
  lighter,
  first,
  returning,
  nohr,
  paused,
}

/// A calendar month or a year's month.
class PeriodLoad {
  const PeriodLoad({
    required this.start,
    this.load = 0,
    this.km = 0,
    this.minutes = 0,
    this.runs = 0,
    this.current = false,
    this.future = false,
    this.beforeStart = false,
    this.partialStart = false,
  });

  /// First day of the month.
  final DateTime start;
  final double load;
  final double km;
  final double minutes;
  final int runs;
  final bool current;

  /// After this month (the year view's hairline stubs).
  final bool future;
  final bool beforeStart;

  /// The month of the first run, when that run was after the 1st.
  final bool partialStart;
}

/// This year by month, with the same stretch of last year for a km line.
class YearLoad {
  const YearLoad({
    required this.months,
    required this.km,
    required this.runs,
    required this.minutes,
    required this.lastYearKm,
    required this.lastYearRuns,
  });

  /// January to December of this year.
  final List<PeriodLoad> months;
  final double km;
  final int runs;
  final double minutes;

  /// Km from 1 Jan to the same date last year.
  final double lastYearKm;
  final int lastYearRuns;

  /// Km this year minus the same stretch of last year; null with no run then.
  double? get kmVsLastYear => lastYearRuns == 0 ? null : km - lastYearKm;
}

/// A finished week set against the mean of the 4 weeks before it.
class LoadCompare {
  const LoadCompare({
    required this.state,
    this.band,
    this.ratio,
    this.pct = 0,
    this.usual = 0,
    this.usualHard = 0,
    this.usualLongestKm = 0,
    this.usualRuns = 0,
    this.usualMin = 0,
    this.afterPause = false,
  });

  final LoadCompareState state;

  /// Null unless [state] is ok.
  final LoadBand? band;

  /// This over usual. For tests and wording; never shown as a number.
  final double? ratio;

  /// Whole percent above (stepUp, bigJump) or below (lighter) usual.
  final int pct;
  final double usual;
  final double usualHard;
  final double usualLongestKm;
  final double usualRuns;
  final double usualMin;

  /// The week or the one before it was a paused week.
  final bool afterPause;

  /// "A week around" this: usual plus 10%, to the nearest 10.
  int get cap => ((usual * 1.1) / 10).round() * 10;

  /// Weeks with runs the usual week needs before any band shows; the copy
  /// says "after 3 weeks of running".
  static const int minWeeks = 3;

  /// Months with runs the usual month needs.
  static const int minMonths = 3;

  static LoadBand bandOf(double ratio) => ratio < 0.8
      ? LoadBand.lighter
      : ratio <= 1.1
      ? LoadBand.usual
      : ratio <= LoadGuard.loadRatio
      ? LoadBand.stepUp
      : LoadBand.bigJump;

  /// [weeks] oldest first, the last the week to judge: a complete week. A
  /// list ending in the current part week is never banded (`firstWeeks`).
  /// Usual is the mean of the up to 4 weeks before it that had runs, leaving
  /// out empty weeks, paused weeks, weeks before the first run and a part
  /// first week. [bandOf] is the pure ratio; here `bigJump` also needs
  /// [WeekLoad.guardFlagged].
  static LoadCompare of(List<WeekLoad> weeks) {
    if (weeks.isEmpty) {
      return const LoadCompare(state: LoadCompareState.firstWeeks);
    }
    final week = weeks.last;
    if (week.current) {
      return const LoadCompare(state: LoadCompareState.firstWeeks);
    }
    final prior = weeks.sublist(
      math.max(0, weeks.length - 5),
      weeks.length - 1,
    );
    final afterPause = week.paused || (prior.isNotEmpty && prior.last.paused);
    // The 2 or more weeks straight before were empty and unpaused: a first
    // week back has no usual (the guard's returner rule).
    bool rest(WeekLoad w) => w.runs == 0 && !w.paused && !w.beforeStart;
    if (week.runs > 0 &&
        prior.length >= 2 &&
        rest(prior[prior.length - 1]) &&
        rest(prior[prior.length - 2])) {
      return LoadCompare(
        state: LoadCompareState.returning,
        afterPause: afterPause,
      );
    }
    final counted = [
      for (final w in prior)
        // An empty week is not a usual week: one rest week (sick, travel)
        // must not drag the usual down and make a normal week a jump.
        if (!w.paused && !w.beforeStart && !w.partialStart && w.runs > 0) w,
    ];
    final withRuns = counted.length;
    double mean(double Function(WeekLoad) f) => counted.isEmpty
        ? 0
        : counted.fold(0.0, (a, w) => a + f(w)) / counted.length;
    final usual = mean((w) => w.load);
    if (withRuns < minWeeks || usual < LoadGuard.minChronicWeekly) {
      return LoadCompare(
        state: LoadCompareState.firstWeeks,
        usual: usual,
        afterPause: afterPause,
      );
    }
    final ratio = week.load / usual;
    // Amber only when the in-week warning agrees; else it is a step up.
    var band = bandOf(ratio);
    if (band == LoadBand.bigJump && !week.guardFlagged) band = LoadBand.stepUp;
    final pct = band == LoadBand.lighter
        ? ((1 - ratio) * 100).round()
        : ((ratio - 1) * 100).round();
    return LoadCompare(
      state: LoadCompareState.ok,
      band: band,
      ratio: ratio,
      pct: pct,
      usual: usual,
      usualHard: mean((w) => w.hardMinutes),
      usualLongestKm: mean((w) => w.longestKm),
      usualRuns: mean((w) => w.runs.toDouble()),
      usualMin: mean((w) => w.minutes),
      afterPause: afterPause,
    );
  }

  /// A complete month against the mean of the up to 3 months before it
  /// (months before the first run left out). Only band, pct and usual are set.
  static LoadCompare months(List<PeriodLoad> months) {
    if (months.isEmpty) {
      return const LoadCompare(state: LoadCompareState.firstWeeks);
    }
    final m = months.last;
    final prior = months
        .sublist(math.max(0, months.length - 4), months.length - 1)
        .where((p) => !p.beforeStart && !p.partialStart)
        .toList();
    final withRuns = prior.where((p) => p.runs > 0).length;
    final usual = prior.isEmpty
        ? 0.0
        : prior.fold(0.0, (a, p) => a + p.load) / prior.length;
    if (withRuns < minMonths || usual < LoadGuard.minChronicWeekly * 4) {
      return LoadCompare(state: LoadCompareState.firstWeeks, usual: usual);
    }
    final ratio = m.load / usual;
    final band = bandOf(ratio);
    return LoadCompare(
      state: LoadCompareState.ok,
      band: band,
      ratio: ratio,
      pct: band == LoadBand.lighter
          ? ((1 - ratio) * 100).round()
          : ((ratio - 1) * 100).round(),
      usual: usual,
    );
  }
}

abstract final class LoadHistory {
  static DateTime _monday(DateTime d) {
    final day = dateOnly(d);
    return addDays(day, -(day.weekday - 1));
  }

  static DateTime? _firstDay(List<LoadRun> runs) {
    DateTime? first;
    for (final r in runs) {
      if (first == null || r.start.isBefore(first)) first = r.start;
    }
    return first == null ? null : dateOnly(first);
  }

  /// The [weeks] calendar weeks ending with the one that holds [now], oldest
  /// first. A week is the local dates Monday to Sunday, the rule of the weekly
  /// story. [pausedWeeks] are `ProgressMath.weekIndex` values.
  static List<WeekLoad> weeks(
    List<LoadRun> runs, {
    required DateTime now,
    double? maxHr,
    double? vdot,
    int weeks = 6,
    Set<int> pausedWeeks = const {},
  }) {
    final thisMonday = _monday(now);
    final first = _firstDay(runs);
    final firstMonday = first == null ? null : _monday(first);
    final out = <WeekLoad>[];
    for (var i = weeks - 1; i >= 0; i--) {
      final monday = addDays(thisMonday, -7 * i);
      final end = addDays(monday, 7);
      final inWeek = [
        for (final r in runs)
          if (!r.start.isBefore(monday) && r.start.isBefore(end)) r,
      ];
      out.add(
        _week(
          monday,
          inWeek,
          maxHr: maxHr,
          vdot: vdot,
          paused: pausedWeeks.contains(ProgressMath.weekIndex(monday)),
          beforeStart: firstMonday == null || monday.isBefore(firstMonday),
          partialStart:
              first != null && monday == firstMonday && first != firstMonday,
          guardFlagged: _guardFlagged(runs, monday, now, maxHr, vdot),
          current: i == 0,
        ),
      );
    }
    return out;
  }

  static WeekLoad _week(
    DateTime monday,
    List<LoadRun> runs, {
    required double? maxHr,
    required double? vdot,
    required bool paused,
    required bool beforeStart,
    required bool partialStart,
    required bool guardFlagged,
    required bool current,
  }) {
    var load = 0.0, km = 0.0, min = 0.0, hard = 0.0, longest = 0.0;
    var hrRuns = 0;
    var moving = 0.0, noHr = 0.0;
    final zones = List<double>.filled(5, 0);
    final basis = <LoadBasis, double>{};
    for (final r in runs) {
      final (w, b) = LoadGuard.weight(r, maxHr: maxHr, vdot: vdot);
      final l = r.movingMin * w;
      load += l;
      basis[b] = (basis[b] ?? 0) + l;
      if (b == LoadBasis.heartRate) hrRuns++;
      final k = r.distanceM / 1000;
      km += k;
      min += r.movingMin;
      longest = math.max(longest, k);
      final z = r.zoneSec;
      final zTotal = z == null ? 0.0 : z.skip(1).fold(0.0, (a, b) => a + b);
      final movingSec = r.movingMin * 60;
      if (z != null && zTotal > 0) {
        hard += ((z.length > 4 ? z[4] : 0) + (z.length > 5 ? z[5] : 0)) / 60;
        for (var i = 1; i <= 5 && i < z.length; i++) {
          zones[i - 1] += z[i];
        }
        moving += math.max(movingSec, zTotal);
        noHr += math.max(0, movingSec - zTotal);
      } else {
        if (r.isIntervals) hard += 0.5 * r.movingMin;
        moving += movingSec;
        noHr += movingSec;
      }
    }
    return WeekLoad(
      monday: monday,
      load: load,
      km: km,
      minutes: min,
      hardMinutes: hard,
      runs: runs.length,
      longestKm: longest,
      hrRuns: hrRuns,
      zoneShare: [for (final z in zones) moving > 0 ? z / moving : 0.0],
      noHrShare: moving > 0 ? noHr / moving : 0,
      basisShare: {
        if (load > 0)
          for (final e in basis.entries) e.key: e.value / load,
      },
      paused: paused,
      beforeStart: beforeStart,
      partialStart: partialStart,
      guardFlagged: guardFlagged,
      current: current,
    );
  }

  /// The load warning was up (the load trigger, high or very high) on some
  /// day of the week starting [monday], judged as the app judges it each
  /// day. Days after [now] are not judged.
  static bool _guardFlagged(
    List<LoadRun> runs,
    DateTime monday,
    DateTime now,
    double? maxHr,
    double? vdot,
  ) {
    for (var d = 0; d < 7; d++) {
      final day = addDays(monday, d);
      if (day.isAfter(now)) break;
      final c = LoadGuard.check(
        runs,
        now: DateTime(day.year, day.month, day.day, 23, 59),
        maxHr: maxHr,
        vdot: vdot,
      );
      if (c.flag?.trigger == LoadTrigger.load) return true;
    }
    return false;
  }

  /// The [months] calendar months ending with the one that holds [now].
  static List<PeriodLoad> months(
    List<LoadRun> runs, {
    required DateTime now,
    double? maxHr,
    double? vdot,
    int months = 6,
  }) {
    final first = _firstDay(runs);
    final out = <PeriodLoad>[];
    for (var i = months - 1; i >= 0; i--) {
      final start = DateTime(now.year, now.month - i);
      out.add(
        _period(
          runs,
          start,
          DateTime(start.year, start.month + 1),
          maxHr: maxHr,
          vdot: vdot,
          current: i == 0,
          future: false,
          first: first,
        ),
      );
    }
    return out;
  }

  static PeriodLoad _period(
    List<LoadRun> runs,
    DateTime start,
    DateTime end, {
    required double? maxHr,
    required double? vdot,
    required bool current,
    required bool future,
    required DateTime? first,
  }) {
    var load = 0.0, km = 0.0, min = 0.0, n = 0;
    for (final r in runs) {
      if (r.start.isBefore(start) || !r.start.isBefore(end)) continue;
      load += LoadGuard.load(r, maxHr: maxHr, vdot: vdot);
      km += r.distanceM / 1000;
      min += r.movingMin;
      n++;
    }
    return PeriodLoad(
      start: start,
      load: load,
      km: km,
      minutes: min,
      runs: n,
      current: current,
      future: future,
      beforeStart: first == null || !end.isAfter(first),
      partialStart:
          first != null && first.isBefore(end) && first.isAfter(start),
    );
  }

  /// January to December of [now]'s year; the months after [now] are
  /// `future`. [YearLoad.lastYearKm] is 1 Jan to the same date last year.
  static YearLoad year(
    List<LoadRun> runs, {
    required DateTime now,
    double? maxHr,
    double? vdot,
  }) {
    final first = _firstDay(runs);
    final months = <PeriodLoad>[
      for (var m = 1; m <= 12; m++)
        _period(
          runs,
          DateTime(now.year, m),
          DateTime(now.year, m + 1),
          maxHr: maxHr,
          vdot: vdot,
          current: m == now.month,
          future: m > now.month,
          first: first,
        ),
    ];
    final today = dateOnly(now);
    final lastDay = math.min(
      today.day,
      DateTime(now.year, now.month + 1, 0).day,
    );
    // Same date last year; 29 Feb falls back to 28 Feb.
    final lyEnd = addDays(
      DateTime(
        now.year - 1,
        now.month,
        math.min(lastDay, DateTime(now.year - 1, now.month + 1, 0).day),
      ),
      1,
    );
    var lyKm = 0.0, lyRuns = 0;
    for (final r in runs) {
      if (!r.start.isBefore(DateTime(now.year - 1)) &&
          r.start.isBefore(lyEnd)) {
        lyKm += r.distanceM / 1000;
        lyRuns++;
      }
    }
    return YearLoad(
      months: months,
      km: months.fold(0.0, (a, m) => a + m.km),
      runs: months.fold(0, (a, m) => a + m.runs),
      minutes: months.fold(0.0, (a, m) => a + m.minutes),
      lastYearKm: lyKm,
      lastYearRuns: lyRuns,
    );
  }
}

/// The words on the weekly story's load page, the load trends and the
/// Sunday recap.
abstract final class LoadWords {
  static const String explainer =
      'Minutes running x how hard. 40 easy minutes is about 80.';

  static const String noHrNote =
      'Most runs this week had no heart rate or pace estimate, so load is '
      'a rough guess.';

  static String _n(double v) => '${v.round()}';
  static String _km(double v) => v.toStringAsFixed(1);
  static String _runs(int n) => n == 1 ? '1 run' : '$n runs';

  static String headline(WeekLoad w, LoadCompare c) {
    final load = _n(w.load);
    switch (c.state) {
      case LoadCompareState.firstWeeks:
        return '$load load. Your usual week takes shape after 3 weeks of '
            'running.';
      case LoadCompareState.returning:
        return "$load load, your first week back. We'll compare from next "
            'week.';
      case LoadCompareState.ok:
        final u = _n(c.usual);
        switch (c.band!) {
          case LoadBand.usual:
            return '$load load, about your usual week ($u).';
          case LoadBand.lighter:
            return '$load load, ${c.pct}% less than your usual week ($u).';
          case LoadBand.stepUp || LoadBand.bigJump:
            final p = loadVsUsualPhrase(
              c.ratio!,
              'your usual week',
              'your usual week',
            );
            return '$load load, $p ($u).';
        }
    }
  }

  /// What changed; the first rule that fires.
  static String changed(WeekLoad w, LoadCompare c) {
    if (c.state != LoadCompareState.ok) {
      return '${_runs(w.runs)}, ${_n(w.minutes)} minutes, ${_km(w.km)} km.';
    }
    final dh = (w.hardMinutes - c.usualHard).abs();
    if (dh >= 10 && dh >= 0.5 * c.usualHard) {
      return 'Hard minutes: ${_n(w.hardMinutes)}, usual ${_n(c.usualHard)}.';
    }
    if (w.longestKm >= 1.3 * c.usualLongestKm &&
        w.longestKm - c.usualLongestKm >= 3) {
      return 'Longest run ${_km(w.longestKm)} km, usual '
          '${_km(c.usualLongestKm)} km.';
    }
    if ((w.runs - c.usualRuns).abs() >= 1) {
      return '${_runs(w.runs)}, usual ${_n(c.usualRuns)}.';
    }
    return '${_n(w.minutes)} minutes running, usual ${_n(c.usualMin)}.';
  }

  static String suggest(WeekLoad w, LoadCompare c) {
    switch (c.state) {
      case LoadCompareState.firstWeeks:
        return 'Three weeks of running and this compares you with your own usual.';
      case LoadCompareState.returning:
        return 'Building back over two or three weeks would fit.';
      case LoadCompareState.ok:
        switch (c.band!) {
          case LoadBand.bigJump:
            return 'A week around ${c.cap}, with the easy runs easy, would balance it.';
          case LoadBand.stepUp:
            return 'A good step. A similar week next would let it settle before '
                'adding more.';
          case LoadBand.usual:
            return 'Steady. If you feel fresh, 10 more minutes on the long run '
                'would fit.';
          case LoadBand.lighter:
            return c.afterPause
                ? 'A lighter week. Building back over two or three weeks would fit.'
                : 'A lighter week. About ${_n(c.usual)} next week would be a '
                      'return to usual.';
        }
    }
  }

  static String why(WeekLoad w) {
    final hr = w.hrRuns > 0
        ? ' ${w.hrRuns} of ${w.runs} runs this week used your heart rate.'
        : '';
    return 'Load is your running minutes times how hard they were, from 1 '
        '(very easy) to 5 (very hard). We use your heart rate when your '
        'strap covered the run, else your pace against your threshold '
        'estimate. Your usual week is the average of the 4 weeks before, '
        'leaving out paused weeks.$hr It is an estimate, not medical '
        'advice.';
  }

  /// Month view line under the tiles, for a complete month only.
  static String? monthLine(LoadCompare c) {
    if (c.state != LoadCompareState.ok) return null;
    switch (c.band!) {
      case LoadBand.usual:
        return 'About your usual month';
      case LoadBand.lighter:
        return '${c.pct}% less than your usual month';
      case LoadBand.stepUp || LoadBand.bigJump:
        return loadVsUsualPhrase(
          c.ratio!,
          'your usual month',
          'your usual month',
        ).replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
    }
  }

  /// Year view line; null with no run in the same stretch last year.
  static String? yearLine(YearLoad y) {
    final d = y.kmVsLastYear;
    if (d == null) return null;
    if (y.lastYearKm > 0 && d.abs() / y.lastYearKm < 0.05) {
      return 'Level with this time last year';
    }
    final km = d.abs().round();
    return d > 0
        ? '$km km more than this time last year'
        : '$km km less than this time last year';
  }
}
