import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../run_mode.dart';
import 'analysis.dart';
import 'constants.dart';
import 'elevation.dart';
import 'trace.dart';

/// A distance a best effort is found for (Phase 4 plan §3.1). Board keys use
/// the reserved `be:` prefix, never a comparison key.
enum BestEffortDistance {
  km1('be:1000', 1000, 400),
  mile('be:1609', 1609.344, 400),
  k5('be:5000', 5000, 1000),
  k10('be:10000', 10000, 1000),

  /// Half and marathon (GOAL runs, plan §G).
  half('be:21097', 21097.5, 1000),
  marathon('be:42195', 42195, 1000);

  const BestEffortDistance(this.key, this.metres, this.splitEveryM);

  final String key;
  final double metres;

  /// Cumulative splits are taken every this many metres inside the window.
  final double splitEveryM;

  static const String keyPrefix = ComparisonKey.reservedBoardPrefix;

  static BestEffortDistance? ofKey(String key) {
    for (final d in values) {
      if (d.key == key) return d;
    }
    return null;
  }
}

/// The fastest contiguous [distance] inside one run.
class BestEffort {
  const BestEffort({
    required this.distance,
    required this.elapsedMs,
    required this.startMs,
    required this.startOffsetM,
    required this.splitsMs,
    this.avgHr,
    this.gradeFactor = 1,
    this.pausedMs = 0,
  });

  final BestEffortDistance distance;

  /// Paused time inside the window, which [elapsedMs] (moving time) leaves
  /// out; non-zero only for a 5K/10K goal run bridged over a pause.
  final int pausedMs;

  /// The hills factor on this window's time (True Pace; 1 on the flat or
  /// without barometer elevation).
  final double gradeFactor;

  /// This effort with its hills factor.
  BestEffort withGrade(double g) => BestEffort(
    distance: distance,
    elapsedMs: elapsedMs,
    startMs: startMs,
    startOffsetM: startOffsetM,
    splitsMs: splitsMs,
    avgHr: avgHr,
    gradeFactor: g,
    pausedMs: pausedMs,
  );
  final int elapsedMs;

  /// Window start, ms since the run's start.
  final int startMs;

  /// Distance covered before the window started (0 = from the first metre).
  final double startOffsetM;

  /// Cumulative time from the window start at every [BestEffortDistance.
  /// splitEveryM] strictly inside the window (the finish is [elapsedMs]).
  final List<int> splitsMs;
  final double? avgHr;

  /// Window end on the run's clock (ms since the run's start), pauses
  /// inside the window included.
  int get endMs => startMs + elapsedMs + pausedMs;

  double get paceSecPerKm => elapsedMs / distance.metres;

  Map<String, Object?> toJson() => {
    'elapsed_ms': elapsedMs,
    'start_ms': startMs,
    'start_offset_m': double.parse(startOffsetM.toStringAsFixed(1)),
    'splits_ms': splitsMs,
    'avg_hr': avgHr == null ? null : double.parse(avgHr!.toStringAsFixed(1)),
    if (gradeFactor != 1)
      'grade_x': double.parse(gradeFactor.toStringAsFixed(4)),
    if (pausedMs != 0) 'paused_ms': pausedMs,
  };

  factory BestEffort.fromJson(
    BestEffortDistance distance,
    Map<String, Object?> json,
  ) => BestEffort(
    distance: distance,
    elapsedMs: json['elapsed_ms'] as int,
    startMs: json['start_ms'] as int,
    startOffsetM: (json['start_offset_m'] as num).toDouble(),
    splitsMs: [for (final s in json['splits_ms'] as List) s as int],
    avgHr: (json['avg_hr'] as num?)?.toDouble(),
    gradeFactor: (json['grade_x'] as num?)?.toDouble() ?? 1,
    pausedMs: (json['paused_ms'] as int?) ?? 0,
  );
}

/// The most distance inside [seconds] of clean running (GOAL time boards,
/// plan §G): `be:t1800` (30 min), `be:t3600` (60 min). Higher is better.
enum BestTimeWindow {
  min30('be:t1800', 1800),
  min60('be:t3600', 3600);

  const BestTimeWindow(this.key, this.seconds);

  final String key;
  final int seconds;

  static BestTimeWindow? ofKey(String key) {
    for (final w in values) {
      if (w.key == key) return w;
    }
    return null;
  }
}

/// The most distance one run covered in a [window].
class BestDistance {
  const BestDistance({
    required this.window,
    required this.metres,
    required this.startMs,
    required this.startOffsetM,
    this.gradeFactor = 1,
  });

  final BestTimeWindow window;

  /// The hills factor over the window (True Pace); 1 without it.
  final double gradeFactor;

  BestDistance withGrade(double g) => BestDistance(
    window: window,
    metres: metres,
    startMs: startMs,
    startOffsetM: startOffsetM,
    gradeFactor: g,
  );
  final double metres;
  final int startMs;
  final double startOffsetM;

  Map<String, Object?> toJson() => {
    'metres': double.parse(metres.toStringAsFixed(1)),
    'start_ms': startMs,
    'start_offset_m': double.parse(startOffsetM.toStringAsFixed(1)),
    if (gradeFactor != 1)
      'grade_x': double.parse(gradeFactor.toStringAsFixed(4)),
  };

  factory BestDistance.fromJson(
    BestTimeWindow window,
    Map<String, Object?> json,
  ) => BestDistance(
    window: window,
    metres: (json['metres'] as num).toDouble(),
    startMs: json['start_ms'] as int,
    startOffsetM: (json['start_offset_m'] as num).toDouble(),
    gradeFactor: (json['grade_x'] as num?)?.toDouble() ?? 1,
  );
}

/// Everything LB1 derives from one run: the board windows and the
/// from-start splits live compare races against (plan §3.1, WARN-1).
class RunBestEfforts {
  const RunBestEfforts({
    required this.efforts,
    required this.fromStartSplitsMs,
    this.distances = const {},
    this.wholeRunM,
    this.wholeRunMs,
    this.miss,
  });

  /// Why a run that went far enough has no 5K/10K effort (MID and ESTIMATED
  /// TIMES read it to tell the runner). Null when it has one, or when the
  /// cause is not in the trace.
  final EffortMiss? miss;

  /// A Free or Laps run with no pause and no gap, as one continuous effort
  /// (a PD1 prediction input; the Home card reads it from the index, PD2).
  /// Null otherwise.
  final double? wholeRunM;
  final int? wholeRunMs;

  static const RunBestEfforts none = RunBestEfforts(
    efforts: {},
    fromStartSplitsMs: [],
  );

  /// Most distance per time window (§G time boards); absent when the run
  /// had no clean stretch that long.
  final Map<BestTimeWindow, BestDistance> distances;

  /// Best window per distance; a distance the run never covered cleanly is
  /// absent.
  final Map<BestEffortDistance, BestEffort> efforts;

  /// Cumulative time from the Start press (run time 0) at each whole km, up
  /// to [maxFromStartKm], cut at the first pause, recording gap, sample gap
  /// or GPS jump. Live compare uses the first 5 for the 5K board, 10 for the
  /// 10K, 21/42 for half/marathon goals (§G), and only when the list is that
  /// long. Empty for sessions that race no distance board (intervals other
  /// than the event and goals, Cooper).
  final List<int> fromStartSplitsMs;

  /// These efforts with the hills factor of each window read from the run's
  /// elevation (True Pace); unchanged without barometer elevation.
  RunBestEfforts withGradeFactors(RunElevation? elevation) {
    if (elevation == null || elevation.src != ElevSource.baro) return this;
    return RunBestEfforts(
      efforts: {
        for (final e in efforts.entries)
          e.key: e.value.withGrade(
            elevation.gradeFactorBetweenMs(e.value.startMs, e.value.endMs),
          ),
      },
      fromStartSplitsMs: fromStartSplitsMs,
      distances: {
        for (final d in distances.entries)
          d.key: d.value.withGrade(
            elevation.gradeFactorBetweenMs(
              d.value.startMs,
              d.value.startMs + d.key.seconds * 1000,
            ),
          ),
      },
      wholeRunM: wholeRunM,
      wholeRunMs: wholeRunMs,
      miss: miss,
    );
  }

  Map<String, Object?> toJson() => {
    'efforts': {for (final e in efforts.values) e.distance.key: e.toJson()},
    'from_start_splits_ms': fromStartSplitsMs,
    if (wholeRunM != null)
      'whole_run': {
        'm': double.parse(wholeRunM!.toStringAsFixed(1)),
        'ms': wholeRunMs,
      },
    if (distances.isNotEmpty)
      'distances': {for (final d in distances.values) d.window.key: d.toJson()},
    if (miss != null) 'miss': miss!.toJson(),
  };

  factory RunBestEfforts.fromJson(Map<String, Object?> json) {
    final efforts = <BestEffortDistance, BestEffort>{};
    for (final e in (json['efforts'] as Map).entries) {
      final d = BestEffortDistance.ofKey(e.key as String);
      if (d == null) continue; // a newer engine's distance: ignore
      efforts[d] = BestEffort.fromJson(d, e.value as Map<String, Object?>);
    }
    final distances = <BestTimeWindow, BestDistance>{};
    for (final e in ((json['distances'] as Map?) ?? const {}).entries) {
      final w = BestTimeWindow.ofKey(e.key as String);
      if (w == null) continue;
      distances[w] = BestDistance.fromJson(w, e.value as Map<String, Object?>);
    }
    return RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: [
        for (final s in (json['from_start_splits_ms'] as List? ?? const []))
          s as int,
      ],
      distances: distances,
      wholeRunM: ((json['whole_run'] as Map?)?['m'] as num?)?.toDouble(),
      wholeRunMs: (json['whole_run'] as Map?)?['ms'] as int?,
      miss: json['miss'] == null
          ? null
          : EffortMiss.fromJson(json['miss'] as Map<String, Object?>),
    );
  }
}

/// What cut a run's 5K/10K short of counting.
enum EffortMissKind {
  /// The runner (or auto-pause) paused.
  pause('pause'),

  /// A goal run paused for over a minute in all before its distance.
  pausedLong('pausedlong'),

  /// Recording stopped and resumed (the system killed it).
  recordingStopped('stopped'),

  /// The GPS went quiet for too long to bridge (over a minute), or for a
  /// few short stretches that add up to too much.
  gpsDropped('dropped'),

  /// The position leaped further than a runner can move.
  gpsJump('jump'),

  /// The whole track was too noisy to trust.
  noisy('noisy'),

  /// A treadmill or other run with no GPS track.
  indoor('indoor');

  const EffortMissKind(this.code);
  final String code;

  static EffortMissKind? ofCode(String? code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// Why a run of 5 km or more (or a 5K/10K goal run) has no 5K/10K effort.
class EffortMiss {
  const EffortMiss(
    this.kind, {
    this.atM,
    this.goalM,
    this.durationMs,
    this.drops = 1,
  });

  final EffortMissKind kind;

  /// Distance into the run where it broke; null for a whole-track cause.
  final double? atM;

  /// The distance of a 5K/10K goal run; null for any other run.
  final double? goalM;

  /// For [EffortMissKind.gpsDropped]: how long the GPS was gone (all
  /// dropouts added up when [drops] is more than one); null when unknown
  /// (a miss stored before version 8).
  final int? durationMs;

  /// How many dropouts [durationMs] adds up.
  final int drops;

  /// "paused at 3.2 km", "GPS dropped for 2 min at 4.1 km" (kilometres).
  String get reason => reasonIn(Units.km);

  /// [reason] with the distance in the runner's [units] ("paused at 2.0
  /// mi").
  String reasonIn(Units units) {
    final at = atM == null
        ? ''
        : units == Units.mi
        ? ' at ${(atM! / 1609.344).toStringAsFixed(1)} mi'
        : ' at ${(atM! / 1000).toStringAsFixed(1)} km';
    return switch (kind) {
      EffortMissKind.pause => 'paused$at',
      EffortMissKind.pausedLong => 'paused for over a minute',
      EffortMissKind.recordingStopped => 'recording stopped$at',
      EffortMissKind.gpsDropped => _dropped(at),
      EffortMissKind.gpsJump => 'GPS jumped$at',
      EffortMissKind.noisy => 'GPS was too noisy',
      EffortMissKind.indoor => 'no GPS track',
    };
  }

  String _dropped(String at) {
    final ms = durationMs;
    if (ms == null) return 'GPS dropped$at';
    final s = (ms / 1000).round();
    final span = s < 120 ? '$s s' : '${(s / 60).round()} min';
    return drops > 1
        ? 'GPS dropped $drops times, $span in all'
        : 'GPS dropped for $span$at';
  }

  Map<String, Object?> toJson() => {
    'kind': kind.code,
    if (atM != null) 'at_m': double.parse(atM!.toStringAsFixed(1)),
    if (goalM != null) 'goal_m': goalM,
    if (durationMs != null) 'ms': durationMs,
    if (drops > 1) 'drops': drops,
  };

  static EffortMiss? fromJson(Map<String, Object?> json) {
    final kind = EffortMissKind.ofCode(json['kind'] as String?);
    if (kind == null) return null;
    return EffortMiss(
      kind,
      atM: (json['at_m'] as num?)?.toDouble(),
      goalM: (json['goal_m'] as num?)?.toDouble(),
      durationMs: (json['ms'] as num?)?.toInt(),
      drops: (json['drops'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Finds the fastest 1 km, mile, 5K and 10K inside any run (Phase 4 plan
/// §3.1, LB1). Pure and O(n) per distance.
///
/// Distance is the recorder's own filtered, pause-frozen `distM` stream,
/// the one native ranks live, never a re-filtered one (BLOCK-2). Window
/// edges between samples are linearly interpolated (the I2 distance-step
/// rule); lap edges are placed by interpolating that stream at the lap's
/// time, never read from the stored lap distance (P2-a).
///
/// A window qualifies only inside one clean stretch: no pause, no
/// kill→resume gap, no sample gap > [EngineConstants.sampleGapInterruptMs]
/// (except a short GPS dropout, see [maxBridgedGpsGapMs]; 1K and mile
/// windows never bridge), and no GPS jump (one sample step faster than
/// [maxStepMps], or a break of any [speedCaps]). In an
/// intervals session short 1K/mile windows must also lie inside one clean
/// work rep; a 5K/10K window can span reps only within a continuous clean
/// GPS stretch. A parkrun (one continuous 5 km step) is searched whole.
/// Indoor and noisy runs get nothing (the verdict gates).
///
/// The GPS guard is physical plausibility only (lead 26-Sep, review #31):
/// speed caps cut the stream, never a pace change against the rest of the
/// run or window, because a real surge, kick or negative split looks the
/// same as slow drift and a board must never lose a real effort. Drift under
/// every cap stays in; it is within phone-GPS error.
class BestEffortFinder {
  const BestEffortFinder([this.constants = EngineConstants.defaults]);

  final EngineConstants constants;

  /// Plausibility caps, cut out of the stream wherever they are broken:
  /// 100 m faster than 9 m/s (a fast sprint, not a Free-run kick) and 200 m
  /// faster than 8 m/s. They catch a jump smeared over several samples that
  /// the one-step cap below misses.
  static const List<(double, double)> speedCaps = [(100, 9), (200, 8)];

  /// A single-sample spike: one step between samples faster than this is
  /// a GPS jump, not a stride (Bolt's top speed is ~12 m/s; a 1 Hz step
  /// over 10 m/s from a recreational runner is the fix moving).
  static const double maxStepMps = 10;

  /// A GOAL run to 5K or 10K that reaches its distance counts as that
  /// effort even when a pause or recording gap splits it, if the run was
  /// interrupted for no more than this long in all (pauses plus gaps). The
  /// time is the moving time: pauses come out. A traffic light or a shoelace
  /// changes a 5K time by seconds; a long rest lets the legs recover and
  /// would make the second half a fake-fast effort, so past this the run is
  /// not a continuous effort and the clean-stretch rule applies as before.
  static const int maxBridgedInterruptMs = 60000;

  /// A GPS dropout inside a run (no fix for longer than
  /// [EngineConstants.sampleGapInterruptMs], no pause, no kill and resume)
  /// is bridged for the 5K, 10K, half and marathon windows when it lasts no
  /// more than this, the speed across it is plausible ([maxStepMps] and
  /// [speedCaps]), and the dropouts a window holds add up to no more than
  /// the larger of [maxBridgedGpsTotalMs] and [bridgedGpsShare] of the
  /// window's time. The total cap guards data quality, not fake PBs: the
  /// chord can only make a time slower. A tunnel
  /// or an urban canyon changes a 5K by seconds; a long loss could hide a
  /// stop, so past this the window is cut as before.
  ///
  /// The distance across a dropout is the recorder's own: its filter adds
  /// the straight line from the last accepted fix to the first one back (or
  /// nothing, if that step is rejected and the track re-anchors), never the
  /// path the runner took. A chord is never longer than the path, so a
  /// window of fixed length that spans a whole dropout holds at most the
  /// distance really run, and its time can only be equal to or slower than
  /// the true time, never faster. A window with an edge inside a dropout is
  /// refused, because its edge distance would be interpolated along the
  /// chord, which is not where the runner was. 1K and mile windows stay
  /// strict: they are SPEED evidence, where a 20 s hole is a large share of
  /// a 3 to 5 minute effort and the 5% rule would not protect them.
  static const int maxBridgedGpsGapMs = 60000;

  /// All dropouts one window may hold, at least (see [maxBridgedGpsGapMs]).
  static const int maxBridgedGpsTotalMs = 180000;

  /// ... or this share of the window's time, if that is more.
  static const double bridgedGpsShare = 0.15;

  RunBestEfforts find(RunFile run, RunAnalysis analysis) {
    if (analysis.indoor || analysis.noisy) {
      // Say why when the run went far enough to have counted.
      return run.distanceM >= BestEffortDistance.k5.metres
          ? RunBestEfforts(
              efforts: const {},
              fromStartSplitsMs: const [],
              miss: EffortMiss(
                analysis.indoor ? EffortMissKind.indoor : EffortMissKind.noisy,
                goalM: _goalMetres(analysis),
              ),
            )
          : RunBestEfforts.none;
    }
    final pts = [for (final s in run.samples) _Pt(s.tMs.toDouble(), s.distM)];
    if (pts.length < 2) return RunBestEfforts.none;

    final stretches = _cutJumps(_cleanStretches(run));
    // The same stream with short GPS dropouts bridged, for the long windows.
    final bridgedStretches = _hasDropout(run)
        ? _cutJumps(_cleanStretches(run, bridge: true))
        : stretches;
    // A parkrun is one continuous 5 km step from the Start press, so the
    // whole run is its work; it does not wait on rep detection (a
    // single-lap session has none).
    final clip = analysis.mode == RunMode.intervals && !_searchWhole(analysis);
    final pool = clip ? _clipToWorkReps(stretches, analysis) : stretches;
    final bridgedPool = identical(bridgedStretches, stretches)
        ? pool
        : clip
        ? _clipToWorkReps(bridgedStretches, analysis)
        : bridgedStretches;

    final efforts = <BestEffortDistance, BestEffort>{};
    BestEffort build(List<_Pt> home, _Window best, BestEffortDistance d) {
      final splits = _splits(home, best, d);
      // Times are on the home stretch's clock (moving time when bridged);
      // the window's place on the run's clock is what the hills factor and
      // the heart rate read.
      final elapsedMs = best.end.round() - best.start.round();
      final startMs = _clockAt(home, best.start).round();
      final endMs = _clockAt(home, best.end).round();
      return BestEffort(
        distance: d,
        elapsedMs: elapsedMs,
        startMs: startMs,
        startOffsetM: best.startD - pts.first.d,
        splitsMs: [for (final t in splits) (t - best.start).round()],
        avgHr: run.hasHr ? Trace(run.samples).meanHr(startMs, endMs) : null,
        pausedMs: endMs - startMs - elapsedMs,
      );
    }

    for (final d in BestEffortDistance.values) {
      // A continuous 5K/10K can count toward MID even when the runner
      // selected INT and no work reps were detected. Short SPEED efforts
      // still stay inside a clean rep; all quality/GPS cuts remain.
      final long = d.metres >= BestEffortDistance.k5.metres;
      final wide = d == BestEffortDistance.k5 || d == BestEffortDistance.k10;
      final search = clip && wide
          ? (long ? bridgedStretches : stretches)
          : long
          ? bridgedPool
          : pool;
      final found = _fastest(search, d, bridged: long);
      if (found == null) continue;
      efforts[d] = build(found.$1, found.$2, d);
    }
    // A 5K/10K goal run that reached its distance counts despite a short
    // pause or gap (moving time; see [maxBridgedInterruptMs]).
    final goalM = _goalMetres(analysis);
    for (final d in [BestEffortDistance.k5, BestEffortDistance.k10]) {
      if (efforts.containsKey(d) || goalM != d.metres) continue;
      final bridged = _bridged(run, d.metres);
      if (bridged == null) continue;
      final found = _fastest(_cutJumps([bridged]), d, bridged: true);
      if (found != null) efforts[d] = build(found.$1, found.$2, d);
    }
    final continuous =
        (analysis.mode == RunMode.free || analysis.mode == RunMode.laps) &&
        run.pauses.isEmpty &&
        run.gaps.isEmpty;
    final distances = <BestTimeWindow, BestDistance>{};
    for (final w in BestTimeWindow.values) {
      final best = _mostDistance(pool, w.seconds * 1000.0);
      if (best == null) continue;
      distances[w] = BestDistance(
        window: w,
        metres: best.$2,
        startMs: best.$1.round(),
        startOffsetM: best.$3 - pts.first.d,
      );
    }
    return RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: _racesDistanceBoards(analysis)
          ? _fromStartSplits(run, stretches)
          : const [],
      distances: distances,
      wholeRunM: continuous ? run.distanceM - run.samples.first.distM : null,
      wholeRunMs: continuous ? run.elapsedMs : null,
      miss: _miss(run, pts, goalM, efforts),
    );
  }

  /// The distance of a 5K or 10K GOAL run (`goal:d5000`); null for any
  /// other run.
  static double? _goalMetres(RunAnalysis a) {
    final m = RegExp(r'^goal:d(\d+)$').firstMatch(a.comparisonKey ?? '');
    final metres = m == null ? null : double.parse(m.group(1)!);
    return metres == BestEffortDistance.k5.metres ||
            metres == BestEffortDistance.k10.metres
        ? metres
        : null;
  }

  /// The run up to the sample that reaches [goalM], as one stretch with the
  /// pauses taken out of its clock (moving time). Null when pauses before
  /// that point add up to more than [maxBridgedInterruptMs], or when it holds
  /// a recording gap, a long sample gap or a GPS jump. Only the run up to the
  /// goal distance counts: a cool-down pause or drift after it is not part of
  /// the effort. Recording gaps are never bridged: after a kill and resume
  /// the first fix can land far from where recording stopped, and the
  /// distance it adds is not a measured effort, so a goal run with one falls
  /// back to the clean-stretch rule. A long GPS drop is treated the same.
  List<_Pt>? _bridged(RunFile run, double goalM) {
    final pauses = [...run.pauses]..sort((a, b) => a.t0Ms - b.t0Ms);
    bool inside(List<Span> spans, int t) =>
        spans.any((b) => t >= b.t0Ms && t < b.t1Ms);
    // Moving clock: elapsed minus the pauses before it.
    int moving(int t) {
      var cut = 0;
      for (final p in pauses) {
        if (t >= p.t1Ms) {
          cut += p.durationMs;
        } else if (t > p.t0Ms) {
          cut += t - p.t0Ms;
        }
      }
      return t - cut;
    }

    final out = <_Pt>[];
    int? prevT;
    var lastClock = 0;
    var gapMs = 0;
    final (collapsed, after) = _collapse(run);
    for (final s in collapsed) {
      if (inside(pauses, s.tMs) || inside(run.gaps, s.tMs)) continue;
      final t = moving(s.tMs);
      gapMs = 0;
      if (prevT != null && out.isNotEmpty) {
        final dt = t - prevT;
        if (dt > constants.sampleGapInterruptMs ||
            (dt > minCountedHoleMs && after.contains(s.tMs))) {
          // A short GPS dropout is bridged like in any run (the window check
          // holds the total); a pause inside it or a long one is not.
          if (dt > maxBridgedGpsGapMs ||
              pauses.any((p) => p.overlaps(lastClock + 1, s.tMs))) {
            return null;
          }
          gapMs = dt;
        }
        if (dt > 0 && (s.distM - out.last.d) / (dt / 1000) > maxStepMps) {
          return null; // a GPS jump: not one honest effort
        }
      }
      if (run.gaps.any((g) => g.t1Ms <= s.tMs && out.isNotEmpty)) return null;
      final d = out.isEmpty || s.distM >= out.last.d ? s.distM : out.last.d;
      out.add(_Pt(t.toDouble(), d, s.tMs.toDouble(), gapMs));
      prevT = t;
      lastClock = s.tMs;
      if (d - out.first.d >= goalM) break;
    }
    var paused = 0;
    for (final p in pauses) {
      if (p.t0Ms < lastClock) paused += p.durationMs;
    }
    if (paused > maxBridgedInterruptMs) return null;
    return out.length >= 2 ? out : null;
  }

  /// The run clock at [t] on [p]'s own clock (the run clock itself unless
  /// [p] is a bridged stretch).
  static double _clockAt(List<_Pt> p, double t) {
    if (p.first.r == null) return t;
    if (t <= p.first.t) return p.first.r!;
    if (t >= p.last.t) return p.last.r!;
    var i = 0;
    while (p[i + 1].t < t) {
      i++;
    }
    final a = p[i];
    final b = p[i + 1];
    if (b.t == a.t) return a.r!;
    return a.r! + (t - a.t) / (b.t - a.t) * (b.r! - a.r!);
  }

  /// Why no 5K (a goal run's own distance) was found in a run that went far
  /// enough: the break nearest the middle of the run, which is the one a
  /// window cannot avoid. Null when the run is too short, has the effort,
  /// or shows no break.
  EffortMiss? _miss(
    RunFile run,
    List<_Pt> pts,
    double? goalM,
    Map<BestEffortDistance, BestEffort> efforts,
  ) {
    final need = goalM ?? BestEffortDistance.k5.metres;
    final total = pts.last.d - pts.first.d;
    if (total < need) return null;
    if (goalM != null
        ? efforts.containsKey(
            goalM == BestEffortDistance.k5.metres
                ? BestEffortDistance.k5
                : BestEffortDistance.k10,
          )
        : efforts.containsKey(BestEffortDistance.k5)) {
      return null;
    }
    final breaks = <_Break>[];
    double at(num t) => _dAtT(pts, t.toDouble()) - pts.first.d;
    for (final p in run.pauses) {
      breaks.add(_Break(at(p.t0Ms), EffortMissKind.pause));
    }
    for (final g in run.gaps) {
      breaks.add(_Break(at(g.t0Ms), EffortMissKind.recordingStopped));
    }
    final spans = [...run.pauses, ...run.gaps];
    // Dropouts: long ones cut for good; short ones were bridged, so they only
    // explain a miss when they add up past what one window may hold.
    final drops = _dropouts(run);
    final short = <_Dropout>[];
    for (final d in drops) {
      final from = d.fromD - pts.first.d;
      if (d.ms > maxBridgedGpsGapMs) {
        breaks.add(_Break(from, EffortMissKind.gpsDropped, ms: d.ms));
      } else if (d.bridgeable) {
        short.add(d);
      } else {
        breaks.add(_Break(from, EffortMissKind.gpsJump));
      }
    }
    final shortMs = short.fold<int>(0, (a, d) => a + d.ms);
    // What one window of the effort's length may hold (as in [_holesOk]).
    final windowMs = (pts.last.t - pts.first.t) * need / total;
    final allowance = windowMs * bridgedGpsShare;
    if (shortMs >
        (allowance > maxBridgedGpsTotalMs ? allowance : maxBridgedGpsTotalMs)) {
      breaks.add(
        _Break(
          short.first.fromD - pts.first.d,
          EffortMissKind.gpsDropped,
          ms: shortMs,
          n: short.length,
        ),
      );
    }
    Sample? prev;
    for (final s in _collapse(run).$1) {
      // Only steps between neighbouring samples; a dropout is judged above.
      if (prev != null &&
          s.tMs > prev.tMs &&
          s.tMs - prev.tMs <= constants.sampleGapInterruptMs &&
          !spans.any((b) => b.overlaps(prev!.tMs + 1, s.tMs)) &&
          (s.distM - prev.distM) / ((s.tMs - prev.tMs) / 1000) > maxStepMps) {
        breaks.add(_Break(prev.distM - pts.first.d, EffortMissKind.gpsJump));
      }
      prev = s;
    }
    for (final p in _cleanStretches(run)) {
      for (final (start, _) in _jumpSpans(p)) {
        breaks.add(
          _Break(_dAtT(p, start) - pts.first.d, EffortMissKind.gpsJump),
        );
      }
    }
    if (breaks.isEmpty) return null;
    // A goal run is bridged over short pauses: if pauses before the goal
    // distance add up past the limit and nothing else broke it, say so.
    if (goalM != null &&
        run.gaps.isEmpty &&
        !breaks.any(
          (b) =>
              b.kind == EffortMissKind.gpsJump ||
              b.kind == EffortMissKind.gpsDropped,
        )) {
      final reached = pts.firstWhere(
        (p) => p.d - pts.first.d >= goalM,
        orElse: () => pts.last,
      );
      var paused = 0;
      for (final p in run.pauses) {
        if (p.t0Ms < reached.t) paused += p.durationMs;
      }
      if (paused > maxBridgedInterruptMs) {
        return EffortMiss(EffortMissKind.pausedLong, goalM: goalM);
      }
    }
    // A goal run is bridged over pauses and gaps, so a jump is what stopped it.
    final jumps = [
      for (final b in breaks)
        if (b.kind == EffortMissKind.gpsJump) b,
    ];
    if (goalM != null && jumps.isNotEmpty) {
      breaks
        ..clear()
        ..addAll(jumps);
    }
    breaks.sort(
      (a, b) => (a.at - total / 2).abs().compareTo((b.at - total / 2).abs()),
    );
    final b = breaks.first;
    return EffortMiss(
      b.kind,
      atM: b.n > 1 ? null : b.at,
      goalM: goalM,
      durationMs: b.ms,
      drops: b.n,
    );
  }

  /// The event and GOAL runs (§G) are one continuous step from the Start
  /// press: the whole run is searched, not clipped to detected reps.
  static bool _searchWhole(RunAnalysis a) {
    final k = a.comparisonKey;
    return k != null && (ComparisonKey.isParkrun(k) || ComparisonKey.isGoal(k));
  }

  static bool _racesDistanceBoards(RunAnalysis a) => switch (a.mode) {
    RunMode.free || RunMode.laps => true,
    // Hill pace is not comparable with road pace: no distance boards for Trail.
    RunMode.cooper || RunMode.trail => false,
    RunMode.intervals => _searchWhole(a),
  };

  /// Longest from-Start ghost (a marathon goal, §G).
  static const int maxFromStartKm = 42;

  /// The most distance inside any [ms] window of a clean stretch, as
  /// (start time, metres, start distance); null when no stretch is that
  /// long. Distance over a fixed-length window is piecewise linear in its
  /// start, so starts and ends on samples are the candidates.
  static (double, double, double)? _mostDistance(
    List<List<_Pt>> pool,
    double ms,
  ) {
    (double, double, double)? best;
    void consider(double start, double metres, double startD) {
      if (best == null || metres > best!.$2 + 1e-6) {
        best = (start, metres, startD);
      }
    }

    // Distance at [t] with a forward-only cursor (both passes move
    // monotonically), so a pass is O(n).
    double at(List<_Pt> p, double t, List<int> cur) {
      var i = cur[0];
      while (i + 1 < p.length && p[i + 1].t < t) {
        i++;
      }
      cur[0] = i;
      if (t <= p.first.t) return p.first.d;
      if (t >= p.last.t) return p.last.d;
      final a = p[i];
      final b = p[i + 1];
      return a.d + (t - a.t) / (b.t - a.t) * (b.d - a.d);
    }

    for (final p in pool) {
      if (p.last.t - p.first.t < ms) continue;
      final fwd = [0];
      final back = [0];
      for (final q in p) {
        if (q.t + ms <= p.last.t) {
          consider(q.t, at(p, q.t + ms, fwd) - q.d, q.d);
        }
        if (q.t - ms >= p.first.t) {
          final d0 = at(p, q.t - ms, back);
          consider(q.t - ms, q.d - d0, d0);
        }
      }
    }
    return best;
  }

  /// Runs of consecutive samples with no pause, gap span, long sample gap
  /// or single-sample spike between them. Samples written inside a pause
  /// are dropped. With [bridge], a GPS dropout (see [maxBridgedGpsGapMs]) that
  /// is short and plausible does not cut the stretch: the samples written
  /// without a fix during it are dropped, so the distance runs straight from
  /// the last fix to the first one back, and that point carries the dropout's
  /// length in [_Pt.gapMs].
  List<List<_Pt>> _cleanStretches(RunFile run, {bool bridge = false}) {
    final breaks = [...run.pauses, ...run.gaps];
    bool inside(int t) => breaks.any((b) => t >= b.t0Ms && t < b.t1Ms);
    final out = <List<_Pt>>[];
    var cur = <_Pt>[];
    Sample? prev;
    final (collapsed, after) = bridge ? _collapse(run) : (run.samples, <int>{});
    for (final s in collapsed) {
      if (inside(s.tMs)) {
        prev = null;
        if (cur.length >= 2) out.add(cur);
        cur = [];
        continue;
      }
      var gapMs = 0;
      if (prev != null) {
        final dt = s.tMs - prev.tMs;
        final overlaps = breaks.any((b) => b.overlaps(prev!.tMs + 1, s.tMs));
        final step = (s.distM - prev.distM) / (dt / 1000);
        if (bridge &&
            !overlaps &&
            (after.contains(s.tMs) || dt > constants.sampleGapInterruptMs) &&
            dt <= maxBridgedGpsGapMs &&
            step <= maxStepMps) {
          gapMs = _isHole(after, s, dt) ? dt : 0;
        } else if (dt > constants.sampleGapInterruptMs ||
            overlaps ||
            step > maxStepMps) {
          if (cur.length >= 2) out.add(cur);
          cur = [];
        }
      }
      // Distance never runs backwards inside a stretch.
      final d = cur.isEmpty || s.distM >= cur.last.d ? s.distM : cur.last.d;
      cur.add(_Pt(s.tMs.toDouble(), d, null, gapMs));
      prev = s;
    }
    if (cur.length >= 2) out.add(cur);
    return out;
  }

  /// Whether [s] carries a usable position: lat/lon, and an accuracy the
  /// recorder's filter would accept. The recorder journals fixes it rejects
  /// for accuracy with lat/lon and the distance frozen, so they are a
  /// dropout too. ([EngineConstants.noFixAccuracyM] is held equal to the
  /// recorder's `PointFilter.maxAccuracyM` by a contract test.)
  bool _isFix(Sample s) =>
      s.hasFix && (s.accM == null || s.accM! <= constants.noFixAccuracyM);

  /// The samples with every run of no-fix ones between two fixes left out,
  /// and the times of the samples that follow such a run. The recorder writes
  /// a sample every second even with no fix, repeating the last distance, so
  /// a dropout is frozen distance and then one jump; with the no-fix samples
  /// out, the distance runs straight from the last fix to the first one back.
  /// How long it may be and whether it is plausible are for the caller.
  (List<Sample>, Set<int>) _collapse(RunFile run) {
    final src = run.samples;
    final out = <Sample>[];
    final after = <int>{};
    var i = 0;
    while (i < src.length) {
      out.add(src[i]);
      if (!_isFix(src[i])) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < src.length && !_isFix(src[j])) {
        j++;
      }
      if (j < src.length && j > i + 1) {
        i = j; // skip the no-fix samples between the two fixes
        after.add(src[j].tMs);
      } else {
        i++;
      }
    }
    return (out, after);
  }

  /// A hole shorter than this is a stray no-fix tick or two, normal GPS
  /// jitter: the distance runs straight across it and it is not counted.
  /// Longer ones count toward a window's allowance ([maxBridgedGpsTotalMs]).
  static const int minCountedHoleMs = 2000;

  /// A hole longer than this is also a dropout a window may not cut through
  /// (an edge inside it is refused); shorter ones are too brief for the
  /// interpolated edge to matter.
  static const int minTrackedDropoutMs = 5000;

  /// Whether the run holds any run of no-fix samples to collapse.
  bool _hasDropout(RunFile run) =>
      _collapse(run).$1.length != run.samples.length ||
      _dropouts(run).isNotEmpty;

  /// Every counted GPS dropout: more than [minCountedHoleMs] between
  /// two neighbouring fix samples (or a sample gap over
  /// [EngineConstants.sampleGapInterruptMs]) outside any pause or recording
  /// gap.
  List<_Dropout> _dropouts(RunFile run) {
    final spans = [...run.pauses, ...run.gaps];
    final out = <_Dropout>[];
    final (samples, after) = _collapse(run);
    Sample? prev;
    for (final s in samples) {
      final p = prev;
      prev = s;
      if (p == null) continue;
      final dt = s.tMs - p.tMs;
      if (!_isHole(after, s, dt) ||
          spans.any((b) => b.overlaps(p.tMs + 1, s.tMs))) {
        continue;
      }
      out.add(_Dropout(p.tMs, dt, p.distM, s.distM));
    }
    return out;
  }

  /// Whether the step to [s], [dt] after the previous sample, is a counted
  /// dropout (see [minCountedHoleMs]).
  bool _isHole(Set<int> after, Sample s, int dt) =>
      dt > constants.sampleGapInterruptMs ||
      (dt > minCountedHoleMs && after.contains(s.tMs));

  /// Removes every span where some 200 m was covered faster than 8 m/s, so
  /// no window can contain a GPS jump.
  List<List<_Pt>> _cutJumps(List<List<_Pt>> stretches) {
    final out = <List<_Pt>>[];
    for (final p in stretches) {
      final merged = _jumpSpans(p);
      if (merged.isEmpty) {
        out.add(p);
        continue;
      }
      var from = p.first.t;
      for (final b in merged) {
        _addClip(out, p, from, b.$1);
        from = b.$2;
      }
      _addClip(out, p, from, p.last.t);
    }
    return out;
  }

  /// The merged time spans of [p] where some 100 m or 200 m was covered
  /// faster than [speedCaps] allow.
  List<(double, double)> _jumpSpans(List<_Pt> p) {
    final bad = <(double, double)>[
      for (final (metres, mps) in speedCaps)
        for (final c in _candidates(p, metres))
          if (c.elapsed < metres / mps * 1000) (c.start, c.end),
    ];
    bad.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final b in bad) {
      if (merged.isNotEmpty && b.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, b.$2 > last.$2 ? b.$2 : last.$2));
      } else {
        merged.add(b);
      }
    }
    return merged;
  }

  List<List<_Pt>> _clipToWorkReps(List<List<_Pt>> stretches, RunAnalysis a) {
    final reps = a.intervals?.reps ?? const [];
    final out = <List<_Pt>>[];
    for (final r in reps) {
      if (!r.clean) continue;
      for (final s in stretches) {
        _addClip(out, s, r.lap.t0Ms.toDouble(), r.lap.t1Ms.toDouble());
      }
    }
    return out;
  }

  /// Adds the part of [p] inside `[a, b]`, edges interpolated, if any.
  static void _addClip(List<List<_Pt>> out, List<_Pt> p, double a, double b) {
    final lo = a > p.first.t ? a : p.first.t;
    final hi = b < p.last.t ? b : p.last.t;
    if (hi <= lo) return;
    // A bridged stretch keeps the run clock on its cut edges too.
    double? clock(double t) => p.first.r == null ? null : _clockAt(p, t);
    // A cut edge inside a bridged dropout keeps that dropout's length, so a
    // window ending there still counts (and is refused for) the whole of it.
    int gapAt(double t) {
      for (final q in p) {
        if (q.t >= t) return q.t > t ? q.gapMs : 0;
      }
      return 0;
    }

    final seg = <_Pt>[_Pt(lo, _dAtT(p, lo), clock(lo))];
    for (final q in p) {
      if (q.t > lo && q.t < hi) seg.add(q);
    }
    seg.add(_Pt(hi, _dAtT(p, hi), clock(hi), gapAt(hi)));
    out.add(seg);
  }

  /// Every candidate window of [metres] in [p]. The window time is
  /// piecewise linear in its start, so the fastest sits where the start or
  /// the end is on a sample: those are the candidates.
  static List<_Window> _candidates(List<_Pt> p, double metres) {
    final out = <_Window>[];
    if (p.last.d - p.first.d < metres) return out;
    var k = 0;
    for (var i = 0; i < p.length; i++) {
      final target = p[i].d + metres;
      if (p.last.d < target) break;
      if (k < i) k = i;
      while (p[k].d < target) {
        k++;
      }
      out.add(_Window(p[i].t, _tAtD(p, k, target), p[i].d));
    }
    k = 0;
    for (var j = 0; j < p.length; j++) {
      final target = p[j].d - metres;
      if (target < p.first.d) continue;
      while (k + 1 < p.length && p[k + 1].d <= target) {
        k++;
      }
      out.add(_Window(_tAtDBack(p, k, target), p[j].t, target));
    }
    return out;
  }

  /// The fastest window of [d] across [pool]; ties keep the earliest. Null
  /// when [pool] has no window of [d]. With [bridged], a window must hold
  /// every bridged dropout it touches whole, and those must add up to no more
  /// than the allowance (see [maxBridgedGpsTotalMs]).
  static (List<_Pt>, _Window)? _fastest(
    List<List<_Pt>> pool,
    BestEffortDistance d, {
    bool bridged = false,
  }) {
    (List<_Pt>, _Window)? best;
    for (final s in pool) {
      final holes = bridged
          ? [
              for (var i = 1; i < s.length; i++)
                if (s[i].gapMs > 0) (s[i - 1].t, s[i].t, s[i].gapMs),
            ]
          : const <(double, double, int)>[];
      for (final w in _candidates(s, d.metres)) {
        if (holes.isNotEmpty && !_holesOk(holes, w)) continue;
        final b = best?.$2;
        if (b == null ||
            w.elapsed < b.elapsed - 1e-6 ||
            (w.elapsed < b.elapsed + 1e-6 && w.start < b.start)) {
          best = (s, w);
        }
      }
    }
    return best;
  }

  /// Whether window [w] takes every dropout in [holes] (start, end, length)
  /// whole or not at all, and the ones it takes fit the allowance.
  static bool _holesOk(List<(double, double, int)> holes, _Window w) {
    var total = 0;
    for (final (a, b, ms) in holes) {
      if (w.end <= a + 1e-6 || w.start >= b - 1e-6) continue; // not touched
      if ((w.start > a + 1e-6 || w.end < b - 1e-6) &&
          ms > minTrackedDropoutMs) {
        return false; // an edge in it
      }
      total += ms;
    }
    final allowance = w.elapsed * bridgedGpsShare;
    return total <=
        (allowance > maxBridgedGpsTotalMs ? allowance : maxBridgedGpsTotalMs);
  }

  /// Times at each split mark strictly inside the window.
  static List<double> _splits(List<_Pt> p, _Window w, BestEffortDistance d) {
    final out = <double>[];
    var k = 0;
    for (
      var mark = d.splitEveryM;
      mark < d.metres - 1e-6;
      mark += d.splitEveryM
    ) {
      final target = w.startD + mark;
      while (p[k].d < target) {
        k++;
      }
      out.add(_tAtD(p, k, target));
    }
    return out;
  }

  /// Whole-km times from run time 0 inside the first clean stretch, which
  /// must start at the first sample; cut where that stretch ends.
  List<int> _fromStartSplits(RunFile run, List<List<_Pt>> stretches) {
    if (stretches.isEmpty) return const [];
    final p = stretches.first;
    final first = run.samples.first;
    if (p.first.t != first.tMs.toDouble() ||
        first.tMs > constants.sampleGapInterruptMs) {
      return const [];
    }
    final out = <int>[];
    var k = 0;
    for (var km = 1; km <= maxFromStartKm; km++) {
      final mark = first.distM + km * 1000.0;
      if (p.last.d < mark) break;
      while (p[k].d < mark) {
        k++;
      }
      out.add(_tAtD(p, k, mark).round());
    }
    return out;
  }

  /// Time where distance first reaches [d]; `p[k]` is the first point at or
  /// past it (k ≥ 1 unless `p[0]` already is).
  static double _tAtD(List<_Pt> p, int k, double d) {
    if (k == 0 || p[k].d == d) return p[k].t;
    final a = p[k - 1];
    final b = p[k];
    return a.t + (d - a.d) / (b.d - a.d) * (b.t - a.t);
  }

  /// Latest time distance is still [d]; `p[k]` is the last point at or
  /// below it.
  static double _tAtDBack(List<_Pt> p, int k, double d) {
    if (p[k].d == d || k + 1 >= p.length) return p[k].t;
    final a = p[k];
    final b = p[k + 1];
    return a.t + (d - a.d) / (b.d - a.d) * (b.t - a.t);
  }

  static double _dAtT(List<_Pt> p, double t) {
    if (t <= p.first.t) return p.first.d;
    if (t >= p.last.t) return p.last.d;
    var i = 0;
    while (p[i + 1].t < t) {
      i++;
    }
    final a = p[i];
    final b = p[i + 1];
    return a.d + (t - a.t) / (b.t - a.t) * (b.d - a.d);
  }
}

class _Pt {
  const _Pt(this.t, this.d, [this.r, this.gapMs = 0]);
  final double t;
  final double d;

  /// How long the bridged GPS dropout that ends at this point lasted, ms;
  /// 0 when the step from the previous point is ordinary.
  final int gapMs;

  /// The run's own clock at this point when [t] is moving time (a bridged
  /// goal run); null when [t] already is the run clock.
  final double? r;
}

class _Window {
  const _Window(this.start, this.end, this.startD);
  final double start;
  final double end;
  final double startD;
  double get elapsed => end - start;
}

/// A GPS dropout: no fix for [ms] after the fix at [tMs].
class _Dropout {
  const _Dropout(this.tMs, this.ms, this.fromD, this.toD);
  final int tMs;
  final int ms;
  final double fromD;
  final double toD;

  /// Short and plausible enough to bridge (see
  /// [BestEffortFinder.maxBridgedGpsGapMs]).
  bool get bridgeable =>
      ms <= BestEffortFinder.maxBridgedGpsGapMs &&
      (toD - fromD) / (ms / 1000) <= BestEffortFinder.maxStepMps;
}

/// One thing that cut a run's 5K/10K, for picking the miss reason.
class _Break {
  const _Break(this.at, this.kind, {this.ms, this.n = 1});
  final double at;
  final EffortMissKind kind;

  /// Dropout length (all of them when [n] is more than one), ms.
  final int? ms;
  final int n;
}
