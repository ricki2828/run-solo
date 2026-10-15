/// The `trail` block of a run's companion summary (`POST /v1/runs`, see
/// `companion-server/README.md` "Trail block"): where this run ranks among
/// the runner's own runs of the same trail, the trail's elevation profile and
/// how far ahead or behind their old best they were along it.
///
/// Pure: the grouping, the like-for-like times and the ranks come from the
/// engine (`Trails.group`, `TrailGroup.normMs`, the heat-adjusted pace over
/// the trail's distance), the profile and the gap from the run files handed
/// in. Whole numbers only, no coordinates, no dates.
library;

import 'dart:math' as math;

import 'package:run_engine/run_engine.dart' as engine;

/// Caps from the server's validation (`companion/trail.py`).
const int kTrailBoardRows = 10;
const int kTrailPoints = 64;
const int kTrailMinRuns = 3;
const int kTrailNameMax = 30;

/// The group [runId] is in, or null when it is on no known trail.
engine.TrailGroup? trailGroupOf(
  String runId,
  Iterable<engine.TrailRunFacts> runs,
) => engine.Trails.groupOf(runId, engine.Trails.group(runs));

/// The fastest run on [g] before [runId] (like for like), or null for none.
engine.TrailRunFacts? priorBestOf(engine.TrailGroup g, String runId) {
  final me = g.runs.where((r) => r.id == runId);
  if (me.isEmpty) return null;
  final start = me.first.start;
  engine.TrailRunFacts? best;
  for (final r in g.runs) {
    if (r.id == runId || !r.start.isBefore(start)) continue;
    if (best == null || g.normMs(r) < g.normMs(best)) best = r;
  }
  return best;
}

/// The trail block for [run] (id [runId]) among [runs], or null: not on a
/// known trail, or fewer than [kTrailMinRuns] runs on it (the board starts
/// from the 3rd). [priorBest] is the run file of [priorBestOf]; without it
/// there is no `ghost_gap`. [names] is the "Show trail names on cards"
/// switch.
Map<String, Object?>? trailBlock({
  required String runId,
  required Iterable<engine.TrailRunFacts> runs,
  required engine.RunFile run,
  engine.RunFile? priorBest,
  bool names = false,
}) {
  final g = trailGroupOf(runId, runs);
  if (g == null || g.runs.length < kTrailMinRuns) return null;
  final n = g.runs.length;
  final board = _board(g, runId);
  if (board == null) return null;

  final geo = engine.TrailGhostBuilder.geometry(run);
  final path = geo == null ? null : engine.GhostPath(geo);
  final prof = _profile(run, geo, path);

  final gap = path == null || priorBest == null
      ? null
      : _ghostGap(path, run, priorBest);
  final turnM = geo == null ? null : engine.TrailGhostBuilder.turnaround(geo);
  final shape = turnM != null
      ? 'out_and_back'
      : (g.anchor.route?.isLoop ?? false)
      ? 'loop'
      : 'one_way';
  final name = names ? _name(g.name) : null;
  return {
    'n': n,
    'board': board,
    if (prof != null) ...{
      'profile': prof,
      'elev_src': run.elevSrc == engine.ElevSource.baro ? 'baro' : 'gps',
      if (turnM != null && path != null && path.totalM > 0)
        'turn': (turnM / path.totalM * (prof.length - 1)).round().clamp(
          0,
          prof.length - 1,
        ),
    },
    'ghost_gap': ?gap,
    'shape': shape,
    'name': ?name,
  };
}

/// At most [kTrailBoardRows] rows: the best run, today and the nearest rows,
/// each with its TRUE rank among all runs (ties share the better rank).
List<Map<String, Object?>>? _board(engine.TrailGroup g, String runId) {
  final rows = <({int attempt, int timeS, int rank, bool today})>[];
  final times = [for (final r in g.runs) g.normMs(r)];
  for (var i = 0; i < g.runs.length; i++) {
    final rank = 1 + times.where((t) => t < times[i]).length;
    rows.add((
      attempt: i + 1,
      timeS: (times[i] / 1000).round().clamp(1, 86400),
      rank: rank,
      today: g.runs[i].id == runId,
    ));
  }
  final today = rows.where((r) => r.today);
  if (today.isEmpty) return null;
  final todayRank = today.first.rank;
  final picked = <int>{};
  if (rows.length <= kTrailBoardRows) {
    picked.addAll([for (var i = 0; i < rows.length; i++) i]);
  } else {
    picked.add(rows.indexOf(today.first));
    final bestI = rows.indexWhere((r) => r.rank == 1);
    picked.add(bestI);
    final rest =
        [
          for (var i = 0; i < rows.length; i++)
            if (!picked.contains(i)) i,
        ]..sort((a, b) {
          final da = (rows[a].rank - todayRank).abs();
          final db = (rows[b].rank - todayRank).abs();
          return da != db ? da.compareTo(db) : a.compareTo(b);
        });
    for (final i in rest) {
      if (picked.length >= kTrailBoardRows) break;
      picked.add(i);
    }
  }
  final out = [for (final i in picked) rows[i]]
    ..sort((a, b) {
      final c = a.rank.compareTo(b.rank);
      return c != 0 ? c : a.attempt.compareTo(b.attempt);
    });
  return [
    for (final r in out)
      {
        'attempt': r.attempt,
        'time_s': r.timeS,
        if (r.today) 'today': true,
        'rank': r.rank,
      },
  ];
}

/// The elevation profile in metres relative to the start, at most
/// [kTrailPoints] evenly spaced ints; null without usable elevation. The
/// trail's smoothed ghost elevation when the run has a track, else the run's
/// own elevation points.
List<int>? _profile(
  engine.RunFile run,
  List<double>? geo,
  engine.GhostPath? path,
) {
  List<double>? vals;
  if (geo != null && path != null) {
    vals = engine.TrailGhostBuilder.elevation(path, run)?.elevM;
  }
  if (vals == null) {
    final pts = engine.RunElevation.of(run)?.points;
    if (pts != null && pts.length >= 2) {
      vals = _byDistance([for (final p in pts) (p.distM, p.elevM)]);
    }
  }
  if (vals == null || vals.length < 2) return null;
  final even = _resample(vals);
  return [for (final v in even) (v - even.first).round().clamp(-2000, 9000)];
}

/// Seconds ahead (+) or behind (-) of [best] at the same progress along
/// [path], at most [kTrailPoints] values; null when the two runs share fewer
/// than two reached vertices.
List<int>? _ghostGap(
  engine.GhostPath path,
  engine.RunFile run,
  engine.RunFile best,
) {
  final now = engine.TrailGhostBuilder.profile(path, run);
  final then = engine.TrailGhostBuilder.profile(path, best);
  if (now == null || then == null) return null;
  final gaps = <double>[
    for (var i = 0; i < path.size; i++)
      if (now[i] >= 0 && then[i] >= 0) (then[i] - now[i]) / 1000,
  ];
  if (gaps.length < 2) return null;
  return [for (final v in _resample(gaps)) v.round().clamp(-3600, 3600)];
}

/// [vals] (evenly spaced) cut to at most [kTrailPoints] by linear
/// interpolation; shorter lists are kept as they are.
List<double> _resample(List<double> vals) {
  if (vals.length <= kTrailPoints) return vals;
  final step = (vals.length - 1) / (kTrailPoints - 1);
  return [
    for (var k = 0; k < kTrailPoints; k++)
      () {
        final pos = k * step;
        final i = math.min(pos.floor(), vals.length - 2);
        final f = pos - i;
        return vals[i] + (vals[i + 1] - vals[i]) * f;
      }(),
  ];
}

/// (distance, value) pairs onto an even distance grid of [kTrailPoints].
List<double>? _byDistance(List<(double, double)> pts) {
  final total = pts.last.$1 - pts.first.$1;
  if (total <= 0) return null;
  final out = <double>[];
  var j = 0;
  for (var k = 0; k < kTrailPoints; k++) {
    final d = pts.first.$1 + total * k / (kTrailPoints - 1);
    while (j + 1 < pts.length - 1 && pts[j + 1].$1 < d) {
      j++;
    }
    final span = pts[j + 1].$1 - pts[j].$1;
    final f = span <= 0 ? 0.0 : ((d - pts[j].$1) / span).clamp(0.0, 1.0);
    out.add(pts[j].$2 + (pts[j + 1].$2 - pts[j].$2) * f);
  }
  return out;
}

String? _name(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  return t.length <= kTrailNameMax ? t : t.substring(0, kTrailNameMax).trim();
}
