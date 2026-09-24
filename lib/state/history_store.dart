/// Finalised runs for the History list. Phase 1 reads run files directly
/// (`files/runs/run-<id>.json.gz`); the sqflite index and Reconciler arrive
/// with Phase 2 and replace [FileHistoryStore] behind the same interface.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';

@immutable
class RunSummary {
  const RunSummary({
    required this.id,
    required this.mode,
    required this.start,
    required this.durationMs,
    required this.distanceM,
    required this.laps,
    this.preset,
    this.missing = false,
  });

  final String id;
  final RecordMode mode;
  final DateTime start;
  final int durationMs;
  final double distanceM;
  final int laps;
  final Preset? preset;

  /// Indexed but the file is gone (plan §2 rule 5); shown, never hidden.
  final bool missing;

  bool get isFourByFour => mode == RecordMode.fourByFour;

  /// Whole-run average pace, s/km; null when no distance.
  double? get avgSecPerKm =>
      distanceM > 0 ? durationMs / 1000 / (distanceM / 1000) : null;
}

abstract class HistoryStore {
  /// Newest first.
  Future<List<RunSummary>> list();
}

class MemoryHistoryStore implements HistoryStore {
  MemoryHistoryStore([List<RunSummary>? runs, this.fake]) : runs = runs ?? [];
  final List<RunSummary> runs;

  /// When set, runs the fake recorder finalised appear too.
  final FakeRecorderGateway? fake;

  @override
  Future<List<RunSummary>> list() async {
    final all = [
      ...runs,
      ...?fake?.finalised.map(
        (f) => RunSummary(
          id: f.runId,
          mode: f.mode,
          start: f.start,
          durationMs: f.durationMs,
          distanceM: f.distanceM,
          laps: f.laps,
          preset: f.preset,
        ),
      ),
    ];
    all.sort((a, b) => b.start.compareTo(a.start));
    return all;
  }
}

class FileHistoryStore implements HistoryStore {
  FileHistoryStore(this.runsDir);
  final Directory runsDir;

  static final _name = RegExp(r'^run-(.+)\.json\.gz$');

  @override
  Future<List<RunSummary>> list() async {
    if (!await runsDir.exists()) return const [];
    final out = <RunSummary>[];
    await for (final entity in runsDir.list()) {
      if (entity is! File) continue;
      final base = entity.uri.pathSegments.last;
      final m = _name.firstMatch(base);
      if (m == null) continue;
      try {
        final text = utf8.decode(gzip.decode(await entity.readAsBytes()));
        final run = engine.RunFileCodec.decode(text);
        out.add(
          RunSummary(
            id: run.id,
            mode: run.mode == engine.RunMode.fourByFour
                ? RecordMode.fourByFour
                : RecordMode.free,
            start: run.start,
            durationMs: run.end.difference(run.start).inMilliseconds,
            distanceM: run.samples.isEmpty ? 0 : run.samples.last.distM,
            laps: run.laps.length,
            preset: run.preset == null
                ? null
                : Preset(
                    reps: run.preset!.reps,
                    workSeconds: run.preset!.workSeconds,
                    recoverySeconds: run.preset!.recoverySeconds,
                  ),
          ),
        );
      } catch (e) {
        // A newer-schema or damaged file is Phase 2's Reconciler problem;
        // the list must never crash on one bad file.
        debugPrint('history: skipped $base ($e)');
      }
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }
}
