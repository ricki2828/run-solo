import 'dart:math' as math;

import '../model/session_catalogue.dart';
import '../model/session_spec.dart';
import 'load_guard.dart';
import 'identity_scores.dart';
import 'race_percentile_norms.dart';

/// The 4-week progress block: a deterministic, explainable plan built around
/// the four score lanes. Pure data and date logic; the app owns storage,
/// screens and the Start preset.
///
/// Nothing here learns or guesses: the same plan and the same runs always give
/// the same view, and every session carries one plain reason.

/// What a planned session is for. Order is the drop order when a week runs
/// out of days: easy goes first, the key session last.
enum BlockRole { easy, second, support, key }

/// How a session is run.
enum BlockKind { interval, easy, long, goal }

class BlockSession {
  const BlockSession({
    required this.id,
    required this.week,
    required this.dayOffset,
    required this.role,
    required this.kind,
    required this.reason,
    this.presetId,
    this.reps,
    this.minutes,
    this.goalId,
    this.minDistanceM,
    this.isTest = false,
    this.swapped = false,
  });

  /// `w1s1`: stable across swaps.
  final String id;

  /// 1 to 4.
  final int week;

  /// Suggested day inside the week, 0 to 6 from the week's first day.
  final int dayOffset;
  final BlockRole role;
  final BlockKind kind;

  /// One plain line: why this session, why this size.
  final String reason;
  final String? presetId;
  final int? reps;
  final int? minutes;

  /// A goal run's distance id (`d5000`), kind [BlockKind.goal] only.
  final String? goalId;

  /// A long run only counts this far (the LONG test).
  final double? minDistanceM;

  /// The week-4 re-measure.
  final bool isTest;
  final bool swapped;

  bool get hard => role == BlockRole.key || role == BlockRole.second;

  String get name {
    switch (kind) {
      case BlockKind.interval:
        final p = SessionCatalogue.byId(presetId!);
        if (presetId == '400s') return '${reps ?? p!.defaultReps} × 400 m';
        return p?.name ?? 'Intervals';
      case BlockKind.easy:
        return 'Easy run';
      case BlockKind.long:
        return minDistanceM != null ? '15K+ run' : 'Long run';
      case BlockKind.goal:
        return '5K goal run';
    }
  }

  /// "4 reps", "40 min" or "15 km or more": the size line.
  String get size {
    if (kind == BlockKind.interval) return '$reps reps';
    if (minDistanceM != null) {
      return '${(minDistanceM! / 1000).round()} km or more';
    }
    if (kind == BlockKind.goal) return 'best effort';
    return '$minutes min';
  }

  BlockSession copyWith({
    BlockRole? role,
    BlockKind? kind,
    String? reason,
    String? presetId,
    int? reps,
    int? minutes,
    String? goalId,
    double? minDistanceM,
    bool? isTest,
    bool? swapped,
    bool clearPreset = false,
  }) => BlockSession(
    id: id,
    week: week,
    dayOffset: dayOffset,
    role: role ?? this.role,
    kind: kind ?? this.kind,
    reason: reason ?? this.reason,
    presetId: clearPreset ? null : presetId ?? this.presetId,
    reps: clearPreset ? null : reps ?? this.reps,
    minutes: minutes ?? this.minutes,
    goalId: goalId ?? this.goalId,
    minDistanceM: minDistanceM ?? this.minDistanceM,
    isTest: isTest ?? this.isTest,
    swapped: swapped ?? this.swapped,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'week': week,
    'day': dayOffset,
    'role': role.name,
    'kind': kind.name,
    'reason': reason,
    if (presetId != null) 'preset': presetId,
    if (reps != null) 'reps': reps,
    if (minutes != null) 'minutes': minutes,
    if (goalId != null) 'goal': goalId,
    if (minDistanceM != null) 'minDistanceM': minDistanceM,
    if (isTest) 'test': true,
    if (swapped) 'swapped': true,
  };

  static BlockSession fromJson(Map<String, Object?> j) {
    T pick<T extends Enum>(List<T> values, Object? v) {
      for (final e in values) {
        if (e.name == v) return e;
      }
      throw FormatException('unknown plan value: $v');
    }

    final week = j['week'];
    final day = j['day'];
    if (j['id'] is! String ||
        week is! int ||
        week < 1 ||
        week > BlockPlanner.weeks ||
        day is! int ||
        day < 0 ||
        day > 6) {
      throw const FormatException('bad plan session');
    }
    return BlockSession(
      id: j['id'] as String,
      week: week,
      dayOffset: day,
      role: pick(BlockRole.values, j['role']),
      kind: pick(BlockKind.values, j['kind']),
      reason: j['reason'] is String ? j['reason'] as String : '',
      presetId: j['preset'] as String?,
      reps: j['reps'] as int?,
      minutes: j['minutes'] as int?,
      goalId: j['goal'] as String?,
      minDistanceM: (j['minDistanceM'] as num?)?.toDouble(),
      isTest: j['test'] == true,
      swapped: j['swapped'] == true,
    );
  }
}

/// A stored block: the sessions as built or swapped, from [start].
class BlockPlan {
  const BlockPlan({
    required this.lane,
    required this.perWeek,
    required this.start,
    required this.sessions,
  });

  static const int schema = 1;

  final IdentityLane lane;
  final int perWeek;

  /// Local date (no time) the block began.
  final DateTime start;

  /// Week by week, in the order to run them.
  final List<BlockSession> sessions;

  BlockPlan withSession(BlockSession s) => BlockPlan(
    lane: lane,
    perWeek: perWeek,
    start: start,
    sessions: [for (final o in sessions) o.id == s.id ? s : o],
  );

  Map<String, Object?> toJson() => {
    'schema': schema,
    'lane': lane.name,
    'perWeek': perWeek,
    'start': _dateStr(start),
    'sessions': [for (final s in sessions) s.toJson()],
  };

  /// Null for a missing, damaged or newer-schema file: no plan, never a crash.
  static BlockPlan? tryParse(Object? json) {
    try {
      if (json is! Map || json['schema'] != schema) return null;
      final laneName = json['lane'];
      final lane = IdentityLane.values.where((l) => l.name == laneName);
      final per = json['perWeek'];
      final start = DateTime.tryParse('${json['start']}');
      final raw = json['sessions'];
      if (lane.isEmpty ||
          per is! int ||
          per < BlockPlanner.minPerWeek ||
          per > BlockPlanner.maxPerWeek ||
          start == null ||
          raw is! List ||
          raw.isEmpty) {
        return null;
      }
      return BlockPlan(
        lane: lane.first,
        perWeek: per,
        start: DateTime(start.year, start.month, start.day),
        sessions: [
          for (final s in raw)
            BlockSession.fromJson(Map<String, Object?>.from(s as Map)),
        ],
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// What the planner knows about the runner, from the runs it can see.
class BlockBaseline {
  const BlockBaseline({this.typicalRunMin, this.longestRunMin, this.vdot});

  /// Median length of recent non-interval runs, minutes.
  final int? typicalRunMin;
  final int? longestRunMin;

  /// Median of the lane VDOTs, a True Pace based capacity estimate.
  final double? vdot;
}

/// One finished run, reduced to what the plan needs.
enum PlanRunKind { intervals, cooper, other }

class PlanRun {
  const PlanRun({
    required this.id,
    required this.start,
    required this.movingMs,
    required this.distanceM,
    required this.kind,
    this.templateId,
    this.truePaceSecPerKm,
  });
  final String id;
  final DateTime start;
  final int movingMs;
  final double distanceM;
  final PlanRunKind kind;
  final String? templateId;
  final double? truePaceSecPerKm;

  double get minutes => movingMs / 60000.0;
}

abstract final class BlockPlanner {
  static const int weeks = 4;
  static const int minPerWeek = 2;
  static const int maxPerWeek = 6;

  /// A week with nothing done moves the rest of the block back, this often.
  static const int maxShifts = 2;

  static const double longTestM = 15000;

  /// Chronological order for n sessions: hard early, the long one last.
  static const _order = {
    1: [BlockRole.key],
    2: [BlockRole.key, BlockRole.support],
    3: [BlockRole.key, BlockRole.easy, BlockRole.support],
    4: [BlockRole.key, BlockRole.easy, BlockRole.second, BlockRole.support],
    5: [
      BlockRole.key,
      BlockRole.easy,
      BlockRole.second,
      BlockRole.easy,
      BlockRole.support,
    ],
    6: [
      BlockRole.key,
      BlockRole.easy,
      BlockRole.second,
      BlockRole.easy,
      BlockRole.easy,
      BlockRole.support,
    ],
  };

  static BlockPlan build({
    required IdentityLane lane,
    required int perWeek,
    required DateTime start,
    BlockBaseline baseline = const BlockBaseline(),
  }) {
    final n = perWeek.clamp(minPerWeek, maxPerWeek);
    final typical = (baseline.typicalRunMin ?? 30).clamp(20, 60);
    final longBase = lane == IdentityLane.long
        ? _round5((baseline.longestRunMin ?? 60).clamp(45, 100))
        : _round5((typical * 1.5).round().clamp(40, 90));
    final sessions = <BlockSession>[];
    final firstWeekDays = firstMonday(start).difference(dateOnly(start)).inDays;
    for (var w = 1; w <= weeks; w++) {
      // Weeks run Monday to Sunday. A short first week keeps the sessions it
      // has room for, one a day at most.
      final days = w == 1 ? firstWeekDays : 7;
      final count = days >= 7
          ? n
          : (n * days / 7).round().clamp(1, math.min(n, days));
      final roles = _order[count]!;
      for (var i = 0; i < roles.length; i++) {
        final role = roles[i];
        final s = _session(
          lane: lane,
          week: w,
          role: role,
          typical: typical,
          longBase: longBase,
        );
        sessions.add(
          s.copyWithSlot(
            id: 'w${w}s${i + 1}',
            dayOffset: (i * days) ~/ roles.length,
          ),
        );
      }
    }
    return BlockPlan(
      lane: lane,
      perWeek: n,
      start: dateOnly(start),
      sessions: sessions,
    );
  }

  /// The first Monday after [start] (a Monday start gives the next one): week
  /// 1 runs from [start] to the Sunday before it.
  static DateTime firstMonday(DateTime start) {
    final d = dateOnly(start);
    return addDays(d, 8 - d.weekday);
  }

  /// The first day of plan week [week] (1 to 4), the block moved back by
  /// [shifts] weeks.
  static DateTime weekStart(DateTime start, int week, int shifts) => week == 1
      ? addDays(dateOnly(start), 7 * shifts)
      : addDays(firstMonday(start), 7 * (week - 2 + shifts));

  /// The day after plan week [week] ends (a Monday).
  static DateTime weekEnd(DateTime start, int week, int shifts) =>
      addDays(firstMonday(start), 7 * (week - 1 + shifts));

  static int _clampReps(String preset, int reps) {
    final p = SessionCatalogue.byId(preset)!;
    return reps.clamp(p.minReps ?? p.defaultReps, p.maxReps ?? p.defaultReps);
  }

  static int _round5(int v) => (v / 5).round() * 5;

  /// Week 3 is the light one for LONG (week 4 is its test); week 4 is the
  /// light one, with the test, for the rest.
  static bool isLight(IdentityLane lane, int w) =>
      lane == IdentityLane.long ? w == 3 : w == 4;

  static String _laneName(IdentityLane l) => l.name.toUpperCase();

  static BlockSession _session({
    required IdentityLane lane,
    required int week,
    required BlockRole role,
    required int typical,
    required int longBase,
  }) {
    final light = isLight(lane, week);
    final test = week == weeks;
    BlockSession easy(String why) => BlockSession(
      id: '',
      week: week,
      dayOffset: 0,
      role: BlockRole.easy,
      kind: BlockKind.easy,
      minutes: _round5((typical * (light ? 0.8 : 1.0)).round()).clamp(15, 75),
      reason: why,
    );
    const easyWhy =
        'Easy running between the hard days is where the gains settle in.';
    BlockSession interval(BlockRole r, String preset, int reps, String why) =>
        _interval(week, r, preset, reps, why);

    switch (role) {
      case BlockRole.easy:
        return easy(easyWhy);
      case BlockRole.second:
        if (light || test) {
          return easy(
            'Lighter week, so this one stays easy to let the work sink in.',
          );
        }
        return switch (lane) {
          IdentityLane.speed => interval(
            role,
            '30-30s',
            const [12, 16, 20][week - 1],
            'A shorter, quicker session to back up the main one.',
          ),
          IdentityLane.long => easy(
            'Steady and easy: the long run is the hard one this week.',
          ),
          _ => interval(
            role,
            'tempo',
            const [2, 3, 3][week - 1],
            'Tempo work lifts the pace you can hold, kept shorter than the main session.',
          ),
        };
      case BlockRole.support:
        if (lane == IdentityLane.long) {
          if (light || test) {
            return easy('Lighter and easy before the long run.')
                .copyWith(role: BlockRole.support);
          }
          return interval(
            role,
            'tempo',
            const [2, 3, 3][week - 1],
            'Tempo work keeps your pace honest while the long runs grow.',
          );
        }
        final f = light ? 0.8 : const [1.0, 1.1, 1.15][week - 1];
        return BlockSession(
          id: '',
          week: week,
          dayOffset: 0,
          role: role,
          kind: BlockKind.long,
          minutes: _round5((longBase * f).round()),
          reason: light
              ? 'A shorter long run in the lighter week.'
              : 'A longer easy run builds the base under everything else.',
        );
      case BlockRole.key:
        return _key(lane, week, longBase);
    }
  }

  static BlockSession _interval(
    int week,
    BlockRole role,
    String preset,
    int reps,
    String why, {
    bool isTest = false,
  }) {
    return BlockSession(
      id: '',
      week: week,
      dayOffset: 0,
      role: role,
      kind: BlockKind.interval,
      presetId: preset,
      reps: _clampReps(preset, reps),
      reason: why,
      isTest: isTest,
    );
  }

  static BlockSession _key(IdentityLane lane, int week, int longBase) {
    BlockSession interval(
      BlockRole r,
      String preset,
      int reps,
      String why, {
      bool isTest = false,
    }) => _interval(week, r, preset, reps, why, isTest: isTest);

    final laneName = _laneName(lane);
    final test = week == weeks;
    // Text and value come from the same clamped number.
    String upFrom(String preset, List<int> reps) {
      final now = _clampReps(preset, reps[week - 1]);
      final prev = _clampReps(preset, reps[week - 2]);
      return '$laneName session of the week: $now reps, up from $prev.';
    }

    switch (lane) {
      case IdentityLane.aerobic:
        if (test) {
          return interval(
            BlockRole.key,
            SessionSpec.norwegian4x4Id,
            4,
            'The re-measure: a standard 4x4 to see what the 4 weeks did to $laneName.',
            isTest: true,
          );
        }
        const reps = [3, 4, 5];
        return interval(
          BlockRole.key,
          SessionSpec.norwegian4x4Id,
          reps[week - 1],
          week == 1
              ? 'Starts building $laneName: the 4x4 is the session that moves it.'
              : upFrom(SessionSpec.norwegian4x4Id, reps),
        );
      case IdentityLane.speed:
        if (test) {
          return interval(
            BlockRole.key,
            '400s',
            8,
            'The re-measure: a standard 8 × 400 m to see what the 4 weeks did to $laneName.',
            isTest: true,
          );
        }
        const reps = [6, 8, 10];
        return interval(
          BlockRole.key,
          '400s',
          reps[week - 1],
          week == 1
              ? 'Starts building $laneName with clean 400s.'
              : upFrom('400s', reps),
        );
      case IdentityLane.mid:
        if (test) {
          return BlockSession(
            id: '',
            week: week,
            dayOffset: 0,
            role: BlockRole.key,
            kind: BlockKind.goal,
            goalId: 'd5000',
            isTest: true,
            reason:
                'The re-measure: a 5K run to see what the 4 weeks did to $laneName.',
          );
        }
        const reps = [3, 4, 5];
        return interval(
          BlockRole.key,
          '1km-repeats',
          reps[week - 1],
          week == 1
              ? 'Starts building $laneName with 1 km repeats at about 5K effort.'
              : upFrom('1km-repeats', reps),
        );
      case IdentityLane.long:
        if (test) {
          return BlockSession(
            id: '',
            week: week,
            dayOffset: 0,
            role: BlockRole.key,
            kind: BlockKind.long,
            minDistanceM: longTestM,
            isTest: true,
            reason:
                'The re-measure: a 15K+ run to see what the 4 weeks did to $laneName.',
          );
        }
        const f = [1.0, 1.1, 0.8];
        final mins = _round5((longBase * f[week - 1]).round());
        final prev = week == 1
            ? null
            : _round5((longBase * f[week - 2]).round());
        return BlockSession(
          id: '',
          week: week,
          dayOffset: 0,
          role: BlockRole.key,
          kind: BlockKind.long,
          minutes: mins,
          reason: week == 1
              ? 'The long run is the one that moves $laneName. Start at $mins min.'
              : week == 3
              ? 'A lighter week: $mins min, so the long test feels fresh.'
              : 'The long run grows: $mins min, up from $prev.',
        );
    }
  }

  /// Other sessions the runner can swap in for [s], same job and similar load.
  static List<BlockSession> alternatives(BlockSession s) {
    BlockSession preset(String id, int reps) {
      final p = SessionCatalogue.byId(id)!;
      return s.copyWith(
        kind: BlockKind.interval,
        presetId: id,
        reps: reps.clamp(
          p.minReps ?? p.defaultReps,
          p.maxReps ?? p.defaultReps,
        ),
        isTest: false,
        swapped: true,
        reason: 'You swapped this in.',
      );
    }

    final easyRun = s.copyWith(
      kind: BlockKind.easy,
      minutes: s.minutes ?? 30,
      isTest: false,
      swapped: true,
      clearPreset: true,
      reason: 'You swapped this for an easy run.',
    );
    if (s.isTest) return const [];
    switch (s.kind) {
      case BlockKind.interval:
        return [
          for (final id in const [
            SessionSpec.norwegian4x4Id,
            'tempo',
            '1km-repeats',
            '400s',
            '30-30s',
            '1-min-reps',
            'pyramid',
          ])
            if (id != s.presetId)
              preset(id, SessionCatalogue.byId(id)!.defaultReps),
          easyRun,
        ];
      case BlockKind.easy:
        return [
          for (final m in const [20, 30, 40, 50])
            if (m != s.minutes)
              s.copyWith(
                minutes: m,
                swapped: true,
                reason: 'You changed the length.',
              ),
        ];
      case BlockKind.long:
        final base = s.minutes ?? 60;
        return [
          s.copyWith(
            minutes: _round5((base * 0.8).round()),
            swapped: true,
            reason: 'You made this one shorter.',
          ),
          easyRun.copyWith(minutes: _round5((base * 0.6).round())),
        ];
      case BlockKind.goal:
        return [easyRun.copyWith(minutes: 30)];
    }
  }
}

extension on BlockSession {
  BlockSession copyWithSlot({required String id, required int dayOffset}) =>
      BlockSession(
        id: id,
        week: week,
        dayOffset: dayOffset,
        role: role,
        kind: kind,
        reason: reason,
        presetId: presetId,
        reps: reps,
        minutes: minutes,
        goalId: goalId,
        minDistanceM: minDistanceM,
        isTest: isTest,
        swapped: swapped,
      );
}

/// Paces for a runner, as True Pace (flat, cool day) seconds per km, from a
/// VDOT estimate. Estimates, not prescriptions.
abstract final class BlockPaces {
  /// Pace at the effort a runner can hold for about an hour.
  static double? threshold(double vdot) {
    if (!vdot.isFinite || vdot <= 0) return null;
    var lo = 2000.0, hi = 30000.0;
    for (var i = 0; i < 50; i++) {
      final mid = (lo + hi) / 2;
      final t = RacePercentileNorms.equivalentSeconds(vdot, mid);
      if (t == null) return null;
      if (t < 3600) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return 3600 / ((lo + hi) / 2 / 1000);
  }

  /// Pace (s/km) of the race-equivalent effort over [metres] for [vdot].
  static double? race(double vdot, double metres) => _race(vdot, metres);

  static double? _race(double vdot, double metres) {
    final t = RacePercentileNorms.equivalentSeconds(vdot, metres);
    return t == null ? null : t / (metres / 1000);
  }

  /// The pace the session aims at, or null with no VDOT or no threshold
  /// (a VDOT the pace model cannot place). Callers must not drop the session's
  /// guidance on null: the app falls back to effort-only wording.
  static double? target(BlockSession s, double? vdot) {
    if (vdot == null) return null;
    final th = threshold(vdot);
    if (th == null) return null;
    switch (s.kind) {
      case BlockKind.easy:
      case BlockKind.long:
        return th * (s.kind == BlockKind.long ? 1.2 : 1.25);
      case BlockKind.goal:
        return _race(vdot, 5000);
      case BlockKind.interval:
        return switch (s.presetId) {
          'tempo' => _race(vdot, 21097.5),
          '1km-repeats' => _race(vdot, 5000),
          '400s' => _race(vdot, 1500),
          _ => _race(vdot, 3000),
        };
    }
  }

  /// Threshold over actual pace: 1.0 is a run at threshold pace, above it is
  /// harder. Null without a pace or a VDOT.
  static double? intensity(double? truePaceSecPerKm, double? vdot) {
    if (truePaceSecPerKm == null || truePaceSecPerKm <= 0 || vdot == null) {
      return null;
    }
    final th = threshold(vdot);
    return th == null ? null : th / truePaceSecPerKm;
  }

  /// The median VDOT across the lanes that have a score; null with none.
  static double? medianVdot(Iterable<double> vdots) {
    final v = vdots.where((e) => e.isFinite && e > 0).toList()..sort();
    if (v.isEmpty) return null;
    final m = v.length ~/ 2;
    return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
  }
}

enum BlockStatus { done, next, planned, missed }

class BlockSessionState {
  const BlockSessionState({
    required this.session,
    required this.status,
    required this.date,
    this.runId,
    this.note,
    this.softened = false,
  });

  /// As shown and started: after any softening.
  final BlockSession session;
  final BlockStatus status;

  /// The suggested day.
  final DateTime date;
  final String? runId;

  /// Why a session is missed or changed, when it is.
  final String? note;
  final bool softened;
}

class BlockView {
  const BlockView({
    required this.plan,
    required this.weeks,
    required this.currentWeek,
    required this.shifts,
    this.next,
    this.nextIsNextWeek = false,
  });

  final BlockPlan plan;

  /// weeks[w - 1] in running order.
  final List<List<BlockSessionState>> weeks;

  /// 1 to 4, or null once every week is over.
  final int? currentWeek;

  /// Weeks the block moved back because one went by with nothing done.
  final int shifts;
  final BlockSessionState? next;
  final bool nextIsNextWeek;

  bool get finished => currentWeek == null || next == null;

  Iterable<BlockSessionState> get all => weeks.expand((w) => w);
  int get doneCount => all.where((s) => s.status == BlockStatus.done).length;
  int get totalCount => all.length;

  List<BlockSessionState> get thisWeek =>
      currentWeek == null ? const [] : weeks[currentWeek! - 1];

  /// Done and still to do this week; sessions that no longer fit are left out.
  int get weekDone =>
      thisWeek.where((s) => s.status == BlockStatus.done).length;
  int get weekTotal =>
      thisWeek.where((s) => s.status != BlockStatus.missed).length;
}

/// Turns a stored plan and the runs so far into what to show. Recomputed from
/// the runs every time, so the same input always gives the same answer and
/// nothing needs saving after a run.
abstract final class BlockResolver {
  /// A run counts as very hard when a steady run ran at or near threshold.
  static const double veryHardIntensity = 0.95;
  static const double veryHardMinutes = 20;

  static BlockView resolve(
    BlockPlan plan,
    List<PlanRun> runs, {
    required DateTime now,
    double? vdot,
    LoadFlag? load,
  }) {
    final sorted = [...runs.where((r) => !r.start.isBefore(plan.start))]
      ..sort((a, b) => a.start.compareTo(b.start));
    final today = dateOnly(now);
    var shifts = 0;
    final byWeek = <List<BlockSession>>[
      for (var w = 1; w <= BlockPlanner.weeks; w++)
        [
          for (final s in plan.sessions)
            if (s.week == w) s,
        ],
    ];
    final starts = <DateTime>[];
    final matches = <Map<String, String>>[];
    final ends = <DateTime>[];
    for (var w = 1; w <= BlockPlanner.weeks; w++) {
      var ws = BlockPlanner.weekStart(plan.start, w, shifts);
      var we = BlockPlanner.weekEnd(plan.start, w, shifts);
      var m = _match(byWeek[w - 1], sorted, ws, we);
      while (!today.isBefore(we) &&
          m.isEmpty &&
          shifts < BlockPlanner.maxShifts) {
        shifts++;
        ws = BlockPlanner.weekStart(plan.start, w, shifts);
        we = BlockPlanner.weekEnd(plan.start, w, shifts);
        m = _match(byWeek[w - 1], sorted, ws, we);
      }
      starts.add(ws);
      ends.add(we);
      matches.add(m);
    }
    int? current;
    for (var w = 1; w <= BlockPlanner.weeks; w++) {
      if (today.isBefore(ends[w - 1])) {
        current = w;
        break;
      }
    }
    // A week that has not begun yet, because the block was shifted, still
    // counts as the current one: next sessions come from it.
    final out = <List<BlockSessionState>>[];
    var nextFound = false;
    BlockSessionState? next;
    var nextIsNextWeek = false;
    for (var w = 1; w <= BlockPlanner.weeks; w++) {
      final ws = starts[w - 1];
      final m = matches[w - 1];
      final past = current == null || w < current;
      final states = <BlockSessionState>[];
      final undone = [
        for (final s in byWeek[w - 1])
          if (!m.containsKey(s.id)) s,
      ];
      final dropped = <String>{};
      if (w == current) {
        final ranToday = sorted.any((r) => dateOnly(r.start) == today);
        var from = today.isBefore(ws) ? ws : today;
        if (ranToday && !today.isBefore(ws)) from = addDays(today, 1);
        final room = math.max(0, ends[w - 1].difference(from).inDays);
        if (undone.length > room) {
          final order = [...undone]
            ..sort((a, b) {
              final c = a.role.index.compareTo(b.role.index);
              return c != 0 ? c : b.dayOffset.compareTo(a.dayOffset);
            });
          for (final s in order.take(undone.length - room)) {
            dropped.add(s.id);
          }
        }
      }
      for (final s in byWeek[w - 1]) {
        final date = addDays(ws, s.dayOffset);
        if (m.containsKey(s.id)) {
          states.add(
            BlockSessionState(
              session: s,
              status: BlockStatus.done,
              date: date,
              runId: m[s.id],
            ),
          );
        } else if (past) {
          states.add(
            BlockSessionState(
              session: s,
              status: BlockStatus.missed,
              date: date,
              note: 'Missed. It is not added on top of the next week.',
            ),
          );
        } else if (dropped.contains(s.id)) {
          states.add(
            BlockSessionState(
              session: s,
              status: BlockStatus.missed,
              date: date,
              note: 'No room left this week, so it is skipped, not crammed in.',
            ),
          );
        } else {
          states.add(
            BlockSessionState(
              session: s,
              status: BlockStatus.planned,
              date: date,
            ),
          );
        }
      }
      out.add(states);
    }
    // Easing: after a very hard steady run, or while this week runs hot, the
    // next session or two are easier. Derived from the runs, so nothing is
    // saved and it never stacks. The week-4 test is left alone.
    final hard = lastVeryHardRun(sorted, now: now, vdot: vdot);
    final String? easeWhy = hard != null
        ? 'Your run on ${_weekday[hard.start.weekday - 1]} was a very hard '
              'one, so this is easier.'
        : load?.planReason;
    var easeLeft = hard != null ? 1 : (load?.easeCount ?? 0);
    // The next session: first still-planned one in the current week, else the
    // first of the week after.
    for (var w = 1; w <= BlockPlanner.weeks; w++) {
      if (current == null || w < current) continue;
      for (var i = 0; i < out[w - 1].length; i++) {
        if (out[w - 1][i].status != BlockStatus.planned) continue;
        final first = !nextFound;
        var st = out[w - 1][i];
        if (easeLeft > 0 && easeWhy != null && !st.session.isTest) {
          st = _soften(st, easeWhy);
          easeLeft--;
        }
        if (first) {
          st = _with(st, BlockStatus.next);
          next = st;
          nextIsNextWeek = w != current;
          nextFound = true;
        }
        out[w - 1][i] = st;
        if (!first && easeLeft == 0) break;
        if (first && easeLeft == 0) break;
      }
      if (nextFound && easeLeft == 0) break;
    }
    return BlockView(
      plan: plan,
      weeks: out,
      currentWeek: current,
      shifts: shifts,
      next: next,
      nextIsNextWeek: nextIsNextWeek,
    );
  }

  /// The same session, made easier, with [why] as its reason.
  static BlockSessionState _soften(BlockSessionState st, String why) {
    final s = st.session;
    final BlockSession eased;
    switch (s.kind) {
      case BlockKind.interval:
      case BlockKind.goal:
        eased = s.copyWith(
          kind: BlockKind.easy,
          minutes: 30,
          clearPreset: true,
          isTest: false,
          reason: why,
        );
      case BlockKind.long:
        eased = s.copyWith(
          minutes: BlockPlanner._round5(((s.minutes ?? 60) * 0.8).round()),
          reason: why,
        );
      case BlockKind.easy:
        eased = s.copyWith(
          minutes: math.max(
            15,
            BlockPlanner._round5(((s.minutes ?? 30) * 0.8).round()),
          ),
          reason: why,
        );
    }
    return BlockSessionState(
      session: eased,
      status: st.status,
      date: st.date,
      softened: true,
    );
  }

  static BlockSessionState _with(BlockSessionState st, BlockStatus status) =>
      BlockSessionState(
        session: st.session,
        status: status,
        date: st.date,
        runId: st.runId,
        note: st.note,
        softened: st.softened,
      );

  static const _weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// The newest steady run in the last two days that ran at or near
  /// threshold for 20+ minutes, or null.
  static PlanRun? lastVeryHardRun(
    List<PlanRun> runs, {
    required DateTime now,
    required double? vdot,
  }) {
    for (final r in runs.reversed) {
      if (now.difference(r.start).inDays >= 2) return null;
      if (r.kind != PlanRunKind.other || r.minutes < veryHardMinutes) continue;
      final i = BlockPaces.intensity(r.truePaceSecPerKm, vdot);
      if (i != null && i >= veryHardIntensity) return r;
    }
    return null;
  }

  /// Which session each run in the week ticks: the best fit, earliest first.
  static Map<String, String> _match(
    List<BlockSession> sessions,
    List<PlanRun> runs,
    DateTime weekStart,
    DateTime end,
  ) {
    final out = <String, String>{};
    for (final r in runs) {
      if (r.start.isBefore(weekStart) || !r.start.isBefore(end)) continue;
      BlockSession? best;
      var bestScore = 0;
      for (final s in sessions) {
        if (out.containsKey(s.id)) continue;
        final sc = _score(s, r);
        if (sc > bestScore) {
          best = s;
          bestScore = sc;
        }
      }
      if (best != null) out[best.id] = r.id;
    }
    return out;
  }

  static int _score(BlockSession s, PlanRun r) {
    final steady = r.kind == PlanRunKind.other;
    switch (s.kind) {
      case BlockKind.interval:
        return r.kind == PlanRunKind.intervals && r.templateId == s.presetId
            ? 3
            : 0;
      case BlockKind.goal:
        return steady && r.distanceM >= 5000 ? 3 : 0;
      case BlockKind.long:
        if (!steady) return 0;
        if (s.minDistanceM != null) {
          return r.distanceM >= s.minDistanceM! ? 3 : 0;
        }
        return r.minutes >= (s.minutes ?? 60) * 0.8 ? 2 : 0;
      case BlockKind.easy:
        return steady && r.minutes >= math.max(15, (s.minutes ?? 30) * 0.7)
            ? 1
            : 0;
    }
  }

  /// "Next: Norwegian 4x4 Thu".
  static String dayName(DateTime d) => _weekday[d.weekday - 1];
}

/// What the runner's runs say for planning: typical length, longest, VDOT.
abstract final class BlockBaselines {
  static BlockBaseline of(
    List<PlanRun> runs,
    Map<IdentityLane, IdentityScore> scores, {
    required DateTime now,
  }) {
    final mins = [
      for (final r in runs)
        if (r.kind == PlanRunKind.other &&
            now.difference(r.start).inDays < 60 &&
            r.minutes >= 10)
          r.minutes,
    ]..sort();
    return BlockBaseline(
      typicalRunMin: mins.isEmpty ? null : mins[mins.length ~/ 2].round(),
      longestRunMin: mins.isEmpty ? null : mins.last.round(),
      vdot: BlockPaces.medianVdot([for (final s in scores.values) s.vdot]),
    );
  }
}
