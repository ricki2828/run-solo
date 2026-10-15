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

/// A block goes from the 2nd run on (a trail record needs two rows). The
/// server draws a board only from the 3rd run (`card_kind`), so n = 2 can
/// never become a board.
const int kTrailMinRuns = 2;
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

/// [g] as it stood at [runId]'s own run: later runs left out, so a run that
/// uploads late still reads as run N of N. Null when [runId] is not on [g].
engine.TrailGroup? trailAsOf(engine.TrailGroup g, String runId) {
  final me = g.runs.where((r) => r.id == runId);
  if (me.isEmpty) return null;
  final start = me.first.start;
  return engine.TrailGroup(
    key: g.key,
    name: g.name,
    anchorId: g.anchorId,
    runs: [
      for (final r in g.runs)
        if (!r.start.isAfter(start)) r,
    ],
  );
}

/// The trail block for [run] (id [runId]) on trail [group], or null when the
/// run is not on it or it has fewer than [kTrailMinRuns] runs up to this one.
/// [priorBest] is the run file of [priorBestOf]; without it there is no
/// `ghost_gap`. [names] is the "Show trail names on cards" switch.
/// [heartZones] is non-null only while the "Heart rate on cards" switch is on
/// (the runner's own zones): the block then carries `hr` and `hr_z` when the
/// run had a strap, and never otherwise.
Map<String, Object?>? trailBlock({
  required String runId,
  required engine.TrailGroup group,
  required engine.RunFile run,
  engine.RunFile? priorBest,
  bool names = false,
  engine.HrZones? heartZones,
}) {
  final g = trailAsOf(group, runId);
  if (g == null || g.runs.length < kTrailMinRuns) return null;
  final n = g.runs.length;
  final board = _board(g, runId);
  if (board == null) return null;

  final geo = engine.TrailGhostBuilder.geometry(run);
  final path = geo == null ? null : engine.GhostPath(geo);
  final prof = _profile(run, geo, path);

  final priorFacts = priorBestOf(g, runId);
  final todayFacts = g.runs.firstWhere((r) => r.id == runId);
  final gap = path == null || priorBest == null || priorFacts == null
      ? null
      : _ghostGap(path, run, priorBest, todayFacts, priorFacts, g);
  final turnM = geo == null ? null : engine.TrailGhostBuilder.turnaround(geo);
  final shape = turnM != null
      ? 'out_and_back'
      : (g.anchor.route?.isLoop ?? false)
      ? 'loop'
      : 'one_way';
  final name = names ? _name(g) : null;
  final heart = heartZones == null || prof == null
      ? null
      : heartSeries(run, prof.length, heartZones);
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
    if (heart != null) ...{'hr': heart.bpm, 'hr_z': heart.zones},
  };
}

/// Caps from the server's validation (`companion/trail.py`): one bpm is a
/// whole number in this range.
const int kHrMin = 30;
const int kHrMax = 250;

/// The runner's heart rate along the run, [points] values on the same
/// progress axis as the profile (the profile's point k sits at
/// `k / (points - 1)` of the run's distance), each with the runner's own zone
/// (1-5) from [zones]. Each point is the mean of the strap readings nearest
/// it. Null without a strap: under 70% of the points reached by a reading in
/// [kHrMin]..[kHrMax], or no distance. Holes take the nearest read value.
({List<int> bpm, List<int> zones})? heartSeries(
  engine.RunFile run,
  int points,
  engine.HrZones zones,
) {
  if (points < 2 || run.samples.isEmpty) return null;
  final total = run.samples.fold<double>(
    0,
    (m, s) => s.distM > m ? s.distM : m,
  );
  if (total <= 0) return null;
  final sum = List<double>.filled(points, 0);
  final count = List<int>.filled(points, 0);
  for (final s in run.samples) {
    final hr = s.hr;
    if (hr == null || hr < kHrMin || hr > kHrMax) continue;
    final k = (s.distM / total * (points - 1)).round().clamp(0, points - 1);
    sum[k] += hr;
    count[k]++;
  }
  final read = count.where((c) => c > 0).length;
  if (read < 0.7 * points) return null;
  final vals = List<double?>.generate(
    points,
    (k) => count[k] == 0 ? null : sum[k] / count[k],
  );
  double? carry;
  for (var k = 0; k < points; k++) {
    if (vals[k] != null) {
      carry = vals[k];
    } else if (carry != null) {
      vals[k] = carry;
    }
  }
  carry = null;
  for (var k = points - 1; k >= 0; k--) {
    if (vals[k] != null) {
      carry = vals[k];
    } else if (carry != null) {
      vals[k] = carry;
    }
  }
  final bpm = [for (final v in vals) v!.round().clamp(kHrMin, kHrMax)];
  return (bpm: bpm, zones: [for (final b in bpm) zones.zoneOf(b).clamp(1, 5)]);
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
/// [path], at most [kTrailPoints] values on the same progress axis as the
/// profile (one value per trail vertex, resampled alike). Each run's times
/// are heat-adjusted like the board's, so the gap and the board agree. Holes
/// (vertices a run did not reach) take the nearest reached value; null when
/// under 70% of the vertices are shared, or when the end of the gap
/// disagrees with the board's verdict between the two runs.
List<int>? _ghostGap(
  engine.GhostPath path,
  engine.RunFile run,
  engine.RunFile best,
  engine.TrailRunFacts today,
  engine.TrailRunFacts prior,
  engine.TrailGroup g,
) {
  final now = engine.TrailGhostBuilder.profile(path, run);
  final then = engine.TrailGhostBuilder.profile(path, best);
  if (now == null || then == null) return null;
  final raw = List<double?>.filled(path.size, null);
  var shared = 0;
  for (var i = 0; i < path.size; i++) {
    if (now[i] >= 0 && then[i] >= 0) {
      raw[i] = (then[i] * prior.heatFactor - now[i] * today.heatFactor) / 1000;
      shared++;
    }
  }
  if (shared < 2 || shared < 0.7 * path.size) return null;
  double? carry;
  for (var i = 0; i < path.size; i++) {
    if (raw[i] != null) {
      carry = raw[i];
    } else if (carry != null) {
      raw[i] = carry;
    }
  }
  carry = null;
  for (var i = path.size - 1; i >= 0; i--) {
    if (raw[i] != null) {
      carry = raw[i];
    } else if (carry != null) {
      raw[i] = carry;
    }
  }
  final gap = [
    for (final v in _resample([for (final v in raw) v!])) v,
  ];
  final boardDelta = (g.normMs(prior) - g.normMs(today)) / 1000;
  if (gap.last * boardDelta < 0) return null;
  return [for (final v in gap) v.round().clamp(-3600, 3600)];
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

/// The trail's place name, or null when the anchor run has no street or
/// place (the dated fallback "Trail of 1 Sep" is not a place and carries a
/// date). Cut to [kTrailNameMax] code points, never inside one.
String? _name(engine.TrailGroup g) {
  final base = (g.anchor.street ?? g.anchor.place)?.trim() ?? '';
  if (base.isEmpty) return null;
  final runes = g.name.trim().runes;
  if (runes.length <= kTrailNameMax) return g.name.trim();
  return String.fromCharCodes(runes.take(kTrailNameMax)).trim();
}
