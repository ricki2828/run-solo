/// The pure engine behind [buildProgressSnapshot] (direction B "Cohort").
/// Same runs, clock, profile and seen set give the same snapshot; nothing
/// here reads a file, a clock or the network.
///
/// Maths lives in the engine package (`ProgressMath`): age grade, the level
/// ladder, the pack shape and the streak. This file reduces [RunSummary] to
/// what they need and builds the human-facing pieces.
///
/// ## Fitness reading
/// Each run gives a VDOT (Daniels-Gilbert, `FitnessHero.vdot`) as one even
/// effort over its whole distance and time. Runs under 1 km or 6 minutes,
/// Trail runs and non-goal interval sessions are skipped for this (a
/// verdict-grade interval session counts at its work pace over 1 km; a valid
/// Cooper test counts at its VO2 estimate, as the engine's FitnessHero does).
/// The reading is the best in the last 42 days (the engine's window), else
/// the latest one. An easy run reads low, which is why the level shows as
/// calibrating until a hard effort or 5 runs.
///
/// ## The 15 firsts (ids stable, in the order they usually land)
/// first-run, first-1k, first-3k, first-5k, first-10k, first-half,
/// first-30min, first-60min (a single run of that distance or time),
/// first-week (the first Monday-Sunday week with a run, once it is over),
/// two-weeks (two weeks in a row), first-month (four weeks in a row),
/// first-intervals (a non-goal interval session), first-test (a Cooper
/// test), first-trail (a Trail run), first-sub30-5k (a run of 5K or more at
/// an average pace that covers 5K in under 30 minutes).
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../../platform/gateway.dart';
import '../history_store.dart';
import '../progress_snapshot.dart';
import '../settings.dart';

const Duration _kMonth = Duration(days: 28);
const Duration _kRecent = Duration(days: 14);

/// One run reduced to what the progress engine reads.
class ProgressRun {
  ProgressRun(RunSummary s)
    : id = s.id,
      start = s.start,
      local = s.localStart,
      durationMs = s.durationMs,
      distanceM = s.distanceM,
      mode = s.mode,
      isGoal = s.spec?.isGoal == true,
      cooperVo2 = s.cooper?.valid == true
          ? (s.cooper!.vo2Adjusted ?? s.cooper!.vo2)
          : null,
      hardInterval = s.mode == RecordMode.intervals && s.eligibleAsPrior,
      workPaceSecPerKm = s.workPaceSecPerKm,
      parkrunLike = s.isParkrun;

  final String id;
  final DateTime start;

  /// Wall clock where the run happened; only the date fields are read.
  final DateTime local;
  final int durationMs;
  final double distanceM;
  final RecordMode mode;
  final bool isGoal;
  final double? cooperVo2;
  final bool hardInterval;
  final double? workPaceSecPerKm;
  final bool parkrunLike;

  bool get isIntervals => mode == RecordMode.intervals && !isGoal;
  bool get isCooper => mode == RecordMode.cooper || cooperVo2 != null;
  bool get isTrail => mode == RecordMode.trail;
  int get week => engine.ProgressMath.weekIndex(local);

  /// A hard, already-scored effort: the app's own scored lanes.
  bool get isHardEffort => isCooper || hardInterval || parkrunLike;

  double? get vdot {
    if (cooperVo2 != null) return _sane(cooperVo2!);
    if (isTrail) return null;
    if (mode == RecordMode.intervals && !isGoal) {
      final p = workPaceSecPerKm;
      if (!hardInterval || p == null || p <= 0) return null;
      return _sane(engine.FitnessHero.vdot(1000, (p * 1000).round()));
    }
    if (distanceM < 1000 || durationMs < 360000) return null;
    return _sane(engine.FitnessHero.vdot(distanceM, durationMs));
  }

  static double? _sane(double v) => v.isFinite && v >= 15 && v <= 85 ? v : null;
}

/// Fitness (VDOT) as of [asOf] from [runs] (oldest first, all at or before
/// [asOf]): best in the last 42 days, else the latest reading; null if none.
double? fitnessAt(List<ProgressRun> runs, DateTime asOf) {
  final from = asOf.subtract(
    const Duration(days: engine.FitnessHero.windowDays),
  );
  double? best, latest;
  for (final r in runs) {
    final v = r.vdot;
    if (v == null) continue;
    latest = v;
    if (r.start.isAfter(from) && (best == null || v > best)) best = v;
  }
  return best ?? latest;
}

class _Standing {
  const _Standing(
    this.rawLevel,
    this.ageGrade,
    this.vdot,
    this.runs,
    this.hard,
  );
  final int rawLevel;
  final double? ageGrade;
  final double? vdot;
  final int runs;
  final bool hard;
}

int? _ageOf(DateTime at, int? birthYear) =>
    birthYear == null ? null : at.year - birthYear;

_Standing _standing(
  List<ProgressRun> upTo,
  DateTime asOf, {
  required bool? female,
  required int? birthYear,
}) {
  final v = fitnessAt(upTo, asOf);
  final age = _ageOf(asOf, birthYear);
  final grade = v == null || female == null || age == null
      ? null
      : engine.ProgressMath.ageGradePct(vdot: v, age: age, female: female);
  return _Standing(
    engine.ProgressMath.level(runs: upTo.length, ageGrade: grade, vdot: v),
    grade,
    v,
    upTo.length,
    upTo.any((r) => r.isHardEffort),
  );
}

CalibratedLevel buildLevel(
  List<ProgressRun> runs,
  DateTime now, {
  required bool? female,
  required int? birthYear,
}) {
  final cut = now.subtract(_kMonth);
  final nowS = _standing(runs, now, female: female, birthYear: birthYear);
  final past = [
    for (final r in runs)
      if (!r.start.isAfter(cut)) r,
  ];
  final pastS = past.isEmpty
      ? null
      : _standing(past, cut, female: female, birthYear: birthYear);
  final calibrating = !(nowS.hard || nowS.runs >= 5);
  return CalibratedLevel(
    level: engine.ProgressMath.smoothedLevel(nowS.rawLevel, pastS?.rawLevel),
    ageGradePct: nowS.ageGrade,
    calibrating: calibrating,
    runsToSettle: calibrating ? 5 - nowS.runs : 0,
    levelMonthAgo: pastS?.rawLevel,
    ageGradeMonthAgo: pastS?.ageGrade,
  );
}

PackStanding? buildPack(
  List<ProgressRun> runs,
  DateTime now, {
  required bool? female,
  required int? birthYear,
}) {
  if (runs.isEmpty || female == null) return null;
  final age = _ageOf(now, birthYear);
  final v = fitnessAt(runs, now);
  if (age == null || v == null) return null;
  final band = engine.ProgressMath.band(age: age, female: female);
  final pct = engine.ProgressMath.percentile(vdot: v, age: age, female: female);
  if (band == null || pct == null) return null;
  final shape = engine.ProgressMath.packShape(pct);
  return PackStanding(
    band: band,
    lane: engine.IdentityLane.aerobic,
    percentile: pct,
    histogram: shape.bins,
    youBin: shape.youBin,
  );
}

WeeklyStreak buildStreak(List<ProgressRun> runs, DateTime now) {
  final s = engine.ProgressMath.streak({
    for (final r in runs) r.week,
  }, engine.ProgressMath.weekIndex(now));
  return WeeklyStreak(
    weeks: s.weeks,
    thisWeekDone: s.thisWeekDone,
    freezesReady: s.freezesReady,
    recent: s.recent,
  );
}

// ---- Firsts ---------------------------------------------------------------

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'June',
  'July',
  'Aug',
  'Sept',
  'Oct',
  'Nov',
  'Dec',
];

String fmtDuration(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String _fmtKm(double km) => km.toStringAsFixed(1);

String _dayLabel(DateTime d) =>
    '${_days[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';

class _FirstDef {
  const _FirstDef(this.id, this.title, this.short);
  final String id;
  final String title;
  final String short;
}

const _firstDefs = [
  _FirstDef('first-run', 'Your first run', 'Run 1'),
  _FirstDef('first-1k', 'Your first 1K', '1K'),
  _FirstDef('first-3k', 'Your first 3K', '3K'),
  _FirstDef('first-5k', 'Your first 5K', '5K'),
  _FirstDef('first-10k', 'Your first 10K', '10K'),
  _FirstDef('first-half', 'Your first half marathon', 'Half'),
  _FirstDef('first-30min', 'Your first 30 minutes', '30 min'),
  _FirstDef('first-60min', 'Your first hour', '60 min'),
  _FirstDef('first-week', 'Your first week done', 'Week 1'),
  _FirstDef('two-weeks', 'Two weeks in a row', '2 weeks'),
  _FirstDef('first-month', 'Your first month', '4 weeks'),
  _FirstDef('first-intervals', 'Your first interval session', 'Intervals'),
  _FirstDef('first-test', 'Your first test', 'Test'),
  _FirstDef('first-trail', 'Your first trail run', 'Trail'),
  _FirstDef('first-sub30-5k', 'Your first sub-30 5K', 'Sub-30'),
];

/// Short label for a first's moment ("5K"), by id.
String firstShort(String id) =>
    _firstDefs.firstWhere((d) => d.id == id, orElse: () => _firstDefs[0]).short;

/// The 15 firsts, all present, done or not. [runs] oldest first.
List<FirstMilestone> buildFirsts(List<ProgressRun> runs, DateTime now) {
  ProgressRun? firstWhere(bool Function(ProgressRun) test) {
    for (final r in runs) {
      if (test(r)) return r;
    }
    return null;
  }

  final byWeek = <int, List<ProgressRun>>{};
  for (final r in runs) {
    (byWeek[r.week] ??= []).add(r);
  }
  final weeks = byWeek.keys.toList()..sort();
  final current = engine.ProgressMath.weekIndex(now);

  ProgressRun? weekDone() {
    for (final w in weeks) {
      if (w < current) return byWeek[w]!.last;
    }
    return null;
  }

  ProgressRun? inARow(int n) {
    for (final w in weeks) {
      var ok = true;
      for (var i = 1; i < n; i++) {
        if (!byWeek.containsKey(w - i)) ok = false;
      }
      if (ok && w - n + 1 >= weeks.first) return byWeek[w]!.first;
    }
    return null;
  }

  final done = <String, ProgressRun?>{
    'first-run': runs.isEmpty ? null : runs.first,
    'first-1k': firstWhere((r) => r.distanceM >= 1000),
    'first-3k': firstWhere((r) => r.distanceM >= 3000),
    'first-5k': firstWhere((r) => r.distanceM >= 5000),
    'first-10k': firstWhere((r) => r.distanceM >= 10000),
    'first-half': firstWhere((r) => r.distanceM >= 21097.5),
    'first-30min': firstWhere((r) => r.durationMs >= 30 * 60000),
    'first-60min': firstWhere((r) => r.durationMs >= 60 * 60000),
    'first-week': weekDone(),
    'two-weeks': inARow(2),
    'first-month': inARow(4),
    'first-intervals': firstWhere((r) => r.isIntervals),
    'first-test': firstWhere((r) => r.isCooper),
    'first-trail': firstWhere((r) => r.isTrail),
    'first-sub30-5k': firstWhere(
      (r) =>
          r.distanceM >= 5000 && r.durationMs / r.distanceM * 5000 <= 1800000,
    ),
  };
  final index = {for (var i = 0; i < runs.length; i++) runs[i].id: i + 1};
  return [
    for (final d in _firstDefs)
      FirstMilestone(
        id: d.id,
        title: d.title,
        detail: done[d.id] == null
            ? ''
            : '${fmtDuration(done[d.id]!.durationMs)} on '
                  '${_dayLabel(done[d.id]!.local)}, run ${index[done[d.id]!.id]}',
        achievedAt: done[d.id]?.start,
      ),
  ];
}

// ---- Ghost ----------------------------------------------------------------

GhostCompare? buildGhost(List<ProgressRun> runs, DateTime now) {
  final nowFrom = now.subtract(_kMonth);
  final thenFrom = now.subtract(_kMonth * 2);
  final thisMonth = [
    for (final r in runs)
      if (r.start.isAfter(nowFrom) && !r.start.isAfter(now)) r,
  ];
  final lastMonth = [
    for (final r in runs)
      if (r.start.isAfter(thenFrom) && !r.start.isAfter(nowFrom)) r,
  ];
  if (thisMonth.isEmpty || lastMonth.isEmpty) return null;
  ProgressRun? bestRun(List<ProgressRun> pool, double d) {
    ProgressRun? top;
    for (final r in pool) {
      if (r.distanceM < d || r.distanceM > d * 1.5 || r.durationMs <= 0) {
        continue;
      }
      if (top == null ||
          r.durationMs / r.distanceM < top.durationMs / top.distanceM) {
        top = r;
      }
    }
    return top;
  }

  Duration atDistance(ProgressRun r, double d) =>
      Duration(milliseconds: (r.durationMs / r.distanceM * d).round());
  // Name the month of the run it was compared against, not a date guess.
  String monthOf(ProgressRun r) => _months[r.start.month - 1];

  for (final (d, name) in [(5000.0, '5K'), (3000.0, '3K'), (1000.0, '1K')]) {
    final a = bestRun(thisMonth, d), b = bestRun(lastMonth, d);
    if (a != null && b != null) {
      return GhostCompare(
        label: name,
        now: atDistance(a, d),
        then: atDistance(b, d),
        thenLabel: monthOf(b),
      );
    }
  }
  ProgressRun longest(List<ProgressRun> pool) =>
      pool.reduce((a, b) => a.distanceM >= b.distanceM ? a : b);
  final topNow = longest(thisMonth), topThen = longest(lastMonth);
  final d =
      (topNow.distanceM < topThen.distanceM
          ? topNow.distanceM
          : topThen.distanceM) ~/
      100 *
      100;
  if (d < 500) return null;
  Duration at(ProgressRun r) =>
      Duration(milliseconds: (r.durationMs / r.distanceM * d).round());
  return GhostCompare(
    label: '${_fmtKm(d / 1000)}K',
    now: at(topNow),
    then: at(topThen),
    thenLabel: monthOf(topThen),
  );
}

// ---- Weekly story ---------------------------------------------------------

engine.IdentityLane laneOf(ProgressRun r) {
  if (r.isIntervals) return engine.IdentityLane.speed;
  if (r.distanceM >= 15000) return engine.IdentityLane.long;
  if (r.distanceM >= 5000 && !r.isTrail) return engine.IdentityLane.mid;
  return engine.IdentityLane.aerobic;
}

WeeklyStory? buildStory(List<ProgressRun> runs, DateTime now) {
  final last = engine.ProgressMath.weekIndex(now) - 1;
  final inWeek = [
    for (final r in runs)
      if (r.week == last) r,
  ];
  if (inWeek.isEmpty) return null;
  final earlier = [
    for (final r in runs)
      if (r.week < last) r,
  ];
  final km = inWeek.fold<double>(0, (s, r) => s + r.distanceM) / 1000;
  final longestKm =
      inWeek.map((r) => r.distanceM).reduce((a, b) => a > b ? a : b) / 1000;

  final weekKm = <int, double>{};
  for (final r in earlier) {
    weekKm[r.week] = (weekKm[r.week] ?? 0) + r.distanceM / 1000;
  }
  final biggest = weekKm.isNotEmpty && weekKm.values.every((v) => km > v);
  final longestEver =
      earlier.isNotEmpty &&
      earlier.every((r) => longestKm * 1000 > r.distanceM);
  final streakWeeks = engine.ProgressMath.streak({
    for (final r in runs)
      if (r.week <= last) r.week,
  }, last).weeks;

  final n = inWeek.length;
  final tally = '$n ${n == 1 ? 'run' : 'runs'}, ${_fmtKm(km)} km';
  final headline = biggest
      ? 'Your biggest week yet. $tally.'
      : longestEver
      ? 'Your longest run yet, ${_fmtKm(longestKm)} km. $tally this week.'
      : streakWeeks >= 3
      ? 'Week $streakWeeks in a row. $tally.'
      : '$tally.';

  final dailyKm = List<double>.filled(7, 0);
  final dailyBest = List<ProgressRun?>.filled(7, null);
  final laneKm = <engine.IdentityLane, double>{};
  for (final r in inWeek) {
    final i = r.local.weekday - 1;
    dailyKm[i] += r.distanceM / 1000;
    if (dailyBest[i] == null || r.distanceM > dailyBest[i]!.distanceM) {
      dailyBest[i] = r;
    }
    final l = laneOf(r);
    laneKm[l] = (laneKm[l] ?? 0) + r.distanceM / 1000;
  }
  engine.IdentityLane? laneOfWeek;
  for (final e in laneKm.entries) {
    if (laneOfWeek == null || e.value > laneKm[laneOfWeek]!) laneOfWeek = e.key;
  }
  return WeeklyStory(
    weekStart: engine.ProgressMath.weekStart(last),
    km: km,
    runs: n,
    headline: headline,
    dailyKm: dailyKm,
    dailyLane: [for (final r in dailyBest) r == null ? null : laneOf(r)],
    laneOfWeek: laneOfWeek,
  );
}

// ---- Moments --------------------------------------------------------------

String _isoDay(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

engine.IdentityLane _boardLane(engine.BestEffortDistance d) => switch (d) {
  engine.BestEffortDistance.km1 ||
  engine.BestEffortDistance.mile => engine.IdentityLane.speed,
  engine.BestEffortDistance.k5 ||
  engine.BestEffortDistance.k10 => engine.IdentityLane.mid,
  engine.BestEffortDistance.half ||
  engine.BestEffortDistance.marathon => engine.IdentityLane.long,
};

String _boardName(engine.BestEffortDistance d) => switch (d) {
  engine.BestEffortDistance.km1 => '1K',
  engine.BestEffortDistance.mile => 'Mile',
  engine.BestEffortDistance.k5 => '5K',
  engine.BestEffortDistance.k10 => '10K',
  engine.BestEffortDistance.half => 'Half',
  engine.BestEffortDistance.marathon => 'Marathon',
};

/// Unseen moments, most important first: firsts, PBs, level-ups, the weekly
/// story. Firsts and PBs only count when set in the last 14 days, so a
/// runner with a long history is not flooded on day one. Ids are stable:
/// `first:<id>`, `pb:<board>:<runId>`, `level:<n>`, `story:<yyyy-mm-dd>`.
List<Moment> buildMoments({
  required List<ProgressRun> runs,
  required DateTime now,
  required CalibratedLevel level,
  required List<FirstMilestone> firsts,
  required WeeklyStory? story,
  required Map<String, engine.Leaderboard> leaderboards,
  required Set<String> seen,
}) {
  final out = <Moment>[];
  final recent = now.subtract(_kRecent);
  bool fresh(DateTime d) => d.isAfter(recent) && !d.isAfter(now);

  final doneOrder = [
    for (final f in firsts)
      if (f.done) f,
  ]..sort((a, b) => a.achievedAt!.compareTo(b.achievedAt!));
  for (final f in firsts) {
    if (!f.done || !fresh(f.achievedAt!)) continue;
    out.add(
      Moment(
        id: 'first:${f.id}',
        kind: MomentKind.first,
        eyebrow:
            'FIRST, ${doneOrder.indexWhere((d) => d.id == f.id) + 1} '
            'OF $kFirstsTotal',
        big: firstShort(f.id),
        detail: f.detail.isEmpty ? f.title : '${f.title}. ${f.detail}',
      ),
    );
  }

  final runIds = {for (final r in runs) r.id};
  final keys = leaderboards.keys.toList()..sort();
  for (final key in keys) {
    final board = leaderboards[key]!;
    final dist = engine.BestEffortDistance.ofKey(key);
    final pb = board.pb;
    if (dist == null || pb == null || board.length < 2) continue;
    if (!fresh(pb.date) || !runIds.contains(pb.runId)) continue;
    out.add(
      Moment(
        id: 'pb:$key:${pb.runId}',
        kind: MomentKind.pb,
        eyebrow: 'NEW PB',
        big: _boardName(dist),
        detail:
            'Your fastest ${_boardName(dist)} yet, '
            '${fmtDuration((pb.metric * 1000).round())}.',
        lane: _boardLane(dist),
      ),
    );
  }

  if (!level.calibrating && level.level > (level.levelMonthAgo ?? 0)) {
    out.add(
      Moment(
        id: 'level:${level.level}',
        kind: MomentKind.levelUp,
        eyebrow: 'LEVEL UP',
        big: '${level.level}',
        detail: level.levelMonthAgo == null
            ? 'Your level is set.'
            : 'Up from ${level.levelMonthAgo} a month ago.',
      ),
    );
  }

  if (story != null) {
    out.add(
      Moment(
        id: 'story:${_isoDay(story.weekStart)}',
        kind: MomentKind.story,
        eyebrow: 'YOUR WEEK',
        big: '${_fmtKm(story.km)} km',
        detail: story.headline,
        lane: story.laneOfWeek,
      ),
    );
  }
  return [
    for (final m in out)
      if (!seen.contains(m.id)) m,
  ];
}

/// Everything, in one pass. See [buildProgressSnapshot].
ProgressSnapshot buildSnapshot(
  List<RunSummary> summaries, {
  required DateTime now,
  required ProfileSex sex,
  required int? birthYear,
  required Set<String> seen,
  required Map<String, engine.Leaderboard> leaderboards,
}) {
  final clock = now.isUtc ? now.toLocal() : now;
  final runs = [
    for (final s in summaries)
      if (s.durationMs > 0 && !s.start.isAfter(now)) ProgressRun(s),
  ]..sort((a, b) => a.start.compareTo(b.start));
  if (runs.isEmpty) return ProgressSnapshot.empty;

  final bool? female = switch (sex) {
    ProfileSex.male => false,
    ProfileSex.female => true,
    _ => null,
  };
  final level = buildLevel(runs, now, female: female, birthYear: birthYear);
  final firsts = buildFirsts(runs, clock);
  final story = buildStory(runs, clock);
  return ProgressSnapshot(
    runCount: runs.length,
    level: level,
    pack: buildPack(runs, clock, female: female, birthYear: birthYear),
    streak: buildStreak(runs, clock),
    firsts: firsts,
    ghost: buildGhost(runs, now),
    story: story,
    pending: buildMoments(
      runs: runs,
      now: now,
      level: level,
      firsts: firsts,
      story: story,
      leaderboards: leaderboards,
      seen: seen,
    ),
  );
}
