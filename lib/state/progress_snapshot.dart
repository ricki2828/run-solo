/// The view model behind the 12-Oct redesign (direction B "Cohort"): Home,
/// the Progress tab and the rare full-screen moments all read one
/// [ProgressSnapshot]. "Pack" is the runner's age band drawn from published
/// norms, never other real runners: nothing here leaves the phone.
///
/// UI streams build against the [ProgressSnapshot.sample] fixtures;
/// [buildProgressSnapshot] is filled in by the engine stream.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'history_store.dart';
import 'progress/progress_build.dart';
import 'quests/quest_store.dart';
import 'settings.dart';

/// Total first-time milestones (about 15, most land in runs 1 to 5).
const int kFirstsTotal = 15;

/// One number that moves from run 1. Age grade is the fair-at-any-age
/// figure; [level] is its steep-early ladder. [calibrating] holds until a
/// hard effort or [runsToSettle] more runs confirm it.
class CalibratedLevel {
  const CalibratedLevel({
    required this.level,
    required this.ageGradePct,
    required this.calibrating,
    required this.runsToSettle,
    this.levelMonthAgo,
    this.ageGradeMonthAgo,
  });

  final int level;

  /// Null before the first run or without sex and birth year.
  final double? ageGradePct;
  final bool calibrating;
  final int runsToSettle;
  final int? levelMonthAgo;
  final double? ageGradeMonthAgo;
}

/// Where the runner sits in their age band this week, from norms.
class PackStanding {
  const PackStanding({
    required this.band,
    required this.lane,
    required this.percentile,
    required this.histogram,
    required this.youBin,
  });

  /// "M40-49", "F30-39".
  final String band;
  final engine.IdentityLane lane;

  /// 0..100; "faster than N in 10" is percentile ~/ 10.
  final int percentile;
  int get fasterThanInTen => percentile ~/ 10;

  /// Relative heights 0..1, slowest bin first.
  final List<double> histogram;
  final int youBin;
}

/// One or more runs in a Monday-to-Sunday week keeps it alive; a freeze
/// covers a missed week; a paused week (ill or sore) neither counts nor
/// breaks.
class WeeklyStreak {
  const WeeklyStreak({
    required this.weeks,
    required this.thisWeekDone,
    required this.freezesReady,
    required this.recent,
  });

  final int weeks;
  final bool thisWeekDone;
  final int freezesReady;

  /// The last 8 weeks, oldest first.
  final List<engine.StreakWeek> recent;
}

class FirstMilestone {
  const FirstMilestone({
    required this.id,
    required this.title,
    required this.detail,
    this.achievedAt,
  });

  final String id;

  /// "Your first 5K".
  final String title;

  /// "28:12 on Sunday, run 5".
  final String detail;
  final DateTime? achievedAt;
  bool get done => achievedAt != null;
}

/// "You last month": the same effort now against a month ago.
class GhostCompare {
  const GhostCompare({
    required this.label,
    required this.now,
    required this.then,
    required this.thenLabel,
    this.nowLabel = kGhostNowLabel,
  });

  /// "5K".
  final String label;
  final Duration now;
  final Duration then;

  /// The windows are rolling 28 days, not calendar months, so the copy names
  /// the span and never a month (both sides could read the same month).
  final String nowLabel;

  /// "The 4 weeks before".
  final String thenLabel;
}

const kGhostNowLabel = 'Last 4 weeks';
const kGhostThenLabel = 'The 4 weeks before';

class WeeklyStory {
  const WeeklyStory({
    required this.weekStart,
    required this.km,
    required this.runs,
    required this.headline,
    required this.dailyKm,
    required this.dailyLane,
    this.laneOfWeek,
  });

  final DateTime weekStart;
  final double km;
  final int runs;

  /// "Your biggest week. Four runs, one long one, every easy day easy."
  final String headline;

  /// Seven entries, Monday first.
  final List<double> dailyKm;
  final List<engine.IdentityLane?> dailyLane;
  final engine.IdentityLane? laneOfWeek;
}

enum MomentKind { first, pb, levelUp, story, quest }

/// A full-screen reveal. Rare by design: firsts, PBs, level-ups, a finished
/// quest and the weekly story only, each shown once.
class Moment {
  const Moment({
    required this.id,
    required this.kind,
    required this.eyebrow,
    required this.big,
    required this.detail,
    this.lane,
  });

  /// Stable, so a seen moment never shows twice.
  final String id;
  final MomentKind kind;

  /// "SMALL FIRST, 4 OF 15".
  final String eyebrow;

  /// "5K".
  final String big;
  final String detail;
  final engine.IdentityLane? lane;
}

class ProgressSnapshot {
  const ProgressSnapshot({
    required this.runCount,
    required this.level,
    required this.streak,
    required this.firsts,
    this.pack,
    this.ghost,
    this.story,
    this.pending = const [],
  });

  final int runCount;
  final CalibratedLevel level;
  final PackStanding? pack;
  final WeeklyStreak streak;

  /// All [kFirstsTotal], done or not, in the order they usually land.
  final List<FirstMilestone> firsts;
  int get firstsDone => firsts.where((f) => f.done).length;
  final GhostCompare? ghost;

  /// Last complete week's story; null before one exists.
  final WeeklyStory? story;

  /// Unseen moments, most important first.
  final List<Moment> pending;

  static const empty = ProgressSnapshot(
    runCount: 0,
    level: CalibratedLevel(
      level: 0,
      ageGradePct: null,
      calibrating: true,
      runsToSettle: 5,
    ),
    streak: WeeklyStreak(
      weeks: 0,
      thisWeekDone: false,
      freezesReady: 1,
      recent: [
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
        engine.StreakWeek.missed,
      ],
    ),
    firsts: [],
  );

  /// Golden and widget-test fixtures: day 1, week 2, month 3.
  static ProgressSnapshot sample(String stage) => switch (stage) {
    'week2' => _week2,
    'month3' => _month3,
    _ => empty,
  };
}

/// Fills in the snapshot from history (see `progress/progress_build.dart`).
/// Pure: same runs, clock, profile and seen set give the same snapshot.
///
/// [leaderboards] (optional, `Boards.byKey`) feeds the PB moments; without it
/// no PB moment appears. Seen ids live in `SeenMomentsStore`.
///
/// [pausedWeeks] are Monday-start week indices that neither count nor break
/// the streak (the runner's own pauses plus the coach's care weeks).
/// [questHistory] feeds the QUEST DONE moments.
ProgressSnapshot buildProgressSnapshot(
  List<RunSummary> runs, {
  required DateTime now,
  required ProfileSex sex,
  required int? birthYear,
  Set<String> seenMoments = const {},
  Map<String, engine.Leaderboard> leaderboards = const {},
  Set<int> pausedWeeks = const {},
  List<QuestHistoryEntry> questHistory = const [],
}) => buildSnapshot(
  runs,
  now: now,
  sex: sex,
  birthYear: birthYear,
  seen: seenMoments,
  leaderboards: leaderboards,
  pausedWeeks: pausedWeeks,
  questHistory: questHistory,
);

List<double> get _histo => [
  for (var i = 0; i < 20; i++) 1 / (1 + (i - 9.5) * (i - 9.5) / 12),
];

FirstMilestone _first(String id, String title, [DateTime? at]) =>
    FirstMilestone(id: id, title: title, detail: '', achievedAt: at);

const _laneA = engine.IdentityLane.aerobic;

final _week2 = ProgressSnapshot(
  runCount: 3,
  level: const CalibratedLevel(
    level: 2,
    ageGradePct: 41,
    calibrating: true,
    runsToSettle: 2,
  ),
  pack: PackStanding(
    band: 'M40-49',
    lane: _laneA,
    percentile: 42,
    histogram: _histo,
    youBin: 7,
  ),
  streak: const WeeklyStreak(
    weeks: 1,
    thisWeekDone: true,
    freezesReady: 1,
    recent: [
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.missed,
      engine.StreakWeek.ran,
    ],
  ),
  firsts: [
    _first('first-run', 'Your first run', DateTime(2026, 10, 5)),
    _first('first-1k', 'Your first 1K', DateTime(2026, 10, 5)),
    _first('first-3k', 'Your first 3K', DateTime(2026, 10, 8)),
    _first('first-week', 'Your first week done', DateTime(2026, 10, 11)),
    for (var i = 4; i < kFirstsTotal; i++) _first('f$i', 'First $i'),
  ],
);

final _month3 = ProgressSnapshot(
  runCount: 41,
  level: const CalibratedLevel(
    level: 14,
    ageGradePct: 58,
    calibrating: false,
    runsToSettle: 0,
    levelMonthAgo: 12,
    ageGradeMonthAgo: 55,
  ),
  pack: PackStanding(
    band: 'M40-49',
    lane: _laneA,
    percentile: 63,
    histogram: _histo,
    youBin: 12,
  ),
  streak: const WeeklyStreak(
    weeks: 11,
    thisWeekDone: true,
    freezesReady: 1,
    recent: [
      engine.StreakWeek.ran,
      engine.StreakWeek.ran,
      engine.StreakWeek.ran,
      engine.StreakWeek.frozen,
      engine.StreakWeek.ran,
      engine.StreakWeek.ran,
      engine.StreakWeek.ran,
      engine.StreakWeek.ran,
    ],
  ),
  firsts: [
    for (var i = 0; i < kFirstsTotal; i++)
      _first('f$i', 'First $i', i < 12 ? DateTime(2026, 8, 1 + i) : null),
  ],
  ghost: const GhostCompare(
    label: '5K',
    now: Duration(minutes: 26, seconds: 41),
    then: Duration(minutes: 27, seconds: 55),
    thenLabel: kGhostThenLabel,
  ),
  story: WeeklyStory(
    weekStart: DateTime(2026, 10, 5),
    km: 42.6,
    runs: 4,
    headline:
        'Your biggest week. Four runs, one long one, every easy day easy.',
    dailyKm: const [8.1, 0, 7.2, 0, 10.9, 0, 16.4],
    dailyLane: const [
      engine.IdentityLane.aerobic,
      null,
      engine.IdentityLane.speed,
      null,
      engine.IdentityLane.mid,
      null,
      engine.IdentityLane.long,
    ],
    laneOfWeek: engine.IdentityLane.long,
  ),
);
