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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../app/event_names.dart';
import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';
import '../platform/session_codec.dart';
import 'boards.dart';
import 'coaching.dart';
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
    this.row,
    this.indexedComparisonKey,
    this.indexedOfficialTime,
    this.parkrun,
    this.indexedHeatFraction,
    this.eventStart,
  });

  /// From the index (W5b): no file decoded, no analysis.
  factory RunSummary.fromEntry(RunIndexEntry e) => RunSummary(
    id: e.id,
    mode: recordModeOf(e.mode),
    start: e.start,
    durationMs: e.durationMs,
    distanceM: e.distanceM,
    laps: e.row!.lapCount,
    spec: e.row!.session,
    verdict: e.row!.verdict,
    row: e.row,
    indexedComparisonKey: e.comparisonKey,
    indexedOfficialTime: e.prior?.officialTime,
    indexedHeatFraction: e.heatAdj,
    eventStart: e.row!.eventStartLat == null || e.row!.eventStartLon == null
        ? null
        : (lat: e.row!.eventStartLat!, lon: e.row!.eventStartLon!),
  );

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

  /// Full analysis, only on the memory store and tests. The file store
  /// lists from the index (W5b): read the figures below, never this.
  final engine.RunAnalysis? analysis;

  /// The index row the figures come from (file store).
  final IndexRow? row;

  /// The key from the index (file store); the analysis's otherwise.
  final String? indexedComparisonKey;

  /// K1: an event run's first fix; null otherwise or without a fix.
  final ({double lat, double lon})? eventStart;

  String? get comparisonKey => indexedComparisonKey ?? analysis?.comparisonKey;

  /// K1: the headline is the runner's official time (index prior, file
  /// store); null when the index does not say (memory store, no prior).
  final bool? indexedOfficialTime;

  /// The heat slowdown from the index (file store; null without usable
  /// weather or when too hot to compare).
  final double? indexedHeatFraction;

  /// W1/W2: this run's heat slowdown (0.047 = 4.7%, 0 when cool); null
  /// without usable weather or when too hot to compare.
  double? get heatFraction => indexedHeatFraction ?? analysis?.heat?.fraction;

  /// The heat-adjusted twin of [workPaceSecPerKm] (W2 trend).
  double? get heatAdjustedWorkPaceSecPerKm {
    final p = workPaceSecPerKm, f = heatFraction;
    return p == null || f == null ? null : p * (1 - f);
  }

  /// A 12-minute test's figures (C1): the row's, else the analysis's.
  CooperFigures? get cooper =>
      row?.cooper ?? CooperFigures.of(analysis?.cooper);

  /// Intervals figures (null when the run has no interval metrics).
  int? get detectedReps =>
      row?.detectedReps ?? analysis?.intervals?.reps.length;
  double? get workPaceSecPerKm =>
      row?.workPaceSecPerKm ?? analysis?.intervals?.avgWorkPaceSecPerKm;
  double? get fadeSecPerKm =>
      row?.fadeSecPerKm ?? analysis?.intervals?.fadeSecPerKm;
  double? get recoveryPaceSecPerKm =>
      row?.recoveryPaceSecPerKm ?? analysis?.intervals?.recoveryPaceSecPerKm;

  /// Every rep's pace (null when it has none), and the clean ones only.
  List<double?> get repPacesSecPerKm =>
      row?.repPacesSecPerKm ??
      [
        for (final r
            in analysis?.intervals?.reps ?? const <engine.RepMetrics>[])
          r.paceSecPerKm,
      ];
  List<double?> get cleanRepPacesSecPerKm {
    final clean =
        row?.repClean ??
        [
          for (final r
              in analysis?.intervals?.reps ?? const <engine.RepMetrics>[])
            r.clean,
        ];
    final paces = repPacesSecPerKm;
    return [
      for (var i = 0; i < paces.length; i++)
        i < clean.length && clean[i] ? paces[i] : null,
    ];
  }

  bool get eligibleAsPrior =>
      row?.eligibleAsPrior ?? analysis?.eligibleAsPrior ?? false;
  bool get hasIntervals => detectedReps != null;

  /// K1: course and official time from the sidecar; null when neither.
  final engine.ParkrunInfo? parkrun;

  bool get isFourByFour => mode == RecordMode.intervals;

  /// The Saturday 5 km event (K1), by its session template.
  bool get isParkrun => spec?.templateId == engine.SessionSpec.parkrunId;

  /// Whole-run average pace, s/km; null when no distance.
  double? get avgSecPerKm =>
      distanceM > 0 ? durationMs / 1000 / (distanceM / 1000) : null;

  /// Headline pace for the row: work pace for a 4x4, whole-run otherwise.
  double? get headlineSecPerKm =>
      isFourByFour ? (workPaceSecPerKm ?? avgSecPerKm) : avgSecPerKm;
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

  /// Personal leaderboards over every run (LB3): the LB2 fold of the index.
  /// A fold made before the background batch has built some run's best
  /// efforts says so ([Boards.updating]); fold again on [derivedChanged].
  Future<Boards> boards();

  /// CR2: after-run coaching and Home's "try next" over the same entries
  /// as [boards]; a run without derived data yet has none (fold again on
  /// [derivedChanged]).
  Future<Coaching> coaching();

  /// Fires each time a background batch writes derived data (best efforts)
  /// into the index, however long after the run it lands (#71 review P1):
  /// a result screen re-folds its chips then.
  Listenable get derivedChanged;
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

  /// K1: the runner's official time in whole seconds (null clears it). The
  /// verdict is recomputed with it; callers validate first.
  Future<RunDetail> setOfficialTime(String id, int? seconds);

  /// K1: move an event run to another course (the runner's pick).
  Future<RunDetail> setCourse(String id, String courseId);
  Future<void> delete(String id);
}

/// K1: [info] with one field changed, keeping the other.
engine.ParkrunInfo _parkrunWith(
  engine.ParkrunInfo? info, {
  Object? courseId = _keep,
  Object? officialTimeSeconds = _keep,
}) {
  final base = info ?? const engine.ParkrunInfo();
  return engine.ParkrunInfo(
    courseId: identical(courseId, _keep) ? base.courseId : courseId as String?,
    officialTimeSeconds: identical(officialTimeSeconds, _keep)
        ? base.officialTimeSeconds
        : officialTimeSeconds as int?,
  );
}

const _keep = Object();

/// K1 course tags still to write: every event run without a course gets
/// one, oldest first, so a new course's first run names the id and later
/// runs join it (`ParkrunCourses.assign`, 150 m). Runs without a fix stay
/// untagged (retried on the next pass). Pure; returns id → course id.
Map<String, String> pendingCourseTags(
  List<engine.RunFile> runs,
  engine.RunSidecar? Function(String id) sidecarOf,
) {
  final events =
      runs
          .where((r) => r.session?.templateId == engine.SessionSpec.parkrunId)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  final known = <engine.ParkrunCourseStart>[];
  final out = <String, String>{};
  for (final run in events) {
    final have = sidecarOf(run.id)?.parkrun?.courseId;
    final start = engine.ParkrunCourses.startOf(run);
    final id = have ?? engine.ParkrunCourses.assign(run, known);
    if (id == null) continue;
    if (have == null) out[run.id] = id;
    if (start != null) {
      known.add(
        engine.ParkrunCourseStart(courseId: id, lat: start.lat, lon: start.lon),
      );
    }
  }
  return out;
}

/// Sidecar transform for a course tag: only while the run is still
/// untagged (a runner's pick that landed meanwhile wins).
engine.RunSidecar Function(engine.RunSidecar) courseTagTransform(
  String courseId,
) =>
    (current) => current.parkrun?.courseId != null
    ? current
    : current.withParkrun(_parkrunWith(current.parkrun, courseId: courseId));

/// Shared analysis pass over decoded runs (memory and file stores).
class _Analyser {
  _Analyser({
    required this.profile,
    required this.now,
    bool Function()? heatCompare,
    engine.RunEngine? runEngine,
  }) : heatCompare = heatCompare ?? _off,
       runEngine = runEngine ?? const engine.RunEngine(names: kEventNames);

  static bool _off() => false;

  final engine.UserProfile Function() profile;
  final DateTime Function() now;

  /// "Compare heat-adjusted paces" (W2), read at each pass.
  final bool Function() heatCompare;
  final engine.RunEngine runEngine;

  /// Oldest → newest; returns analyses keyed by id plus the computed
  /// verdicts to freeze (the caller persists those through
  /// [freezeTransform]).
  ({
    Map<String, engine.RunAnalysis> analyses,
    Map<String, engine.Verdict> frozen,
  })
  run(
    List<engine.RunFile> runs,
    Map<String, engine.RunSidecar> sidecars, {
    List<engine.PriorRun> seedPriors = const [],
  }) {
    final ordered = List.of(runs)..sort((a, b) => a.start.compareTo(b.start));
    // Priors of runs not analysed here (W5b: from the index). The engine
    // only compares earlier runs of the same key, so all may be passed.
    final priors = List.of(seedPriors);
    final analyses = <String, engine.RunAnalysis>{};
    final frozen = <String, engine.Verdict>{};
    final p = profile();
    final heat = heatCompare();
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
          compareHeatAdjusted: heat,
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
  parkrun: sidecar?.parkrun,
  eventStart: run.session?.templateId == engine.SessionSpec.parkrunId
      ? engine.ParkrunCourses.startOf(run)
      : null,
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
    bool Function()? heatCompare,
  }) : runs = runs ?? [],
       files = files ?? [],
       sidecars = sidecars ?? {},
       _analyser = _Analyser(
         profile: profile ?? (() => engine.UserProfile.none),
         now: now ?? DateTime.now,
         heatCompare: heatCompare,
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
    for (final e in pendingCourseTags(live, (id) => sidecars[id]).entries) {
      final current = sidecars[e.key] ?? engine.RunSidecar(runId: e.key);
      final next = courseTagTransform(e.value)(current);
      sidecars[e.key] = next;
      written.add(next);
    }
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

  /// The same index entries the file store keeps, built in memory (derived
  /// data included), so the boards match a phone's.
  /// Derived data is built in line here, except for runs a test holds back
  /// in [underived] (a slow phone's batch); [landDerived] releases them.
  @override
  Listenable get derivedChanged => _derivedChanged;
  final ValueNotifier<int> _derivedChanged = ValueNotifier(0);

  /// Test seam: runs whose best efforts have "not been built yet".
  @visibleForTesting
  final Set<String> underived = {};

  /// Test seam: the held-back batch lands (fires [derivedChanged]).
  @visibleForTesting
  void landDerived() {
    underived.clear();
    _derivedChanged.value++;
  }

  @override
  Future<Boards> boards() async => Boards.fold(_entries());

  @override
  Future<Coaching> coaching() async => Coaching.fold(_entries());

  /// What the index would hold for every run (boards, coaching).
  List<RunIndexEntry> _entries() {
    final analyses = _analyse();
    return [
      for (final f in files.where((f) => !_deleted.contains(f.id)))
        if (analyses[f.id] case final a?)
          if (RunIndexEntry.of(
                run: f,
                sidecar: sidecars[f.id],
                a: a,
                shownVerdict: a.verdict,
                stamp: const FileStamp(runMtimeMs: 0, runBytes: 0),
              )
              case final e)
            // Held back: no derived data and not failed (pending).
            underived.contains(f.id)
                ? e
                : e.withDerived(RunIndexEntry.deriveOrNull(f, a)),
    ];
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
  Future<RunDetail> setOfficialTime(String id, int? seconds) => _mutate(
    id,
    (s) => s.withParkrun(_parkrunWith(s.parkrun, officialTimeSeconds: seconds)),
  );

  @override
  Future<RunDetail> setCourse(String id, String courseId) => _mutate(
    id,
    (s) => s.withParkrun(_parkrunWith(s.parkrun, courseId: courseId)),
  );

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
    bool Function()? heatCompare,
    engine.RunEngine? runEngine,
  }) : archiveDir =
           archiveDir ?? Directory('${runsDir.parent.path}/runs-archive'),
       sidecars = sidecarWriter ?? SidecarWriter(),
       _analyser = _Analyser(
         profile: profile ?? (() => engine.UserProfile.none),
         now: now ?? DateTime.now,
         heatCompare: heatCompare,
         runEngine: runEngine,
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

  /// Fingerprint of the analysis inputs that live outside the files (W5b):
  /// the max-HR resolver's inputs, the event names and (W2) the
  /// heat-compare setting, spelled only when on so an update with it off
  /// rebuilds nothing. A change rebuilds every entry.
  String _inputs() {
    final p = _analyser.profile();
    return 'p:${p.age}|${p.maxHr}|${p.observedMaxHr};'
        'n:${_analyser.runEngine.names.parkrun}'
        '${_analyser.heatCompare() ? ';h:1' : ''}';
  }

  /// Run files by id, from their names only (nothing decoded).
  Future<Map<String, File>> _files() async {
    final out = <String, File>{};
    for (final dir in [runsDir, archiveDir]) {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final m = _name.firstMatch(entity.uri.pathSegments.last);
        if (m != null) out[m.group(1)!] = entity;
      }
    }
    return out;
  }

  Future<File?> _fileFor(String id) async {
    for (final dir in [runsDir, archiveDir]) {
      final f = File('${dir.path}/run-$id.json.gz');
      if (await f.exists()) return f;
    }
    return null;
  }

  /// Test seam (W5b): the file names `_decode` read, in order.
  @visibleForTesting
  final List<String> decoded = [];

  Future<(engine.RunFile, engine.RunSidecar?)?> _decode(File f) async {
    decoded.add(f.uri.pathSegments.last);
    try {
      final text = utf8.decode(gzip.decode(await f.readAsBytes()));
      final run = engine.RunFileCodec.decode(text);
      return (run, await _readSidecar(_sidecarFor(f)));
    } catch (e) {
      // A newer-schema or damaged file is the Reconciler's problem later;
      // the list must never crash on one bad file.
      debugPrint('history: skipped ${f.uri.pathSegments.last} ($e)');
      return null;
    }
  }

  /// Leftovers of a crash between a tmp write and its rename (#21 review
  /// P3): sidecar and index tmp files older than a minute count against the
  /// `runs/` backup budget and are never read.
  Future<void> _sweepTmp() async {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    final tmp = RegExp(r'(\.edits\.json|index\.json)\.[^/]*\.tmp$');
    for (final dir in [runsDir, archiveDir, indexFile.parent]) {
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is! File || !tmp.hasMatch(e.path)) continue;
        try {
          if ((await e.stat()).modified.isBefore(cutoff)) await e.delete();
        } catch (_) {}
      }
    }
  }

  /// Brings the cache in line with the files and returns it (W5b). Only
  /// stale entries are decoded and analysed:
  /// - no entry, or the run file, sidecar, engine or row version changed;
  /// - every entry when the inputs fingerprint changed ([_inputs]);
  /// - every later run of a key whose earlier run was deleted, or rebuilt
  ///   with a different prior or key (old and new key both count); a rebuild
  ///   that leaves both alone (weather, notes) cascades nowhere.
  /// Earlier runs that stay fresh feed their index priors. Computed
  /// verdicts are frozen, then stamped. An entry rebuilt only for inputs or
  /// priors keeps its derived data. Written only when something changed; a
  /// cache failure falls back to what was read.
  Future<RunIndex> _refresh() async {
    await _sweepTmp();
    final files = await _files();
    final old = await readIndex();
    // K1: tag event runs with a course before anything is stamped, so a
    // tag's sidecar write makes its entry stale in this same pass.
    // The files it had to decode are reused below (never decoded twice).
    final tagDecoded = await _tagCourses(files, old);
    final inputs = _inputs();
    final allStale = old.inputs != inputs;
    final stamps = <String, FileStamp>{};
    for (final e in files.entries) {
      final stamp = await FileStamp.of(e.value, _sidecarFor(e.value));
      if (stamp != null) stamps[e.key] = stamp;
    }
    final affected = <String>{
      for (final id in stamps.keys)
        if (allStale || !(old.entries[id]?.isFresh(stamps[id]!) ?? false)) id,
      // An entry from before K1's no-fix mark: rebuilt once to carry it.
      for (final MapEntry(key: id, value: (run, sidecar)) in tagDecoded.entries)
        if (stamps.containsKey(id) &&
            old.entries[id]?.courseNoFix == false &&
            run.session?.templateId == engine.SessionSpec.parkrunId &&
            sidecar?.parkrun?.courseId == null &&
            engine.ParkrunCourses.startOf(run) == null)
          id,
    };
    final gone = [
      for (final e in old.entries.values)
        if (!stamps.containsKey(e.id)) e,
    ];

    final decoded = <String, (engine.RunFile, engine.RunSidecar?)>{
      ...tagDecoded,
    };
    var analyses = <String, engine.RunAnalysis>{};
    var frozen = <String, engine.Verdict>{};
    while (true) {
      for (final id in affected) {
        if (decoded.containsKey(id)) continue;
        final d = await _decode(files[id]!);
        if (d != null) decoded[id] = d;
      }
      final r = _analyser.run(
        [for (final id in affected) ?decoded[id]?.$1],
        {
          for (final id in affected)
            if (decoded[id]?.$2 != null) id: decoded[id]!.$2!,
        },
        seedPriors: [
          for (final e in old.entries.values)
            if (!affected.contains(e.id) && stamps.containsKey(e.id)) ?e.prior,
        ],
      );
      analyses = r.analyses;
      frozen = r.frozen;
      // Earliest changed start per key (old and new keys, deleted runs).
      final since = <String, DateTime>{};
      void mark(String? key, DateTime start) {
        if (key == null) return;
        final s = since[key];
        if (s == null || start.isBefore(s)) since[key] = start;
      }

      for (final e in gone) {
        mark(e.comparisonKey, e.start);
      }
      for (final id in affected) {
        final start = decoded[id]?.$1.start ?? old.entries[id]?.start;
        if (start == null) continue;
        // Later runs only see this run through its prior and its key: a
        // rebuild that changed neither (a weather write, a note) cascades
        // nowhere.
        final was = old.entries[id];
        final nowKey = analyses[id]?.comparisonKey;
        final nowPrior = analyses[id]?.asPrior(start);
        if (was != null &&
            was.comparisonKey == nowKey &&
            jsonEncode(was.prior?.toJson()) == jsonEncode(nowPrior?.toJson())) {
          continue;
        }
        mark(was?.comparisonKey, start);
        mark(nowKey, start);
      }
      final more = [
        for (final e in old.entries.values)
          if (stamps.containsKey(e.id) &&
              !affected.contains(e.id) &&
              since[e.comparisonKey]?.isBefore(e.start) == true)
            e.id,
      ];
      if (more.isEmpty) break;
      affected.addAll(more);
    }

    await afterAnalyse?.call();
    for (final e in frozen.entries) {
      final file = files[e.key]!;
      try {
        final now = await sidecars.update(
          e.key,
          _sidecarFor(file),
          freezeTransform(e.value),
          runFile: file,
        );
        decoded[e.key] = (decoded[e.key]!.$1, now);
      } catch (err) {
        debugPrint('history: could not freeze verdict for ${e.key} ($err)');
      }
    }

    final next = <String, RunIndexEntry>{};
    for (final id in stamps.keys) {
      if (!affected.contains(id)) {
        next[id] = old.entries[id]!;
        continue;
      }
      final d = decoded[id];
      if (d == null) continue;
      final file = files[id]!;
      final stamp = await FileStamp.of(file, _sidecarFor(file));
      if (stamp == null) continue;
      final (run, sidecar) = d;
      final a = analyses[id];
      next[id] = RunIndexEntry.of(
        run: run,
        sidecar: sidecar,
        a: a,
        shownVerdict: _summaryOf(run, sidecar, a).verdict,
        stamp: stamp,
      ).keepingDerivedOf(old.entries[id]);
    }
    final index = RunIndex(next, inputs: inputs);
    if (affected.isEmpty && gone.isEmpty && !allStale) {
      _queueDerived(next, files);
      return old;
    }
    try {
      await sidecars.replaceText('index.json', indexFile, (current) {
        // A derived batch may have landed since we read: keep its data on
        // every entry built from the same files.
        final now = RunIndex.decode(current);
        return RunIndex({
          for (final e in next.entries)
            e.key: e.value.keepingDerivedOf(now.entries[e.key]),
        }, inputs: inputs).encode();
      });
    } catch (e) {
      debugPrint('index: not updated ($e)');
    }
    final written = await readIndex();
    _queueDerived(written.entries, files);
    return written.inputs == inputs ? written : index;
  }

  /// Builds Phase 4 derived data for [jobs] and returns it by run id (null
  /// = it threw). Default: one background isolate per batch, never the UI
  /// isolate (plan WARN-3; ~50 ms per 2 h run, ~10 s for 200 runs after an
  /// engine bump). Only paths cross into the worker (a few hundred bytes
  /// per run): it reads, gunzips, decodes and analyses there, so the UI
  /// isolate never copies a sample array. Test seam.
  @visibleForTesting
  Future<Map<String, engine.RunDerived?>> Function(List<DeriveJob> jobs)
  deriveBatch = defaultDeriveBatch;

  /// What new stores use for [deriveBatch]. Tests set a no-op in
  /// `test/flutter_test_config.dart` so no background write outlives a test
  /// (a batch still writing index.json broke tearDown's directory delete);
  /// the tests that exercise it opt back in with [deriveInIsolate].
  @visibleForTesting
  static Future<Map<String, engine.RunDerived?>> Function(List<DeriveJob> jobs)
  defaultDeriveBatch = deriveInIsolate;

  static Future<Map<String, engine.RunDerived?>> deriveInIsolate(
    List<DeriveJob> jobs,
  ) => Isolate.run(() => {for (final j in jobs) j.id: j.run()});

  Future<void>? _deriving;

  /// Completes when no derived-data batch is running (tests, diagnostics).
  @visibleForTesting
  Future<void> get derivedIdle => _deriving ?? Future<void>.value();

  /// Starts one background batch for every entry still missing derived
  /// data. `list()` never waits for it: boards fill in when it lands. One
  /// batch at a time; a list during a batch leaves the rest to the next.
  void _queueDerived(
    Map<String, RunIndexEntry> entries,
    Map<String, File> files,
  ) {
    if (_deriving != null) return;
    final jobs = <DeriveJob>[];
    final at = <String, RunIndexEntry>{};
    for (final e in entries.entries) {
      // The worker re-reads and re-analyses from the paths; a run it cannot
      // analyse comes back as failed and is not retried until it changes.
      final file = files[e.key];
      // Built at an older derived version (a new board, §G): refill once.
      final have = e.value.derived;
      if ((have != null && have.isCurrent) ||
          e.value.derivedFailed ||
          file == null) {
        continue;
      }
      jobs.add(
        DeriveJob(
          id: e.key,
          runPath: file.path,
          sidecarPath: _sidecarFor(file).path,
          runEngine: _analyser.runEngine,
        ),
      );
      at[e.key] = e.value;
    }
    if (jobs.isEmpty) return;
    _deriving = _fillDerived(jobs, at).then((changed) {
      _deriving = null;
      // After _deriving is cleared: a listener's re-fold (boards() →
      // _refresh) can then queue the next batch if a run still lacks data.
      if (changed) _derivedChanged.value++;
    });
  }

  /// True when the index gained derived data.
  Future<bool> _fillDerived(
    List<DeriveJob> jobs,
    Map<String, RunIndexEntry> at,
  ) async {
    var changed = false;
    try {
      final built = await deriveBatch(jobs);
      // The store's directory can be gone by now (a test tore it down).
      if (!await indexFile.parent.exists()) return false;
      await sidecars.replaceText('index.json', indexFile, (current) {
        final index = RunIndex.decode(current);
        changed = false;
        final next = {...index.entries};
        for (final r in built.entries) {
          final now = next[r.key];
          final then = at[r.key];
          // Only onto the same version of the entry it was built from; a
          // run edited meanwhile is rebuilt and queued again.
          if (now == null || then == null || !now.sameStampAs(then)) continue;
          if (now.derived?.isCurrent ?? false) continue;
          // A failed refill keeps the older data rather than losing it.
          if (r.value == null && now.derived != null) continue;
          next[r.key] = now.withDerived(r.value);
          changed = true;
        }
        return changed ? RunIndex(next, inputs: index.inputs).encode() : null;
      });
    } catch (e) {
      debugPrint('index: derived data not built ($e)');
      return false;
    }
    return changed;
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

  @override
  Future<Boards> boards() async =>
      Boards.fold((await _refresh()).entries.values);

  @override
  Future<Coaching> coaching() async =>
      Coaching.fold((await _refresh()).entries.values);

  /// Bumps once per batch written.
  final ValueNotifier<int> _derivedChanged = ValueNotifier(0);

  @override
  Listenable get derivedChanged => _derivedChanged;

  @override
  Future<List<RunSummary>> list() async {
    final index = await _refresh();
    final out = [
      for (final e in index.entries.values)
        if (e.row != null) RunSummary.fromEntry(e),
    ];
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  /// One run in full: the cache is brought up to date first (so its frozen
  /// verdict and the priors are current), then only this file is decoded
  /// and analysed, with the other runs' priors from the index.
  @override
  Future<RunDetail?> load(String id) async {
    final index = await _refresh();
    final file = await _fileFor(id);
    if (file == null) return null;
    final d = await _decode(file);
    if (d == null) return null;
    final (run, sc) = d;
    final r = _analyser.run(
      [run],
      {id: ?sc},
      seedPriors: [
        for (final e in index.entries.values)
          if (e.id != id) ?e.prior,
      ],
    );
    final a = r.analyses[id];
    if (a == null) return null;
    final sidecar = sc ?? engine.RunSidecar(runId: id);
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
    final file = await _fileFor(id);
    final d = file == null ? null : await _decode(file);
    if (file == null || d == null) throw StateError('run $id not found');
    // The change applies to the sidecar as it is inside the writer's
    // critical section, not to the scan's copy; a refused edit throws
    // there and nothing is written.
    await sidecars.update(id, _sidecarFor(file), (current) {
      final next = change(current);
      _checkEdits(_analyser, d.$1, next);
      return next;
    }, runFile: file);
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
  Future<RunDetail> setOfficialTime(String id, int? seconds) => _mutate(
    id,
    (s) => s.withParkrun(_parkrunWith(s.parkrun, officialTimeSeconds: seconds)),
  );

  @override
  Future<RunDetail> setCourse(String id, String courseId) => _mutate(
    id,
    (s) => s.withParkrun(_parkrunWith(s.parkrun, courseId: courseId)),
  );

  /// K1: tag finished or imported event runs with a course, once, through
  /// the writer (plan: the app assigns after finalise, imports included).
  /// Only decodes when there is something to tag: a file the index does
  /// not know yet, or an event entry still keyed without a course. A run
  /// without a fix is marked in its entry (courseNoFix) and skipped from
  /// then on; a failed write only logs and is retried next time.
  Future<Map<String, (engine.RunFile, engine.RunSidecar?)>> _tagCourses(
    Map<String, File> files,
    RunIndex old,
  ) async {
    bool isEvent(RunIndexEntry e) =>
        e.templateId == engine.SessionSpec.parkrunId;
    final unknown = [
      for (final id in files.keys)
        if (!old.entries.containsKey(id)) id,
    ];
    // An event run with no GPS fix can never get a course: its entry
    // records that (courseNoFix) and it is not decoded again until its run
    // file or sidecar changes and the entry is rebuilt.
    final untagged = old.entries.values.any(
      (e) =>
          isEvent(e) &&
          files.containsKey(e.id) &&
          e.comparisonKey == engine.ComparisonKey.parkrun &&
          !e.courseNoFix,
    );
    if (unknown.isEmpty && !untagged) return {};
    final ids = {
      ...unknown,
      for (final e in old.entries.values)
        if (isEvent(e) && files.containsKey(e.id) && !e.courseNoFix) e.id,
    };
    final decoded = <String, (engine.RunFile, engine.RunSidecar?)>{};
    for (final id in ids) {
      final d = await _decode(files[id]!);
      if (d != null) decoded[id] = d;
    }
    final events = [
      for (final d in decoded.values)
        if (d.$1.session?.templateId == engine.SessionSpec.parkrunId) d.$1,
    ];
    final tags = pendingCourseTags(events, (id) => decoded[id]?.$2);
    for (final e in tags.entries) {
      try {
        decoded[e.key] = (
          decoded[e.key]!.$1,
          await sidecars.update(
            e.key,
            _sidecarFor(files[e.key]!),
            courseTagTransform(e.value),
            runFile: files[e.key],
          ),
        );
      } catch (err) {
        debugPrint('history: could not tag the course for ${e.key} ($err)');
      }
    }
    return decoded;
  }

  /// Every readable run with its sidecar, for the weather queue (W1).
  Future<List<(engine.RunFile, engine.RunSidecar?)>> weatherCandidates() async {
    final scanned = await _scan();
    return [for (final v in scanned.values) (v.$1, v.$2)];
  }

  /// Store a run's weather in its sidecar (through the writer; nothing is
  /// written once the run is deleted). Weather never touches the verdict:
  /// the frozen one stays as it is (plan §18.5).
  Future<void> setWeather(String id, engine.WeatherRecord weather) async {
    final file = await _fileFor(id);
    if (file == null) return;
    await sidecars.update(
      id,
      _sidecarFor(file),
      (current) => current.copyWith(weather: weather.toJson()),
      runFile: file,
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
    final plan = engine.planBundleImport(
      bundles,
      (await _files()).keys.toSet(),
    );
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
    final file = await _fileFor(id);
    if (file == null) return;
    await sidecars.deleteRun(id, file, _sidecarFor(file));
    // The entry goes now; later runs of its key lose a prior, so their rows
    // are dropped and rebuilt on the next list (W5b).
    await sidecars.replaceText('index.json', indexFile, (current) {
      final index = RunIndex.decode(current);
      final gone = index.entries[id];
      if (gone == null) return null;
      return RunIndex({
        for (final e in index.entries.values)
          if (e.id != id)
            e.id:
                e.comparisonKey != null &&
                    e.comparisonKey == gone.comparisonKey &&
                    e.start.isAfter(gone.start)
                ? e.withoutRow()
                : e,
      }, inputs: index.inputs).encode();
    });
  }
}

/// Phase 1 name, kept for callers; the store is the same object.
typedef MemoryHistoryStore = MemoryRunStore;
typedef FileHistoryStore = FileRunStore;

/// One run's Phase 4 derived-data job: file paths only, so the message to
/// the worker isolate is tiny. [run] executes in the worker.
@immutable
class DeriveJob {
  const DeriveJob({
    required this.id,
    required this.runPath,
    required this.sidecarPath,
    this.runEngine = const engine.RunEngine(),
  });

  final String id;
  final String runPath;
  final String sidecarPath;

  /// The store's engine (same constants as the UI-side analysis).
  final engine.RunEngine runEngine;

  /// Read, decode and analyse the run, then derive; null when any step
  /// throws. The analysis has no priors and no profile: neither changes
  /// the reps, laps or gates the derived data reads (only the verdict word
  /// and HR zones, which it does not use).
  engine.RunDerived? run() {
    try {
      final text = utf8.decode(gzip.decode(File(runPath).readAsBytesSync()));
      final r = engine.RunFileCodec.decode(text);
      final sc = File(sidecarPath);
      engine.RunSidecar? sidecar;
      if (sc.existsSync()) {
        try {
          sidecar = engine.RunSidecarCodec.decode(sc.readAsStringSync());
        } catch (_) {
          sidecar = null;
        }
      }
      return RunIndexEntry.deriveOrNull(
        r,
        runEngine.analyze(r, sidecar: sidecar),
      );
    } catch (e) {
      debugPrint('index: derived job $id failed ($e)');
      return null;
    }
  }
}
