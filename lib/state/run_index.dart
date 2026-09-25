/// `files/state/index.json`: a per-run summary cache (Phase 3 plan §3.8,
/// eng-review W5). There is no sqflite index; without this every History
/// load gunzips and analyses every run.
///
/// One entry per run id: mode, template id, comparison key, rep count,
/// start, headline pace, a hash of the shown verdict, the engine version and
/// the mtimes of BOTH the run file and its sidecar (a fix-laps edit, an
/// override or a heat flip only touches the sidecar, and must not leave a
/// stale headline; re-check INFO), plus the run file's size and a hash of
/// the sidecar's bytes, because mtimes can be as coarse as a second. An
/// entry is fresh only when all of them and the engine version still match;
/// anything else rebuilds that one entry.
///
/// Written through [SidecarWriter.replaceText] (serialised, unique tmp,
/// flush, rename), and only when an entry actually changed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

@immutable
class RunIndexEntry {
  const RunIndexEntry({
    required this.id,
    required this.mode,
    this.templateId,
    this.comparisonKey,
    this.repCount,
    required this.start,
    required this.durationMs,
    required this.distanceM,
    this.headlineSecPerKm,
    this.verdictHash,
    required this.engineVersion,
    required this.runMtimeMs,
    required this.runBytes,
    this.sidecarMtimeMs,
    this.sidecarHash,
    this.prior,
  });

  final String id;

  /// Effective mode (the override when set), wire name.
  final engine.RunMode mode;
  final String? templateId;
  final String? comparisonKey;
  final int? repCount;
  final DateTime start;
  final int durationMs;
  final double distanceM;

  /// Work pace for intervals, whole-run pace otherwise; null without distance.
  final double? headlineSecPerKm;

  /// FNV-1a of the shown verdict's JSON; null when the run has none.
  final String? verdictHash;
  final int engineVersion;
  final int runMtimeMs;
  final int runBytes;

  /// null when the run has no sidecar yet.
  final int? sidecarMtimeMs;
  final String? sidecarHash;

  /// What this run contributes as a prior to later verdicts of its key.
  final engine.PriorRun? prior;

  /// Fresh when the run file, the sidecar and the engine are all unchanged.
  bool isFresh(FileStamp s) =>
      engineVersion == engine.engineVersion &&
      runMtimeMs == s.runMtimeMs &&
      runBytes == s.runBytes &&
      sidecarMtimeMs == s.sidecarMtimeMs &&
      sidecarHash == s.sidecarHash;

  Map<String, Object?> toJson() => {
    'id': id,
    'mode': mode.name,
    'template_id': templateId,
    'comparison_key': comparisonKey,
    'rep_count': repCount,
    'start': start.toUtc().toIso8601String(),
    'duration_ms': durationMs,
    'distance_m': distanceM,
    'headline_s_per_km': headlineSecPerKm,
    'verdict_hash': verdictHash,
    'engine_version': engineVersion,
    'run_mtime_ms': runMtimeMs,
    'run_bytes': runBytes,
    'sidecar_mtime_ms': sidecarMtimeMs,
    'sidecar_hash': sidecarHash,
    'prior': prior?.toJson(),
  };

  factory RunIndexEntry.fromJson(Map<String, Object?> j) => RunIndexEntry(
    id: j['id']! as String,
    mode: engine.RunMode.decode(
      j['mode']! as String,
      schema: engine.RunFile.schema,
    ),
    templateId: j['template_id'] as String?,
    comparisonKey: j['comparison_key'] as String?,
    repCount: j['rep_count'] as int?,
    start: DateTime.parse(j['start']! as String).toUtc(),
    durationMs: j['duration_ms']! as int,
    distanceM: (j['distance_m']! as num).toDouble(),
    headlineSecPerKm: (j['headline_s_per_km'] as num?)?.toDouble(),
    verdictHash: j['verdict_hash'] as String?,
    engineVersion: j['engine_version']! as int,
    runMtimeMs: j['run_mtime_ms']! as int,
    runBytes: j['run_bytes']! as int,
    sidecarMtimeMs: j['sidecar_mtime_ms'] as int?,
    sidecarHash: j['sidecar_hash'] as String?,
    prior: j['prior'] == null
        ? null
        : engine.PriorRun.fromJson(j['prior']! as Map<String, Object?>),
  );

  /// Built from a fresh analysis ([a] null when the run could not be
  /// analysed; the entry still lists it).
  factory RunIndexEntry.of({
    required engine.RunFile run,
    required engine.RunSidecar? sidecar,
    required engine.RunAnalysis? a,
    required engine.Verdict? shownVerdict,
    required FileStamp stamp,
  }) {
    final mode = sidecar?.runTypeOverride ?? a?.mode ?? run.mode;
    final durationMs = run.end.difference(run.start).inMilliseconds;
    final whole = run.distanceM > 0
        ? durationMs / 1000 / (run.distanceM / 1000)
        : null;
    return RunIndexEntry(
      id: run.id,
      mode: mode,
      templateId: a?.session?.templateId,
      comparisonKey: a?.comparisonKey,
      repCount: a?.session?.steps.isEmpty ?? true ? null : a!.session!.repCount,
      start: run.start,
      durationMs: durationMs,
      distanceM: run.distanceM,
      headlineSecPerKm: mode == engine.RunMode.intervals
          ? (a?.intervals?.avgWorkPaceSecPerKm ?? whole)
          : whole,
      verdictHash: shownVerdict == null
          ? null
          : fnv1a(jsonEncode(shownVerdict.toJson())),
      engineVersion: engine.engineVersion,
      runMtimeMs: stamp.runMtimeMs,
      runBytes: stamp.runBytes,
      sidecarMtimeMs: stamp.sidecarMtimeMs,
      sidecarHash: stamp.sidecarHash,
      prior: a?.asPrior(run.start),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RunIndexEntry &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// What the cache checks on disk for one run.
@immutable
class FileStamp {
  const FileStamp({
    required this.runMtimeMs,
    required this.runBytes,
    this.sidecarMtimeMs,
    this.sidecarHash,
  });

  final int runMtimeMs;
  final int runBytes;
  final int? sidecarMtimeMs;
  final String? sidecarHash;

  /// null when the run file is gone.
  static Future<FileStamp?> of(File run, File sidecar) async {
    final rs = await run.stat();
    if (rs.type == FileSystemEntityType.notFound) return null;
    final ss = await sidecar.stat();
    final hasSidecar = ss.type != FileSystemEntityType.notFound;
    return FileStamp(
      runMtimeMs: rs.modified.millisecondsSinceEpoch,
      runBytes: rs.size,
      sidecarMtimeMs: hasSidecar ? ss.modified.millisecondsSinceEpoch : null,
      sidecarHash: hasSidecar ? fnv1a(await sidecar.readAsString()) : null,
    );
  }
}

/// The whole cache. Unknown or damaged content reads as empty (it is a
/// cache: the next `list()` rebuilds it from the files).
@immutable
class RunIndex {
  const RunIndex(this.entries);

  static const int schema = 1;
  static const RunIndex empty = RunIndex({});

  final Map<String, RunIndexEntry> entries;

  String encode() => jsonEncode({
    'schema': schema,
    'runs': [
      for (final id in (entries.keys.toList()..sort())) entries[id]!.toJson(),
    ],
  });

  static RunIndex decode(String? text) {
    if (text == null) return empty;
    try {
      final j = jsonDecode(text) as Map<String, Object?>;
      if (j['schema'] != schema) return empty;
      return RunIndex({
        for (final e in j['runs']! as List<Object?>)
          (e! as Map<String, Object?>)['id']! as String: RunIndexEntry.fromJson(
            e as Map<String, Object?>,
          ),
      });
    } catch (e) {
      debugPrint('index: unreadable, rebuilding ($e)');
      return empty;
    }
  }

  static Future<RunIndex> read(File f) async =>
      decode(await f.exists() ? await f.readAsString() : null);
}

/// FNV-1a 32-bit, hex: stable across runs and platforms (String.hashCode is
/// not guaranteed to be).
String fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
