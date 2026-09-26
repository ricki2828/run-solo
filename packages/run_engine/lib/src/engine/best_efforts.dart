import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../run_mode.dart';
import 'analysis.dart';
import 'constants.dart';
import 'trace.dart';

/// A distance a best effort is found for (Phase 4 plan §3.1). Board keys use
/// the reserved `be:` prefix, never a comparison key.
enum BestEffortDistance {
  km1('be:1000', 1000, 400),
  mile('be:1609', 1609.344, 400),
  k5('be:5000', 5000, 1000),
  k10('be:10000', 10000, 1000);

  const BestEffortDistance(this.key, this.metres, this.splitEveryM);

  final String key;
  final double metres;

  /// Cumulative splits are taken every this many metres inside the window.
  final double splitEveryM;

  static const String keyPrefix = 'be:';

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
  });

  final BestEffortDistance distance;
  final int elapsedMs;

  /// Window start, ms since the run's start.
  final int startMs;

  /// Distance covered before the window started (0 = from the first metre).
  final double startOffsetM;

  /// Cumulative time from the window start at every [BestEffortDistance.
  /// splitEveryM] strictly inside the window (the finish is [elapsedMs]).
  final List<int> splitsMs;
  final double? avgHr;

  int get endMs => startMs + elapsedMs;

  double get paceSecPerKm => elapsedMs / distance.metres;

  Map<String, Object?> toJson() => {
    'elapsed_ms': elapsedMs,
    'start_ms': startMs,
    'start_offset_m': double.parse(startOffsetM.toStringAsFixed(1)),
    'splits_ms': splitsMs,
    'avg_hr': avgHr == null ? null : double.parse(avgHr!.toStringAsFixed(1)),
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
  );
}

/// Why a run has no best effort for a distance it covered.
enum BestEffortRejection {
  /// Every window of this distance holds a piece far faster than the
  /// window's own average (plan §3.1 GPS guard).
  gpsGuard,
}

/// Everything LB1 derives from one run: the board windows and the
/// from-start splits live compare races against (plan §3.1, WARN-1).
class RunBestEfforts {
  const RunBestEfforts({
    required this.efforts,
    required this.fromStartSplitsMs,
    this.rejected = const {},
  });

  static const RunBestEfforts none = RunBestEfforts(
    efforts: {},
    fromStartSplitsMs: [],
  );

  /// Best window per distance; a distance the run never covered cleanly is
  /// absent.
  final Map<BestEffortDistance, BestEffort> efforts;

  /// Cumulative time from the Start press (run time 0) at each whole km, up
  /// to 10, cut at the first pause, recording gap, sample gap or GPS jump.
  /// Live compare uses the first 5 for the 5K board and all 10 for the 10K
  /// board, and only when the list is that long. Empty for sessions that
  /// race no distance board (intervals other than parkrun, Cooper).
  final List<int> fromStartSplitsMs;

  /// Distances whose fastest window failed the GPS guard.
  final Map<BestEffortDistance, BestEffortRejection> rejected;

  Map<String, Object?> toJson() => {
    'efforts': {for (final e in efforts.values) e.distance.key: e.toJson()},
    'from_start_splits_ms': fromStartSplitsMs,
    'rejected': {for (final r in rejected.entries) r.key.key: r.value.name},
  };

  factory RunBestEfforts.fromJson(Map<String, Object?> json) {
    final efforts = <BestEffortDistance, BestEffort>{};
    for (final e in (json['efforts'] as Map).entries) {
      final d = BestEffortDistance.ofKey(e.key as String);
      if (d == null) continue; // a newer engine's distance: ignore
      efforts[d] = BestEffort.fromJson(d, e.value as Map<String, Object?>);
    }
    final rejected = <BestEffortDistance, BestEffortRejection>{};
    for (final e in ((json['rejected'] as Map?) ?? const {}).entries) {
      final d = BestEffortDistance.ofKey(e.key as String);
      final r = BestEffortRejection.values
          .where((v) => v.name == e.value)
          .firstOrNull;
      if (d != null && r != null) rejected[d] = r;
    }
    return RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: [
        for (final s in (json['from_start_splits_ms'] as List? ?? const []))
          s as int,
      ],
      rejected: rejected,
    );
  }
}

/// Finds the fastest 1 km, mile, 5K and 10K inside any run (Phase 4 plan
/// §3.1, LB1). Pure; O(n log n) per distance (candidates are sorted so a
/// window failing the guard falls back to the next-fastest).
///
/// Distance is the recorder's own filtered, pause-frozen `distM` stream,
/// the one native ranks live, never a re-filtered one (BLOCK-2). Window
/// edges between samples are linearly interpolated (the I2 distance-step
/// rule); lap edges are placed by interpolating that stream at the lap's
/// time, never read from the stored lap distance (P2-a).
///
/// A window qualifies only inside one clean stretch: no pause, no
/// kill→resume gap, no sample gap > [EngineConstants.sampleGapInterruptMs],
/// and no GPS jump (one sample step faster than [maxStepMps], or a break
/// of any [speedCaps]). In an
/// intervals session the window must also lie inside one clean work rep, so
/// a 1 km repeat can set a 1 km best and a 4x4 never a 5K; a parkrun (one
/// continuous 5 km step from Start) is searched whole. Indoor and noisy runs get nothing (the verdict gates).
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

  /// Consistency guard for 5K and 10K (WARN-7): the window's fastest km,
  /// at any alignment, may not be more than this speed ratio above the
  /// window's own average. The window's own, not the run's: a Free run with
  /// an easy warm-up and a hard 5K must keep its 5K. Set above a genuine
  /// finishing kick (a 4:15 last km after 5:00s reads 1.14; review #31).
  /// 1 km and mile windows get no ratio check: a short window mixing jog
  /// and a real sprint finish reads far above its average, so there the
  /// plausibility caps ([speedCaps], [maxStepMps]) are the guard. Seeded;
  /// calibrated on founder runs (plan §8).
  static const double maxRatioVsWindowKm = 1.25;

  /// A window that fails the guard falls back to the next-fastest window;
  /// this bounds the search on a pathological trace.
  static const int maxGuardAttempts = 400;

  RunBestEfforts find(RunFile run, RunAnalysis analysis) {
    if (analysis.indoor || analysis.noisy) return RunBestEfforts.none;
    final pts = [for (final s in run.samples) _Pt(s.tMs.toDouble(), s.distM)];
    if (pts.length < 2) return RunBestEfforts.none;

    final stretches = _cutJumps(_cleanStretches(run));
    // A parkrun is one continuous 5 km step from the Start press, so the
    // whole run is its work; it does not wait on rep detection (a
    // single-lap session has none).
    final pool = analysis.mode == RunMode.intervals && !_isParkrun(analysis)
        ? _clipToWorkReps(stretches, analysis)
        : stretches;

    final efforts = <BestEffortDistance, BestEffort>{};
    final rejected = <BestEffortDistance, BestEffortRejection>{};
    for (final d in BestEffortDistance.values) {
      final found = _fastestPassing(pool, d);
      if (found == null) continue;
      final (home, best, ok) = found;
      if (!ok) {
        rejected[d] = BestEffortRejection.gpsGuard;
        continue;
      }
      final splits = _splits(home, best, d);
      final startMs = best.start.round();
      final endMs = best.end.round();
      efforts[d] = BestEffort(
        distance: d,
        elapsedMs: endMs - startMs,
        startMs: startMs,
        startOffsetM: best.startD - pts.first.d,
        splitsMs: [for (final t in splits) (t - best.start).round()],
        avgHr: run.hasHr ? Trace(run.samples).meanHr(startMs, endMs) : null,
      );
    }
    return RunBestEfforts(
      efforts: efforts,
      fromStartSplitsMs: _racesDistanceBoards(analysis)
          ? _fromStartSplits(run, stretches)
          : const [],
      rejected: rejected,
    );
  }

  static bool _isParkrun(RunAnalysis a) =>
      a.comparisonKey != null && ComparisonKey.isParkrun(a.comparisonKey!);

  static bool _racesDistanceBoards(RunAnalysis a) => switch (a.mode) {
    RunMode.free || RunMode.laps => true,
    RunMode.cooper => false,
    RunMode.intervals => _isParkrun(a),
  };

  /// Runs of consecutive samples with no pause, gap span, long sample gap
  /// or single-sample spike between them. Samples written inside a pause
  /// are dropped.
  List<List<_Pt>> _cleanStretches(RunFile run) {
    final breaks = [...run.pauses, ...run.gaps];
    bool inside(int t) => breaks.any((b) => t >= b.t0Ms && t < b.t1Ms);
    final out = <List<_Pt>>[];
    var cur = <_Pt>[];
    Sample? prev;
    for (final s in run.samples) {
      if (inside(s.tMs)) {
        prev = null;
        if (cur.length >= 2) out.add(cur);
        cur = [];
        continue;
      }
      if (prev != null &&
          (s.tMs - prev.tMs > constants.sampleGapInterruptMs ||
              breaks.any((b) => b.overlaps(prev!.tMs + 1, s.tMs)) ||
              (s.distM - prev.distM) / ((s.tMs - prev.tMs) / 1000) >
                  maxStepMps)) {
        if (cur.length >= 2) out.add(cur);
        cur = [];
      }
      // Distance never runs backwards inside a stretch.
      final d = cur.isEmpty || s.distM >= cur.last.d ? s.distM : cur.last.d;
      cur.add(_Pt(s.tMs.toDouble(), d));
      prev = s;
    }
    if (cur.length >= 2) out.add(cur);
    return out;
  }

  /// Removes every span where some 200 m was covered faster than 8 m/s, so
  /// no window can contain a GPS jump.
  List<List<_Pt>> _cutJumps(List<List<_Pt>> stretches) {
    final out = <List<_Pt>>[];
    for (final p in stretches) {
      final bad = <(double, double)>[
        for (final (metres, mps) in speedCaps)
          for (final c in _candidates(p, metres))
            if (c.elapsed < metres / mps * 1000) (c.start, c.end),
      ];
      if (bad.isEmpty) {
        out.add(p);
        continue;
      }
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
      var from = p.first.t;
      for (final b in merged) {
        _addClip(out, p, from, b.$1);
        from = b.$2;
      }
      _addClip(out, p, from, p.last.t);
    }
    return out;
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
    final seg = <_Pt>[_Pt(lo, _dAtT(p, lo))];
    for (final q in p) {
      if (q.t > lo && q.t < hi) seg.add(q);
    }
    seg.add(_Pt(hi, _dAtT(p, hi)));
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

  /// The fastest window of [d] across [pool] that passes the guard (ties
  /// keep the earliest). The usual case is one O(n) scan and one check;
  /// only when the fastest fails are all candidates sorted and tried in
  /// order. A failing window marks its offending piece, and every later
  /// candidate holding that piece is skipped, so a jump costs a few checks,
  /// not one per sample. Null when [pool] has no window of [d];
  /// `ok == false` when none passes.
  (List<_Pt>, _Window, bool)? _fastestPassing(
    List<List<_Pt>> pool,
    BestEffortDistance d,
  ) {
    final all = <(List<_Pt>, _Window)>[
      for (final s in pool)
        for (final w in _candidates(s, d.metres)) (s, w),
    ];
    if (all.isEmpty) return null;
    int order((List<_Pt>, _Window) a, (List<_Pt>, _Window) b) {
      final c = a.$2.elapsed.compareTo(b.$2.elapsed);
      return c != 0 ? c : a.$2.start.compareTo(b.$2.start);
    }

    var first = all.first;
    for (final c in all) {
      if (order(c, first) < 0) first = c;
    }
    final firstFail = _guardFailure(first.$1, d, first.$2);
    if (firstFail == null) return (first.$1, first.$2, true);
    all.sort(order);
    final bad = <(double, double)>[firstFail];
    var attempts = 1;
    for (final (home, w) in all) {
      if (bad.any((b) => w.start <= b.$1 && w.end >= b.$2)) continue;
      if (++attempts > maxGuardAttempts) break;
      final fail = _guardFailure(home, d, w);
      if (fail == null) return (home, w, true);
      bad.add(fail);
    }
    return (first.$1, first.$2, false);
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

  /// The span of the window's fastest piece when that piece is too fast
  /// for the window's average speed, else null. The piece slides (any
  /// alignment), so a smeared jump cannot hide across two fixed pieces.
  (double, double)? _guardFailure(
    List<_Pt> p,
    BestEffortDistance d,
    _Window w,
  ) {
    if (d.splitEveryM != 1000) return null;
    const piece = 1000.0;
    const ratio = maxRatioVsWindowKm;
    final inside = <List<_Pt>>[];
    _addClip(inside, p, w.start, w.end);
    if (inside.isEmpty) return null;
    _Window? fastest;
    for (final c in _candidates(inside.single, piece)) {
      if (fastest == null || c.elapsed < fastest.elapsed) fastest = c;
    }
    if (fastest == null) return null;
    final avg = d.metres / w.elapsed;
    final top = piece / fastest.elapsed;
    return top > avg * ratio ? (fastest.start, fastest.end) : null;
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
    for (var km = 1; km <= 10; km++) {
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
  const _Pt(this.t, this.d);
  final double t;
  final double d;
}

class _Window {
  const _Window(this.start, this.end, this.startD);
  final double start;
  final double end;
  final double startD;
  double get elapsed => end - start;
}
