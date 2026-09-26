import '../model/run_file.dart';
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
  /// Faster than the run's own evidence allows (plan §3.1 GPS guard): a
  /// piece of the window far faster than the window's median piece, or the
  /// window > 12% faster than the fastest verified lap or rep.
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
/// §3.1, LB1). Pure and O(n) per distance.
///
/// Distance is the recorder's own filtered, pause-frozen `distM` stream,
/// the one native ranks live, never a re-filtered one (BLOCK-2). Window
/// edges between samples are linearly interpolated (the I2 distance-step
/// rule); lap edges are placed by interpolating that stream at the lap's
/// time, never read from the stored lap distance (P2-a).
///
/// A window qualifies only inside one clean stretch: no pause, no
/// kill→resume gap, no sample gap > [EngineConstants.sampleGapInterruptMs],
/// and no GPS jump (any 200 m covered faster than [maxSpeedMps]). In an
/// intervals session the window must also lie inside one clean work rep, so
/// a 1 km repeat can set a 1 km best, a parkrun (one 5 km step) a 5K, and a
/// 4x4 never a 5K. Indoor and noisy runs get nothing (the verdict gates).
class BestEffortFinder {
  const BestEffortFinder([this.constants = EngineConstants.defaults]);

  final EngineConstants constants;

  /// A jump: 200 m faster than 8 m/s (25 s) anywhere is not running.
  static const double jumpWindowM = 200;
  static const double maxSpeedMps = 8;

  /// Consistency guard, every run (WARN-7): no piece of the window may be
  /// more than this speed ratio faster than the window's own median piece.
  /// Pieces are whole kms for 5K/10K and 200 m for 1 km/mile (a short
  /// window needs a finer grain to see a jump; 200 m pieces vary more, so
  /// the ratio is looser). The window's own median, not the run's: a Free
  /// run with an easy warm-up and a hard 5K must keep its 5K. Seeded;
  /// calibrated on founder runs (plan §8).
  static const double maxRatioVsMedianKm = 1.15;
  static const double maxRatioVsMedian200m = 1.25;
  static const double finePieceM = 200;

  /// Runs with verified laps or reps: the window may also not be more than
  /// this speed ratio faster than the fastest of them.
  static const double maxRatioVsFastestLap = 1.12;

  RunBestEfforts find(RunFile run, RunAnalysis analysis) {
    if (analysis.indoor || analysis.noisy) return RunBestEfforts.none;
    final pts = [for (final s in run.samples) _Pt(s.tMs.toDouble(), s.distM)];
    if (pts.length < 2) return RunBestEfforts.none;

    final stretches = _cutJumps(_cleanStretches(run));
    final pool = analysis.mode == RunMode.intervals
        ? _clipToWorkReps(stretches, analysis)
        : stretches;

    final lapRef = _fastestVerifiedMps(analysis);

    final efforts = <BestEffortDistance, BestEffort>{};
    final rejected = <BestEffortDistance, BestEffortRejection>{};
    for (final d in BestEffortDistance.values) {
      _Window? best;
      List<_Pt>? home;
      for (final s in pool) {
        final w = _fastest(s, d.metres);
        if (w != null && (best == null || w.elapsed < best.elapsed)) {
          best = w;
          home = s;
        }
      }
      if (best == null) continue;
      final splits = _splits(home!, best, d);
      if (!_passesGuard(home, d, best, lapRef)) {
        rejected[d] = BestEffortRejection.gpsGuard;
        continue;
      }
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

  static bool _racesDistanceBoards(RunAnalysis a) => switch (a.mode) {
    RunMode.free || RunMode.laps => true,
    RunMode.cooper => false,
    RunMode.intervals =>
      a.comparisonKey != null && a.comparisonKey!.startsWith('parkrun'),
  };

  /// Runs of consecutive samples with no pause, gap span or long sample gap
  /// between them. Samples written inside a pause are dropped.
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
              breaks.any((b) => b.overlaps(prev!.tMs + 1, s.tMs)))) {
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
      final bad = <(double, double)>[];
      var k = 0;
      for (var i = 0; i < p.length; i++) {
        final target = p[i].d + jumpWindowM;
        if (p.last.d < target) break;
        if (k < i) k = i;
        while (p[k].d < target) {
          k++;
        }
        final t = _tAtD(p, k, target);
        if (t - p[i].t < jumpWindowM / maxSpeedMps * 1000) {
          bad.add((p[i].t, t));
        }
      }
      k = 0;
      for (var j = 0; j < p.length; j++) {
        final target = p[j].d - jumpWindowM;
        if (target < p.first.d) continue;
        while (k + 1 < p.length && p[k + 1].d <= target) {
          k++;
        }
        final s = _tAtDBack(p, k, target);
        if (p[j].t - s < jumpWindowM / maxSpeedMps * 1000) bad.add((s, p[j].t));
      }
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
      if (r.interrupted || r.dropped) continue;
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

  /// The fastest window of [metres] in [p]. The window time is piecewise
  /// linear in its start, so the minimum sits where the start or the end is
  /// on a sample: both are tried. Ties keep the earliest window.
  static _Window? _fastest(List<_Pt> p, double metres) {
    if (p.last.d - p.first.d < metres) return null;
    _Window? best;
    void consider(double s, double sd, double e) {
      if (best == null || e - s < best!.elapsed - 1e-6) {
        best = _Window(s, e, sd);
      }
    }

    var k = 0;
    for (var i = 0; i < p.length; i++) {
      final target = p[i].d + metres;
      if (p.last.d < target) break;
      if (k < i) k = i;
      while (p[k].d < target) {
        k++;
      }
      consider(p[i].t, p[i].d, _tAtD(p, k, target));
    }
    k = 0;
    for (var j = 0; j < p.length; j++) {
      final target = p[j].d - metres;
      if (target < p.first.d) continue;
      while (k + 1 < p.length && p[k + 1].d <= target) {
        k++;
      }
      consider(_tAtDBack(p, k, target), target, p[j].t);
    }
    return best;
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

  bool _passesGuard(
    List<_Pt> p,
    BestEffortDistance d,
    _Window w,
    double? lapRefMps,
  ) {
    final mps = d.metres / (w.elapsed / 1000);
    if (lapRefMps != null && mps > lapRefMps * maxRatioVsFastestLap) {
      return false;
    }
    final fine = d.splitEveryM != 1000;
    final piece = fine ? finePieceM : 1000.0;
    final ratio = fine ? maxRatioVsMedian200m : maxRatioVsMedianKm;
    final speeds = <double>[];
    var k = 0;
    var prevT = w.start;
    var prevD = 0.0;
    for (var mark = piece; mark <= d.metres + 1e-6; mark += piece) {
      final m = mark > d.metres ? d.metres : mark;
      while (p[k].d < w.startD + m - 1e-9) {
        k++;
      }
      final t = m == d.metres ? w.end : _tAtD(p, k, w.startD + m);
      if (t > prevT) speeds.add((m - prevD) / ((t - prevT) / 1000));
      prevT = t;
      prevD = m;
    }
    // A mile's last 9 m is too short to judge; ignored.
    if (speeds.length < 2) return true;
    final sorted = [...speeds]..sort();
    final h = sorted.length ~/ 2;
    final median = sorted.length.isOdd
        ? sorted[h]
        : (sorted[h - 1] + sorted[h]) / 2;
    return speeds.every((v) => v <= median * ratio);
  }

  /// Fastest scored lap (Laps) or clean rep (intervals), m/s; null when the
  /// run has none.
  static double? _fastestVerifiedMps(RunAnalysis a) {
    final paces = <double>[
      if (a.laps != null)
        for (final l in a.laps!.laps)
          if (l.scored && l.paceSecPerKm != null) l.paceSecPerKm!,
      if (a.intervals != null)
        for (final r in a.intervals!.reps)
          if (r.clean) r.paceSecPerKm!,
    ];
    if (paces.isEmpty) return null;
    final fastest = paces.reduce((x, y) => x < y ? x : y);
    return fastest <= 0 ? null : 1000 / fastest;
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
