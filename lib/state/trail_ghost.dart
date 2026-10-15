/// The known trails a Start hands to the recorder (the in-run ghost): for each
/// trail the runner has run before, its geometry and the progress profiles of
/// their best and their last run on it.
///
/// Built off the UI isolate when Start opens and whenever the index has changed
/// (the run files of the best and last run on each of the six most recent
/// trails are read there), then only read at Start, so Start never waits on a
/// file. The grouping is the same-trail rule the boards and the verdict use
/// (`Trails.group`); the profiles and the turnaround come from the engine's
/// `TrailGhostBuilder`. Index fields only for the grouping, two run files per
/// trail for the profiles.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'run_index.dart';
import 'history_store.dart' show RunSummary;
import 'trails.dart';

class TrailGhostSource {
  TrailGhostSource({required this.indexFile, required this.runDirs});

  final File indexFile;

  /// Where run files live (`runs/` and `runs-archive/`).
  final List<Directory> runDirs;

  String? _version;
  List<engine.GhostTrail> _cached = const [];
  Future<void>? _preparing;

  /// The trails from the last [prepare]; empty when never prepared.
  List<engine.GhostTrail> get trails => _cached;

  /// Rebuilds the trails in a background isolate when the index has changed
  /// since the last call. Cheap when nothing changed (one stat). Never throws.
  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    try {
      final stat = await indexFile.stat();
      if (stat.type == FileSystemEntityType.notFound) return;
      final version = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      if (version == _version) return;
      final index = indexFile.path;
      final dirs = [for (final d in runDirs) d.path];
      _cached = await Isolate.run(() => buildAt(index, dirs));
      _version = version;
    } catch (e) {
      debugPrint('trail ghost: prepare failed ($e)');
    }
  }

  /// Runs in the background isolate (also callable directly in tests).
  @visibleForTesting
  static List<engine.GhostTrail> buildAt(
    String indexPath,
    List<String> runDirPaths,
  ) {
    final f = File(indexPath);
    final index = RunIndex.decode(f.existsSync() ? f.readAsStringSync() : null);
    final facts = [
      for (final e in index.entries.values)
        if (e.row != null) ?trailFactsOf(RunSummary.fromEntry(e)),
    ];
    // Only trails the runner has really run feed the ghost: two or more runs,
    // or a single Trail-mode run. A one-off Free run is not a known trail and
    // must not crowd a real one out of the six slots. Most recently run first.
    final groups = [
      for (final g in engine.Trails.group(facts))
        if (g.runs.length >= 2 ||
            (g.runs.single.trailMode && g.runs.single.override == null))
          g,
    ]..sort((a, b) => b.runs.last.start.compareTo(a.runs.last.start));
    final out = <engine.GhostTrail>[];
    for (final g in groups) {
      if (out.length >= engine.GhostTrail.maxTrails) break;
      try {
        // The geometry is the latest automatic run's, never a forced join's
        // (its route may not be the trail's). The best is the fastest run
        // whose turn point is within [maxTurnGapM] of its: a run that turned
        // much earlier has no time for the stretch it never ran, and would
        // read as minutes ahead on the way back.
        final geom = g.runs.lastWhere(
          (r) => r.override == null,
          orElse: () => g.runs.last,
        );
        final fits = [
          for (final r in g.runs)
            if (_turnsAlike(r, geom)) r,
        ];
        // Fastest first. A run the runner joined by hand may not share the
        // trail's geometry, and then no profile can be built from it: the
        // next fastest takes the slot.
        fits.sort((a, b) => g.normMs(a).compareTo(g.normMs(b)));
        final last = _load(geom.id, runDirPaths);
        if (last == null) continue;
        engine.GhostTrail? t;
        for (final f in fits) {
          final best = f.id == geom.id ? last : _load(f.id, runDirPaths);
          if (best == null) continue;
          try {
            t = engine.TrailGhostBuilder.build(
              id: g.key,
              name: g.name,
              best: best,
              last: last,
            );
          } catch (e) {
            debugPrint('trail ghost: ${f.id} does not fit ${g.key} ($e)');
          }
          if (t != null) break;
        }
        if (t != null) out.add(t);
      } catch (e) {
        debugPrint('trail ghost: skipped ${g.key} ($e)');
      }
    }
    return out;
  }

  /// Out-and-backs turned round no further apart than this share a ghost.
  static const double maxTurnGapM = engine.RouteMatch.maxTurnGapM;

  static bool _turnsAlike(engine.TrailRunFacts r, engine.TrailRunFacts geom) {
    if (identical(r, geom) || r.id == geom.id) return true;
    final gap = engine.RouteMatch.turnGapM(r.route!, geom.route!);
    return gap == null || gap <= maxTurnGapM;
  }

  static engine.RunFile? _load(String id, List<String> dirs) {
    for (final d in dirs) {
      final file = File('$d/run-$id.json.gz');
      if (file.existsSync()) {
        return engine.RunFileCodec.decode(
          utf8.decode(gzip.decode(file.readAsBytesSync())),
        );
      }
    }
    return null;
  }

  /// [t] as the Pigeon struct `start()` takes.
  static TrailRef toPigeon(engine.GhostTrail t) {
    TrailProfile profile(engine.GhostProfile p) =>
        TrailProfile(runId: p.runId, dateMs: p.dateMs, ms: p.ms);
    return TrailRef(
      id: t.id,
      name: t.name,
      latLon: t.latLon,
      best: profile(t.best),
      last: t.last == null ? null : profile(t.last!),
      turnAlongM: t.turnAlongM,
      elevM: t.elevM,
      elevSrc: t.elevSrc,
      climbs: [
        for (final c in t.climbs)
          TrailClimb(
            startM: c.startM,
            endM: c.endM,
            gainM: c.gainM,
            avgGradePct: c.avgGradePct,
          ),
      ],
    );
  }
}
