/// Finalised runs: the History list, run detail, fix-laps edits, trend and
/// delete. Reads run files directly (`files/runs/` and `files/runs-archive/`,
/// plan §2 rule 5) and mirrors every user-authored or frozen fact to the
/// `run-<id>.edits.json` sidecar, always through [SidecarWriter] (Phase 3
/// BLOCK-1). There is no sqflite index: a JSON summary cache
/// (`files/state/index.json`, Phase 3 W5) sits behind [RunStore] instead.
///
/// Analysis order matters: verdicts compare against earlier runs, so the
/// store analyses oldest → newest, feeding each eligible 4x4 in as a prior
/// for the next (plan §5 staged verdict). A verdict already frozen in the
/// sidecar with the current engine version is restored, never recomputed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import 'run_index.dart';
import 'sidecar_writer.dart';

/// `RunMode` (file / engine) ↔ `RecordMode` (Pigeon / UI). Exhaustive on both
/// sides (W7) so a new run type fails to compile instead of mislabelling.
RecordMode recordModeOf(engine.RunMode m) => switch (m) {
  engine.RunMode.intervals => RecordMode.intervals,
  engine.RunMode.laps => RecordMode.laps,
  engine.RunMode.free => RecordMode.free,
  engine.RunMode.cooper => RecordMode.cooper,
};

engine.RunMode runModeOf(RecordMode m) => switch (m) {
  RecordMode.intervals => engine.RunMode.intervals,
  RecordMode.laps => engine.RunMode.laps,
  RecordMode.free => engine.RunMode.free,
  RecordMode.cooper => engine.RunMode.cooper,
};

/// Short label per run type ("4x4", "LAPS", "FREE", "TEST").
String modeLabel(RecordMode m) => switch (m) {
  RecordMode.intervals => 'INT',
  RecordMode.laps => 'LAPS',
  RecordMode.free => 'FREE',
  RecordMode.cooper => 'TEST',
};

String modeTitle(RecordMode m) => switch (m) {
  RecordMode.intervals => 'Intervals',
  RecordMode.laps => 'Laps run',
  RecordMode.free => 'Free run',
  RecordMode.cooper => '12-minute test',
};

/// Short tag for a run in History (4x4 keeps its own, fartlek is a Laps
/// run carrying the fartlek session, plan §3.5).
String runLabel(RunSummary r) => switch (r.mode) {
  RecordMode.intervals when _isFourByFour(r) => '4x4',
  RecordMode.laps when r.spec?.templateId == engine.SessionSpec.fartlekId =>
    'FRT',
  _ => modeLabel(r.mode),
};

/// Title for a run: the session's name for Intervals and fartlek. A Phase 1
/// by-feel 4x4 (no session, analysed as a 4x4) is still a Norwegian 4x4.
String runTitle(RunSummary r) => switch (r.mode) {
  RecordMode.intervals || RecordMode.laps when r.spec != null => r.spec!.name,
  RecordMode.intervals when _isFourByFour(r) =>
    engine.SessionCatalogue.norwegian4x4.name,
  _ => modeTitle(r.mode),
};

/// Header title: a 4x4 keeps its Phase 1 name "4x4" (existing screens
/// word for word); every other session uses [runTitle].
String runHeaderTitle(RunSummary r) =>
    runLabel(r) == '4x4' ? '4x4' : runTitle(r);

/// A spec-less Intervals run predates I4, when the 4x4 was the only session.
bool _isFourByFour(RunSummary r) =>
    r.spec == null || r.spec!.templateId == engine.SessionSpec.norwegian4x4Id;

@immutable
class RunSummary {
  const RunSummary({
    required this.id,
    required this.mode,
    required this.start,
    required this.durationMs,
    required this.distanceM,
    required this.laps,
    this.spec,
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

  /// The recorded session (schema 3); null for Laps / Free and by-feel
  /// intervals.
  final engine.SessionSpec? spec;

  /// Indexed but the file is gone (plan §2 rule 5); shown, never hidden.
  final bool missing;

  /// The 4x4 verdict (frozen or computed); null for other types / missing.
  final engine.Verdict? verdict;

  /// Full analysis when the file was readable (History rows and Trend read
  /// medians, fade and bests off it).
  final engine.RunAnalysis? analysis;

  bool get isFourByFour => mode == RecordMode.intervals;

  /// Whole-run average pace, s/km; null when no distance.
  double? get avgSecPerKm =>
      distanceM > 0 ? durationMs / 1000 / (distanceM / 1000) : null;

  /// Headline pace for the row: work pace for a 4x4, whole-run otherwise.
  double? get headlineSecPerKm => isFourByFour
      ? (analysis?.intervals?.avgWorkPaceSecPerKm ?? avgSecPerKm)
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

/// The verdict a run shows. Founder decision 25-Sep (overrides the plan's
/// frozen-verdict rule across engine bumps): when the engine version
/// changes, past verdicts are RECALCULATED so verdict and tables always
/// agree; the previous text moves to the sidecar's verdict history (the
/// engine's `freezeInto` does that). Fix-laps edits and overrides still
/// apply on top. Within one engine version the frozen verdict is restored
/// unchanged (the engine's `VerdictSource.frozen` path).
engine.Verdict? displayVerdict(
  engine.RunSidecar? sidecar,
  engine.RunAnalysis? analysis,
) => analysis?.verdict;

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
  }) : runEngine = runEngine ?? const engine.RunEngine(names: kEventNames);

  final engine.UserProfile Function() profile;
  final DateTime Function() now;
  final engine.RunEngine runEngine;

  /// Oldest → newest; returns analyses keyed by id plus the computed
  /// verdicts to freeze (the caller persists those through
  /// [freezeTransform]).
  ({
    Map<String, engine.RunAnalysis> analyses,
    Map<String, engine.Verdict> frozen,
  })
  run(List<engine.RunFile> runs, Map<String, engine.RunSidecar> sidecars) {
    final ordered = List.of(runs)..sort((a, b) => a.start.compareTo(b.start));
    final priors = <engine.PriorRun>[];
    final analyses = <String, engine.RunAnalysis>{};
    final frozen = <String, engine.Verdict>{};
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
      // A computed verdict (first analysis, fix-laps/override, or an engine
      // bump) is frozen; `freezeInto` moves a superseded one to history.
      if (a.verdict != null &&
          a.verdictSource == engine.VerdictSource.computed) {
        frozen[run.id] = a.verdict!;
      }
      final prior = a.asPrior(run.start);
      if (prior != null) priors.add(prior);
    }
    return (analyses: analyses, frozen: frozen);
  }
}

/// Freeze [verdict] onto the sidecar as it is on disk NOW (read inside the
/// writer's critical section). Returns [current] unchanged, so nothing is
/// written, when:
/// - the verdict was computed from other inputs (a fix-laps edit or override
///   landed while `list()` was analysing: that write froze its own verdict);
/// - the same verdict is already frozen.
engine.RunSidecar Function(engine.RunSidecar) freezeTransform(
  engine.Verdict verdict,
) => (current) {
  if (current.inputsKey != verdict.inputsKey) return current;
  final f = current.frozenVerdict;
  if (f != null && jsonEncode(f.toJson()) == jsonEncode(verdict.toJson())) {
    return current;
  }
  return current.withFrozenVerdict(verdict);
};

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
  spec: run.session,
  // Only a 4x4 carries a verdict word (plan §18.2); guard by the effective
  // mode so nothing else ever shows one.
  verdict:
      recordModeOf(sidecar?.runTypeOverride ?? a?.mode ?? run.mode) ==
          RecordMode.intervals
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
      final current = sidecars[e.key] ?? engine.RunSidecar(runId: e.key);
      final next = freezeTransform(e.value)(current);
      if (identical(next, current)) continue;
      sidecars[e.key] = next;
      written.add(next);
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
              spec: f.spec?.toEngine(),
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
/// Kotlin, `run-<id>.edits.json` written here, only via [sidecars].
class FileRunStore implements RunStore {
  FileRunStore(
    this.runsDir, {
    Directory? archiveDir,
    SidecarWriter? sidecarWriter,
    engine.UserProfile Function()? profile,
    DateTime Function()? now,
  }) : archiveDir =
           archiveDir ?? Directory('${runsDir.parent.path}/runs-archive'),
       sidecars = sidecarWriter ?? SidecarWriter(),
       _analyser = _Analyser(
         profile: profile ?? (() => engine.UserProfile.none),
         now: now ?? DateTime.now,
       );

  final Directory runsDir;
  final Directory archiveDir;

  /// Every sidecar write goes through here (one per app: pass the same
  /// writer to every store over the same directory).
  final SidecarWriter sidecars;
  final _Analyser _analyser;

  /// Test seam: runs after `list()`/`load()` analysed its scan and before it
  /// freezes verdicts (where a concurrent edit used to be overwritten).
  @visibleForTesting
  Future<void> Function()? afterAnalyse;

  static final _name = RegExp(r'^run-(.+)\.json\.gz$');

  /// `files/state/index.json` (Phase 3 W5), next to `files/runs/`.
  File get indexFile => File('${runsDir.parent.path}/state/index.json');

  /// The summary cache as last written (empty when missing or damaged).
  Future<RunIndex> readIndex() => RunIndex.read(indexFile);

  /// Brings the cache in line with the files after an analysis pass: an
  /// entry is rebuilt only when its run file, its sidecar or the engine
  /// changed (run AND sidecar mtime, re-check INFO); runs that are gone
  /// drop out. Written only when something changed. A cache failure never
  /// fails the list.
  Future<void> _updateIndex(
    Map<String, (engine.RunFile, engine.RunSidecar?, File)> scanned,
    Map<String, engine.RunAnalysis> analyses,
  ) async {
    try {
      final old = await readIndex();
      final next = <String, RunIndexEntry>{};
      for (final e in scanned.entries) {
        final (run, sidecar, file) = e.value;
        final stamp = await FileStamp.of(file, _sidecarFor(file));
        if (stamp == null) continue;
        final have = old.entries[e.key];
        if (have != null && have.isFresh(stamp)) {
          next[e.key] = have;
          continue;
        }
        final a = analyses[e.key];
        next[e.key] = RunIndexEntry.of(
          run: run,
          sidecar: sidecar,
          a: a,
          shownVerdict: _summaryOf(run, sidecar, a).verdict,
          stamp: stamp,
        );
      }
      final text = RunIndex(next).encode();
      await sidecars.replaceText('index.json', indexFile, (_) => text);
      _queueDerived(next, scanned, analyses);
    } catch (e) {
      debugPrint('index: not updated ($e)');
    }
  }

  /// Builds Phase 4 derived data for [jobs] (run, analysis) and returns it
  /// by run id (null = it threw). Default: one background isolate per
  /// batch, never the UI isolate (plan WARN-3; ~50 ms per 2 h run, ~10 s
  /// for 200 runs after an engine bump). Test seam.
  @visibleForTesting
  Future<Map<String, engine.RunDerived?>> Function(
    List<(engine.RunFile, engine.RunAnalysis)> jobs,
  )
  deriveBatch = _deriveInIsolate;

  static Future<Map<String, engine.RunDerived?>> _deriveInIsolate(
    List<(engine.RunFile, engine.RunAnalysis)> jobs,
  ) => Isolate.run(
    () => {
      for (final (run, a) in jobs) run.id: RunIndexEntry.deriveOrNull(run, a),
    },
  );

  Future<void>? _deriving;

  /// Completes when no derived-data batch is running (tests, diagnostics).
  @visibleForTesting
  Future<void> get derivedIdle => _deriving ?? Future<void>.value();

  /// Starts one background batch for every entry still missing derived
  /// data. `list()` never waits for it: boards fill in when it lands. One
  /// batch at a time; a list during a batch leaves the rest to the next.
  void _queueDerived(
    Map<String, RunIndexEntry> entries,
    Map<String, (engine.RunFile, engine.RunSidecar?, File)> scanned,
    Map<String, engine.RunAnalysis> analyses,
  ) {
    if (_deriving != null) return;
    final jobs = <(engine.RunFile, engine.RunAnalysis)>[];
    final at = <String, RunIndexEntry>{};
    for (final e in entries.entries) {
      final a = analyses[e.key];
      if (e.value.derived != null || e.value.derivedFailed || a == null) {
        continue;
      }
      jobs.add((scanned[e.key]!.$1, a));
      at[e.key] = e.value;
    }
    if (jobs.isEmpty) return;
    _deriving = _fillDerived(jobs, at).whenComplete(() => _deriving = null);
  }

  Future<void> _fillDerived(
    List<(engine.RunFile, engine.RunAnalysis)> jobs,
    Map<String, RunIndexEntry> at,
  ) async {
    try {
      final built = await deriveBatch(jobs);
      // The store's directory can be gone by now (a test tore it down).
      if (!await indexFile.parent.exists()) return;
      await sidecars.replaceText('index.json', indexFile, (current) {
        final index = RunIndex.decode(current);
        var changed = false;
        final next = {...index.entries};
        for (final r in built.entries) {
          final now = next[r.key];
          final then = at[r.key];
          // Only onto the same version of the entry it was built from; a
          // run edited meanwhile is rebuilt and queued again.
          if (now == null || then == null || !now.sameStampAs(then)) continue;
          if (now.derived != null) continue;
          next[r.key] = now.withDerived(r.value);
          changed = true;
        }
        return changed ? RunIndex(next).encode() : null;
      });
    } catch (e) {
      debugPrint('index: derived data not built ($e)');
    }
  }

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

  /// W6: a sidecar from a newer app rethrows (kept read-only, never
  /// rewritten); a damaged one reads as null.
  Future<engine.RunSidecar?> _readSidecar(File f) => SidecarWriter.read(f);

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
    await afterAnalyse?.call();
    for (final e in r.frozen.entries) {
      final entry = scanned[e.key]!;
      try {
        final now = await sidecars.update(
          e.key,
          _sidecarFor(entry.$3),
          freezeTransform(e.value),
          runFile: entry.$3,
        );
        scanned[e.key] = (entry.$1, now, entry.$3);
      } catch (err) {
        debugPrint('history: could not freeze verdict for ${e.key} ($err)');
      }
    }
    return (scanned: scanned, analyses: r.analyses);
  }

  @override
  Future<List<RunSummary>> list() async {
    final r = await _scanAndAnalyse();
    await _updateIndex(r.scanned, r.analyses);
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
    // The change applies to the sidecar as it is inside the writer's
    // critical section, not to the scan's copy; a refused edit throws
    // there and nothing is written.
    await sidecars.update(id, _sidecarFor(v.$3), (current) {
      final next = change(current);
      _checkEdits(_analyser, v.$1, next);
      return next;
    }, runFile: v.$3);
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

  /// Every readable run with its sidecar, for the weather queue (W1).
  Future<List<(engine.RunFile, engine.RunSidecar?)>> weatherCandidates() async {
    final scanned = await _scan();
    return [for (final v in scanned.values) (v.$1, v.$2)];
  }

  /// Store a run's weather in its sidecar (through the writer; nothing is
  /// written once the run is deleted). Weather never touches the verdict:
  /// the frozen one stays as it is (plan §18.5).
  Future<void> setWeather(String id, engine.WeatherRecord weather) async {
    final scanned = await _scan();
    final v = scanned[id];
    if (v == null) return;
    await sidecars.update(
      id,
      _sidecarFor(v.$3),
      (current) => current.copyWith(weather: weather.toJson()),
      runFile: v.$3,
    );
  }

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
          await sidecars.update(
            b.run.id,
            _sidecarFor(runFile),
            (_) => b.sidecar!,
          );
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
    await sidecars.deleteRun(id, v.$3, _sidecarFor(v.$3));
    await sidecars.replaceText('index.json', indexFile, (current) {
      final index = RunIndex.decode(current);
      if (!index.entries.containsKey(id)) return null;
      return RunIndex({...index.entries}..remove(id)).encode();
    });
  }
}

/// Phase 1 name, kept for callers; the store is the same object.
typedef MemoryHistoryStore = MemoryRunStore;
typedef FileHistoryStore = FileRunStore;
