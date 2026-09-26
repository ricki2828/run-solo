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
    this.weatherStatus,
    this.tempC,
    this.dewPointC,
    this.heatAdj,
    this.derived,
    this.derivedFailed = false,
    this.row,
  });

  final String id;

  /// Everything a History row, the trend and the verdict ghost read (W5b),
  /// so `list()` never decodes a fresh run. null in an entry written before
  /// W5b: such an entry is stale once and rebuilt.
  final IndexRow? row;

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

  /// Weather (W1, v1 plan §18.5 index columns); null before any fetch.
  final engine.WeatherStatus? weatherStatus;
  final double? tempC;
  final double? dewPointC;

  /// Slowdown fraction; null when not ok or too hot to compare.
  final double? heatAdj;

  /// Phase 4 per-run data (LB2, plan §3.1): best efforts, from-start splits,
  /// live rep paces, Cooper minute marks, fired nudges. Boards fold over
  /// it. Filled in the background after `list()` (WARN-3), so null until
  /// then, and null when the run could not be analysed.
  final engine.RunDerived? derived;

  /// Building [derived] threw for this entry: it stays off the boards and
  /// is not retried until the entry is rebuilt. Kept in the file so a
  /// systematic bug shows up as a count, not silently as "no boards".
  final bool derivedFailed;

  RunIndexEntry withDerived(engine.RunDerived? d) => RunIndexEntry.fromJson({
    ...toJson(),
    'derived': d?.toJson(),
    'derived_failed': d == null,
  });

  /// Marked stale without touching its files' stamps: rebuilt on the next
  /// `list()`, derived data kept (W5b).
  RunIndexEntry withoutRow() =>
      RunIndexEntry.fromJson({...toJson(), 'row': null});

  /// This entry rebuilt for a reason that is not its own files (max HR, a
  /// setting, a prior of the same key: W5b) keeps [o]'s derived data, which
  /// depends only on the run file, the sidecar and the engine.
  RunIndexEntry keepingDerivedOf(RunIndexEntry? o) =>
      o == null || !sameStampAs(o) || (o.derived == null && !o.derivedFailed)
      ? this
      : RunIndexEntry.fromJson({
          ...toJson(),
          'derived': o.derived?.toJson(),
          if (o.derivedFailed) 'derived_failed': true,
        });

  /// Same run file, sidecar and engine as [o] (built from the same inputs).
  bool sameStampAs(RunIndexEntry o) =>
      engineVersion == o.engineVersion &&
      runMtimeMs == o.runMtimeMs &&
      runBytes == o.runBytes &&
      sidecarMtimeMs == o.sidecarMtimeMs &&
      sidecarHash == o.sidecarHash;

  /// Fresh when the run file, the sidecar and the engine are all unchanged
  /// (and the entry carries the W5b row).
  bool isFresh(FileStamp s) =>
      row?.version == IndexRow.currentVersion &&
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
    'weather_status': weatherStatus?.name,
    'temp_c': tempC,
    'dew_point_c': dewPointC,
    'adj': heatAdj,
    'derived': derived?.toJson(),
    if (derivedFailed) 'derived_failed': true,
    'row': row?.toJson(),
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
    weatherStatus: engine.WeatherStatus.values
        .where((s) => s.name == j['weather_status'])
        .firstOrNull,
    tempC: (j['temp_c'] as num?)?.toDouble(),
    dewPointC: (j['dew_point_c'] as num?)?.toDouble(),
    heatAdj: (j['adj'] as num?)?.toDouble(),
    derived: j['derived'] == null
        ? null
        : engine.RunDerived.fromJson(j['derived']! as Map<String, Object?>),
    derivedFailed: j['derived_failed'] == true,
    row: IndexRow.fromJson(j['row'] as Map<String, Object?>?),
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
    final weather = engine.WeatherRecord.fromJson(sidecar?.weather);
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
      weatherStatus: weather?.status,
      tempC: weather?.tempC,
      dewPointC: weather?.dewPointC,
      heatAdj: weather?.adj,
      row: IndexRow.of(run, a, shownVerdict),
    );
  }

  /// The derived data for one run, or null when building it threw (~50 ms
  /// for a 2 h run on the A-series phone). Runs in the background isolate.
  static engine.RunDerived? deriveOrNull(
    engine.RunFile run,
    engine.RunAnalysis a,
  ) {
    try {
      return engine.RunDerived.of(run, a);
    } catch (e) {
      debugPrint('index: no derived data for ${run.id} ($e)');
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RunIndexEntry &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The History-row part of an index entry (W5b): what `RunSummary` needs
/// without the analysis. Figures are the analysis's own, not recomputed.
@immutable
class IndexRow {
  const IndexRow({
    this.version = currentVersion,
    required this.lapCount,
    this.session,
    this.verdict,
    this.detectedReps,
    this.workPaceSecPerKm,
    this.fadeSecPerKm,
    this.recoveryPaceSecPerKm,
    this.repPacesSecPerKm = const [],
    this.repClean = const [],
    this.eligibleAsPrior = false,
  });

  /// Bump when a field is added, so old rows are rebuilt once.
  static const int currentVersion = 1;

  final int version;
  final int lapCount;

  /// The recorded session (run file `session`).
  final engine.SessionSpec? session;

  /// The verdict the row shows (intervals only).
  final engine.Verdict? verdict;

  /// Intervals: reps the detector found, headline work pace, fade and
  /// recovery pace; every rep's pace (null when it has none) and whether it
  /// was clean.
  final int? detectedReps;
  final double? workPaceSecPerKm;
  final double? fadeSecPerKm;
  final double? recoveryPaceSecPerKm;
  final List<double?> repPacesSecPerKm;
  final List<bool> repClean;

  /// Counts towards later verdicts and the trend's rolling median.
  final bool eligibleAsPrior;

  factory IndexRow.of(
    engine.RunFile run,
    engine.RunAnalysis? a,
    engine.Verdict? shownVerdict,
  ) {
    final m = a?.intervals;
    return IndexRow(
      lapCount: run.laps.length,
      session: run.session,
      verdict: shownVerdict,
      detectedReps: m?.reps.length,
      workPaceSecPerKm: m?.avgWorkPaceSecPerKm,
      fadeSecPerKm: m?.fadeSecPerKm,
      recoveryPaceSecPerKm: m?.recoveryPaceSecPerKm,
      repPacesSecPerKm: [
        for (final r in m?.reps ?? const <engine.RepMetrics>[]) r.paceSecPerKm,
      ],
      repClean: [
        for (final r in m?.reps ?? const <engine.RepMetrics>[]) r.clean,
      ],
      eligibleAsPrior: a?.eligibleAsPrior ?? false,
    );
  }

  Map<String, Object?> toJson() => {
    'v': version,
    'laps': lapCount,
    'session': session?.toJson(),
    'verdict': verdict?.toJson(),
    'reps': detectedReps,
    'work_s_per_km': workPaceSecPerKm,
    'fade_s_per_km': fadeSecPerKm,
    'recovery_s_per_km': recoveryPaceSecPerKm,
    'rep_paces_s_per_km': repPacesSecPerKm,
    'rep_clean': repClean,
    'eligible': eligibleAsPrior,
  };

  /// null for a missing or unreadable row (the entry is then stale).
  static IndexRow? fromJson(Map<String, Object?>? j) {
    if (j == null) return null;
    try {
      double? d(String k) => (j[k] as num?)?.toDouble();
      return IndexRow(
        version: j['v']! as int,
        lapCount: j['laps']! as int,
        session: j['session'] == null
            ? null
            : engine.SessionSpec.fromJson(
                j['session']! as Map<String, Object?>,
              ),
        verdict: j['verdict'] == null
            ? null
            : engine.Verdict.fromJson(j['verdict']! as Map<String, Object?>),
        detectedReps: j['reps'] as int?,
        workPaceSecPerKm: d('work_s_per_km'),
        fadeSecPerKm: d('fade_s_per_km'),
        recoveryPaceSecPerKm: d('recovery_s_per_km'),
        repPacesSecPerKm: [
          for (final v in (j['rep_paces_s_per_km'] as List?) ?? const [])
            (v as num?)?.toDouble(),
        ],
        repClean: [
          for (final v in (j['rep_clean'] as List?) ?? const []) v == true,
        ],
        eligibleAsPrior: j['eligible'] == true,
      );
    } catch (e) {
      debugPrint('index: unreadable row ($e)');
      return null;
    }
  }
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
  const RunIndex(this.entries, {this.inputs});

  /// Phase 4 `derived` is an optional field filled in the background, so it
  /// needs no bump (a bump would force a full synchronous rebuild on the
  /// first open).
  static const int schema = 1;
  static const RunIndex empty = RunIndex({});

  final Map<String, RunIndexEntry> entries;

  /// Fingerprint of everything outside the files that changes an analysis
  /// (max-HR inputs, event names, later the heat-compare setting: W5b).
  /// When it differs, every entry is rebuilt (derived data kept).
  final String? inputs;

  String encode() => jsonEncode({
    'schema': schema,
    'inputs': ?inputs,
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
      }, inputs: j['inputs'] as String?);
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
