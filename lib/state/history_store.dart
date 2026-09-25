/// Finalised runs: the History list, run detail, fix-laps edits, trend and
/// delete. Phase 2 still reads run files directly (`files/runs/` and
/// `files/runs-archive/`, plan §2 rule 5) and mirrors every user-authored or
/// frozen fact to the `run-<id>.edits.json` sidecar; the sqflite index +
/// Reconciler slot in behind [RunStore] later without touching screens.
///
/// Analysis order matters: verdicts compare against earlier runs, so the
/// store analyses oldest → newest, feeding each eligible 4x4 in as a prior
/// for the next (plan §5 staged verdict). A verdict already frozen in the
/// sidecar with the current engine version is restored, never recomputed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';

/// `RunMode` (file / engine) ↔ `RecordMode` (Pigeon / UI). Exhaustive on both
/// sides (W7) so a new run type fails to compile instead of mislabelling.
RecordMode recordModeOf(engine.RunMode m) => switch (m) {
  engine.RunMode.fourByFour => RecordMode.fourByFour,
  engine.RunMode.laps => RecordMode.laps,
  engine.RunMode.free => RecordMode.free,
  engine.RunMode.cooper => RecordMode.cooper,
};

engine.RunMode runModeOf(RecordMode m) => switch (m) {
  RecordMode.fourByFour => engine.RunMode.fourByFour,
  RecordMode.laps => engine.RunMode.laps,
  RecordMode.free => engine.RunMode.free,
  RecordMode.cooper => engine.RunMode.cooper,
};

/// Short label per run type ("4x4", "LAPS", "FREE", "TEST").
String modeLabel(RecordMode m) => switch (m) {
  RecordMode.fourByFour => '4x4',
  RecordMode.laps => 'LAPS',
  RecordMode.free => 'FREE',
  RecordMode.cooper => 'TEST',
};

String modeTitle(RecordMode m) => switch (m) {
  RecordMode.fourByFour => '4x4',
  RecordMode.laps => 'Laps run',
  RecordMode.free => 'Free run',
  RecordMode.cooper => '12-minute test',
};

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
    this.verdict,
    this.analysis,
  });

  final String id;

  /// Effective mode: the sidecar override when set, else the file's.
  final RecordMode mode;
  final DateTime start;
  final int durationMs;
  final double distanceM;
  final int laps;
  final Preset? preset;

  /// Indexed but the file is gone (plan §2 rule 5); shown, never hidden.
  final bool missing;

  /// The 4x4 verdict (frozen or computed); null for other types / missing.
  final engine.Verdict? verdict;

  /// Full analysis when the file was readable (History rows and Trend read
  /// medians, fade and bests off it).
  final engine.RunAnalysis? analysis;

  bool get isFourByFour => mode == RecordMode.fourByFour;

  /// Whole-run average pace, s/km; null when no distance.
  double? get avgSecPerKm =>
      distanceM > 0 ? durationMs / 1000 / (distanceM / 1000) : null;

  /// Headline pace for the row: work pace for a 4x4, whole-run otherwise.
  double? get headlineSecPerKm => isFourByFour
      ? (analysis?.fourByFour?.avgWorkPaceSecPerKm ?? avgSecPerKm)
      : avgSecPerKm;
}

/// A loaded run: file, sidecar and analysis, for detail / verdict / fix-laps.
@immutable
class RunDetail {
  const RunDetail({
    required this.run,
    required this.sidecar,
    required this.analysis,
    required this.summary,
  });
  final engine.RunFile run;
  final engine.RunSidecar sidecar;
  final engine.RunAnalysis analysis;
  final RunSummary summary;
}

abstract class HistoryStore {
  /// Newest first.
  Future<List<RunSummary>> list();
}

/// Outcome of [RunStore.importBundles]: uuid dedupe never overwrites.
@immutable
class ImportResult {
  const ImportResult({
    required this.imported,
    required this.alreadyOnDeviceIds,
    required this.duplicateIds,
  });
  final int imported;

  /// Already here: kept as is, the incoming sidecar was not merged.
  final List<String> alreadyOnDeviceIds;

  /// Repeated within the batch (extra copies).
  final List<String> duplicateIds;

  List<String> get skippedIds => [...alreadyOnDeviceIds, ...duplicateIds];
}

/// The verdict a run shows (plan §5: verdicts are point-in-time and frozen).
/// A sidecar's frozen verdict wins while its inputs (lap edits, override)
/// still match, even after an engine version bump: the runner keeps the
/// words they were shown. Only fix-laps / an override (which change the
/// inputs key) or a run with no frozen verdict get the engine's fresh one.
engine.Verdict? displayVerdict(
  engine.RunSidecar? sidecar,
  engine.RunAnalysis? analysis,
) {
  final frozen = sidecar?.frozenVerdict;
  if (frozen != null && sidecar != null) {
    final key = engine.Verdict.inputsKeyFor(
      sidecar.lapEdits,
      sidecar.runTypeOverride,
    );
    if (frozen.inputsKey == key) return frozen;
  }
  return analysis?.verdict;
}

abstract class RunStore implements HistoryStore {
  Future<RunDetail?> load(String id);

  /// Every readable run with its sidecar, for "Move runs to another Run
  /// Solo" (plan §4 export; the receiving app dedupes by uuid).
  Future<List<engine.RunBundle>> exportBundles();

  /// Write bundles that are not already here (run file + sidecar). Returns
  /// how many landed and which uuids were skipped as duplicates.
  Future<ImportResult> importBundles(List<engine.RunBundle> bundles);

  /// Fix-laps: append an edit to the sidecar, re-analyse, freeze the new
  /// verdict (old text kept in history). Throws `LapEditException` when the
  /// edit cannot apply; nothing is written then.
  Future<RunDetail> applyLapEdit(String id, engine.LapEdit edit);

  /// Drop every lap edit (fix-laps "Reset").
  Future<RunDetail> clearLapEdits(String id);
  Future<RunDetail> setOverride(String id, RecordMode? mode);
  Future<void> delete(String id);
}

/// Shared analysis pass over decoded runs (memory and file stores).
class _Analyser {
  _Analyser({
    required this.profile,
    required this.now,
    engine.RunEngine? runEngine,
  }) : runEngine = runEngine ?? const engine.RunEngine();

  final engine.UserProfile Function() profile;
  final DateTime Function() now;
  final engine.RunEngine runEngine;

  /// Oldest → newest; returns analyses keyed by id plus sidecars that gained
  /// a frozen verdict (the caller persists those).
  ({
    Map<String, engine.RunAnalysis> analyses,
    Map<String, engine.RunSidecar> frozen,
  })
  run(List<engine.RunFile> runs, Map<String, engine.RunSidecar> sidecars) {
    final ordered = List.of(runs)..sort((a, b) => a.start.compareTo(b.start));
    final priors = <engine.PriorRun>[];
    final analyses = <String, engine.RunAnalysis>{};
    final frozen = <String, engine.RunSidecar>{};
    final p = profile();
    for (final run in ordered) {
      final sidecar = sidecars[run.id] ?? engine.RunSidecar(runId: run.id);
      engine.RunAnalysis a;
      try {
        a = runEngine.analyze(
          run,
          sidecar: sidecar,
          priors: List.of(priors),
          profile: p,
          now: now().toUtc(),
        );
      } catch (e) {
        debugPrint('history: analysis failed for ${run.id} ($e)');
        continue;
      }
      analyses[run.id] = a;
      // Freeze only when nothing usable is frozen yet: an engine bump must
      // not silently replace the verdict the runner already saw.
      if (a.verdict != null &&
          a.verdictSource == engine.VerdictSource.computed &&
          displayVerdict(sidecar, a) == a.verdict) {
        frozen[run.id] = a.freezeInto(sidecar);
      }
      final prior = a.asPrior(run.start);
      if (prior != null) priors.add(prior);
    }
    return (analyses: analyses, frozen: frozen);
  }
}

/// An edit the engine cannot apply (`lapEditsInvalid`) is refused before
/// anything is written, so a sidecar never carries a dead edit.
void _checkEdits(
  _Analyser analyser,
  engine.RunFile run,
  engine.RunSidecar sidecar,
) {
  final a = analyser.runEngine.analyze(
    run,
    sidecar: sidecar,
    profile: analyser.profile(),
  );
  if (a.lapEditsInvalid) {
    throw engine.LapEditException('That edit does not fit these laps.');
  }
}

RunSummary _summaryOf(
  engine.RunFile run,
  engine.RunSidecar? sidecar,
  engine.RunAnalysis? a,
) => RunSummary(
  id: run.id,
  mode: recordModeOf(sidecar?.runTypeOverride ?? a?.mode ?? run.mode),
  start: run.start,
  durationMs: run.end.difference(run.start).inMilliseconds,
  distanceM: run.distanceM,
  laps: run.laps.length,
  preset: run.preset == null
      ? null
      : Preset(
          reps: run.preset!.reps,
          workSeconds: run.preset!.workSeconds,
          recoverySeconds: run.preset!.recoverySeconds,
        ),
  // Only a 4x4 carries a verdict word (plan §18.2); guard by the effective
  // mode so nothing else ever shows one.
  verdict:
      recordModeOf(sidecar?.runTypeOverride ?? a?.mode ?? run.mode) ==
          RecordMode.fourByFour
      ? displayVerdict(sidecar, a)
      : null,
  analysis: a,
);

/// In-memory store: plain summaries (Phase 1 tests), decoded run files with
/// sidecars (Phase 2 detail / verdict tests) and the fake recorder's
/// finalised runs.
class MemoryRunStore implements RunStore {
  MemoryRunStore({
    List<RunSummary>? runs,
    List<engine.RunFile>? files,
    Map<String, engine.RunSidecar>? sidecars,
    this.fake,
    engine.UserProfile Function()? profile,
    DateTime Function()? now,
  }) : runs = runs ?? [],
       files = files ?? [],
       sidecars = sidecars ?? {},
       _analyser = _Analyser(
         profile: profile ?? (() => engine.UserProfile.none),
         now: now ?? DateTime.now,
       );

  final List<RunSummary> runs;
  final List<engine.RunFile> files;
  final Map<String, engine.RunSidecar> sidecars;

  /// When set, runs the fake recorder finalised appear too.
  final FakeRecorderGateway? fake;
  final _Analyser _analyser;
  final Set<String> _deleted = {};

  /// Sidecars the store wrote (frozen verdicts, edits), newest last.
  final List<engine.RunSidecar> written = [];

  Map<String, engine.RunAnalysis> _analyse() {
    final live = files.where((f) => !_deleted.contains(f.id)).toList();
    final r = _analyser.run(live, sidecars);
    for (final e in r.frozen.entries) {
      sidecars[e.key] = e.value;
      written.add(e.value);
    }
    return r.analyses;
  }

  @override
  Future<List<RunSummary>> list() async {
    final analyses = _analyse();
    final all = [
      ...runs.where((r) => !_deleted.contains(r.id)),
      for (final f in files.where((f) => !_deleted.contains(f.id)))
        _summaryOf(f, sidecars[f.id], analyses[f.id]),
      ...?fake?.finalised
          .where((f) => !_deleted.contains(f.runId))
          .map(
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

  @override
  Future<RunDetail?> load(String id) async {
    if (_deleted.contains(id)) return null;
    final run = files.where((f) => f.id == id).firstOrNull;
    if (run == null) return null;
    final analyses = _analyse();
    final a = analyses[id];
    if (a == null) return null;
    final sidecar = sidecars[id] ?? engine.RunSidecar(runId: id);
    return RunDetail(
      run: run,
      sidecar: sidecar,
      analysis: a,
      summary: _summaryOf(run, sidecar, a),
    );
  }

  Future<RunDetail> _mutate(
    String id,
    engine.RunSidecar Function(engine.RunSidecar) change,
  ) async {
    final run = files.firstWhere((f) => f.id == id);
    final current = sidecars[id] ?? engine.RunSidecar(runId: id);
    final next = change(current);
    _checkEdits(_analyser, run, next);
    sidecars[id] = next;
    written.add(next);
    return (await load(id))!;
  }

  @override
  Future<RunDetail> applyLapEdit(String id, engine.LapEdit edit) =>
      _mutate(id, (s) => s.withLapEdit(edit));

  @override
  Future<RunDetail> clearLapEdits(String id) => _mutate(
    id,
    (s) => s.copyWith(lapEdits: const []).withOverride(s.runTypeOverride),
  );

  @override
  Future<RunDetail> setOverride(String id, RecordMode? mode) =>
      _mutate(id, (s) => s.withOverride(mode == null ? null : runModeOf(mode)));

  @override
  Future<void> delete(String id) async => _deleted.add(id);

  @override
  Future<List<engine.RunBundle>> exportBundles() async => [
    for (final f in files.where((f) => !_deleted.contains(f.id)))
      engine.RunBundle(run: f, sidecar: sidecars[f.id]),
  ];

  @override
  Future<ImportResult> importBundles(List<engine.RunBundle> bundles) async {
    final existing = {
      for (final f in files.where((f) => !_deleted.contains(f.id))) f.id,
      for (final r in runs) r.id,
    };
    final plan = engine.planBundleImport(bundles, existing);
    for (final b in plan.toImport) {
      _deleted.remove(b.run.id);
      files.add(b.run);
      if (b.sidecar != null) sidecars[b.run.id] = b.sidecar!;
    }
    return ImportResult(
      imported: plan.toImport.length,
      alreadyOnDeviceIds: plan.alreadyOnDeviceIds,
      duplicateIds: plan.duplicateIds,
    );
  }
}

/// `files/runs/` + `files/runs-archive/`: `run-<id>.json.gz` written by
/// Kotlin, `run-<id>.edits.json` written here (tmp → fsync → rename).
class FileRunStore implements RunStore {
  FileRunStore(
    this.runsDir, {
    Directory? archiveDir,
    engine.UserProfile Function()? profile,
    DateTime Function()? now,
  }) : archiveDir =
           archiveDir ?? Directory('${runsDir.parent.path}/runs-archive'),
       _analyser = _Analyser(
         profile: profile ?? (() => engine.UserProfile.none),
         now: now ?? DateTime.now,
       );

  final Directory runsDir;
  final Directory archiveDir;
  final _Analyser _analyser;

  static final _name = RegExp(r'^run-(.+)\.json\.gz$');

  /// Decoded files by id → (file, sidecar, path); rebuilt on every list so
  /// a run finalised by the service a moment ago shows up.
  Future<Map<String, (engine.RunFile, engine.RunSidecar?, File)>>
  _scan() async {
    final out = <String, (engine.RunFile, engine.RunSidecar?, File)>{};
    for (final dir in [runsDir, archiveDir]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.last;
        final m = _name.firstMatch(base);
        if (m == null) continue;
        try {
          final text = utf8.decode(gzip.decode(await entity.readAsBytes()));
          final run = engine.RunFileCodec.decode(text);
          final sc = await _readSidecar(_sidecarFor(entity));
          out[run.id] = (run, sc, entity);
        } catch (e) {
          // A newer-schema or damaged file is the Reconciler's problem later;
          // the list must never crash on one bad file.
          debugPrint('history: skipped $base ($e)');
        }
      }
    }
    return out;
  }

  static File _sidecarFor(File runFile) =>
      File(runFile.path.replaceFirst(RegExp(r'\.json\.gz$'), '.edits.json'));

  Future<engine.RunSidecar?> _readSidecar(File f) async {
    if (!await f.exists()) return null;
    try {
      return engine.RunSidecarCodec.decode(await f.readAsString());
    } on engine.RunFileNewerVersionException {
      // W6: a sidecar from a newer app is kept read-only, never rewritten.
      rethrow;
    } catch (e) {
      debugPrint('history: sidecar unreadable ${f.path} ($e)');
      return null;
    }
  }

  Future<void> _writeSidecar(File f, engine.RunSidecar sidecar) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      engine.RunSidecarCodec.encode(sidecar),
      flush: true,
    );
    await tmp.rename(f.path);
  }

  Future<
    ({
      Map<String, (engine.RunFile, engine.RunSidecar?, File)> scanned,
      Map<String, engine.RunAnalysis> analyses,
    })
  >
  _scanAndAnalyse() async {
    final scanned = await _scan();
    final r = _analyser.run(scanned.values.map((v) => v.$1).toList(), {
      for (final v in scanned.values)
        if (v.$2 != null) v.$1.id: v.$2!,
    });
    for (final e in r.frozen.entries) {
      final entry = scanned[e.key]!;
      try {
        await _writeSidecar(_sidecarFor(entry.$3), e.value);
        scanned[e.key] = (entry.$1, e.value, entry.$3);
      } catch (err) {
        debugPrint('history: could not freeze verdict for ${e.key} ($err)');
      }
    }
    return (scanned: scanned, analyses: r.analyses);
  }

  @override
  Future<List<RunSummary>> list() async {
    final r = await _scanAndAnalyse();
    final out = [
      for (final v in r.scanned.values)
        _summaryOf(v.$1, v.$2, r.analyses[v.$1.id]),
    ];
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  @override
  Future<RunDetail?> load(String id) async {
    final r = await _scanAndAnalyse();
    final v = r.scanned[id];
    final a = r.analyses[id];
    if (v == null || a == null) return null;
    final sidecar = v.$2 ?? engine.RunSidecar(runId: id);
    return RunDetail(
      run: v.$1,
      sidecar: sidecar,
      analysis: a,
      summary: _summaryOf(v.$1, sidecar, a),
    );
  }

  Future<RunDetail> _mutate(
    String id,
    engine.RunSidecar Function(engine.RunSidecar) change,
  ) async {
    final scanned = await _scan();
    final v = scanned[id];
    if (v == null) throw StateError('run $id not found');
    final next = change(v.$2 ?? engine.RunSidecar(runId: id));
    _checkEdits(_analyser, v.$1, next);
    await _writeSidecar(_sidecarFor(v.$3), next);
    return (await load(id))!;
  }

  @override
  Future<RunDetail> applyLapEdit(String id, engine.LapEdit edit) =>
      _mutate(id, (s) => s.withLapEdit(edit));

  @override
  Future<RunDetail> clearLapEdits(String id) => _mutate(
    id,
    (s) => s.copyWith(lapEdits: const []).withOverride(s.runTypeOverride),
  );

  @override
  Future<RunDetail> setOverride(String id, RecordMode? mode) =>
      _mutate(id, (s) => s.withOverride(mode == null ? null : runModeOf(mode)));

  @override
  Future<List<engine.RunBundle>> exportBundles() async {
    final scanned = await _scan();
    final out = [
      for (final v in scanned.values)
        engine.RunBundle(run: v.$1, sidecar: v.$2),
    ];
    out.sort((a, b) => a.run.start.compareTo(b.run.start));
    return out;
  }

  /// Sidecar first, then the run file (plan §4 dual-write order), each via
  /// tmp → flush → rename, into `files/runs/`.
  @override
  Future<ImportResult> importBundles(List<engine.RunBundle> bundles) async {
    final scanned = await _scan();
    final plan = engine.planBundleImport(bundles, scanned.keys.toSet());
    await runsDir.create(recursive: true);
    var imported = 0;
    for (final b in plan.toImport) {
      final runFile = File('${runsDir.path}/run-${b.run.id}.json.gz');
      try {
        if (b.sidecar != null) {
          await _writeSidecar(_sidecarFor(runFile), b.sidecar!);
        }
        final tmp = File('${runFile.path}.tmp');
        await tmp.writeAsBytes(
          gzip.encode(utf8.encode(engine.RunFileCodec.encode(b.run))),
          flush: true,
        );
        await tmp.rename(runFile.path);
        imported += 1;
      } catch (e) {
        debugPrint('import: could not write ${b.run.id} ($e)');
      }
    }
    return ImportResult(
      imported: imported,
      alreadyOnDeviceIds: plan.alreadyOnDeviceIds,
      duplicateIds: plan.duplicateIds,
    );
  }

  /// Deletes the run file and its sidecar together (plan §4: they move and
  /// go as a pair).
  @override
  Future<void> delete(String id) async {
    final scanned = await _scan();
    final v = scanned[id];
    if (v == null) return;
    final sc = _sidecarFor(v.$3);
    if (await sc.exists()) await sc.delete();
    await v.$3.delete();
  }
}

/// Phase 1 name, kept for callers; the store is the same object.
typedef MemoryHistoryStore = MemoryRunStore;
typedef FileHistoryStore = FileRunStore;
