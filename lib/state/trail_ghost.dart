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
    final groups = engine.Trails.group(facts)
      ..sort((a, b) => b.runs.last.start.compareTo(a.runs.last.start));
    final out = <engine.GhostTrail>[];
    for (final g in groups) {
      if (out.length >= engine.GhostTrail.maxTrails) break;
      try {
        final best = _load(g.best.id, runDirPaths);
        final last = _load(g.runs.last.id, runDirPaths);
        if (best == null || last == null) continue;
        final t = engine.TrailGhostBuilder.build(
          id: g.key,
          name: g.name,
          best: best,
          last: last,
        );
        if (t != null) out.add(t);
      } catch (e) {
        debugPrint('trail ghost: skipped ${g.key} ($e)');
      }
    }
    return out;
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
    );
  }
}
