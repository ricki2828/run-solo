import '../engine_version.dart';
import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../model/sidecar.dart';
import '../model/verdict.dart';
import '../run_mode.dart';
import 'constants.dart';
import 'fix_laps.dart';
import 'metrics.dart';
import 'rep_detector.dart';
import 'session_detector.dart';
import 'trace.dart';
import 'verdict_builder.dart';

/// Where the verdict on a [RunAnalysis] came from.
enum VerdictSource {
  /// Restored from the sidecar: same engine version, nothing recomputed.
  frozen,

  /// Computed now (first analysis, after fix-laps/override, or a version bump).
  computed,
}

/// The session run [run] is judged as under [mode] (the override when set):
/// - intervals: the file's session; a by-feel 4x4 (no session, or a Laps
///   run overridden to intervals) is judged as the default Norwegian 4x4,
///   so it keeps its history key `t240x*` (plan §3.8 mapping) while the
///   detector stays by-feel (`RunFile.preset` is null);
/// - cooper: the Cooper session; laps: the fartlek session when recorded as
///   one; free: none.
SessionSpec? effectiveSession(RunFile run, RunMode mode) {
  final own = run.session;
  return switch (mode) {
    RunMode.intervals =>
      own != null && own.steps.isNotEmpty && run.mode == RunMode.intervals
          ? own
          : SessionSpec.norwegian4x4(),
    RunMode.cooper => SessionSpec.cooper,
    RunMode.laps =>
      own?.templateId == SessionSpec.fartlekId ? SessionSpec.fartlek : null,
    RunMode.free => null,
  };
}

/// The comparison key of [session] under [mode]; null for laps and free
/// (a fartlek groups as `fartlek`).
String? comparisonKeyOf(SessionSpec? session, RunMode mode) => switch (mode) {
  RunMode.free => null,
  RunMode.laps =>
    session?.templateId == SessionSpec.fartlekId ? ComparisonKey.fartlek : null,
  RunMode.intervals || RunMode.cooper => session?.comparisonKey,
};

/// How [spec]'s headline is measured (Phase 3 §3.7): uniform distance reps
/// → rep time; other distance work → untrimmed pace over the measured laps;
/// a short-rep session (every rep under 90 s: 30/30s, 1-minute reps) →
/// untrimmed pace; otherwise (tempo, pyramid, custom) trimmed pace. The 4x4
/// key never gets here.
IntervalMetricKind metricKindOf(SessionSpec spec) {
  final work = spec.workSteps.toList();
  final distance = work.where((s) => s.target == TargetKind.distance);
  if (distance.isNotEmpty) {
    final uniform =
        distance.length == work.length &&
        work.every((s) => s.value == work.first.value);
    return uniform
        ? IntervalMetricKind.repTime
        : IntervalMetricKind.untrimmedPace;
  }
  return work.every((s) => s.value < 90)
      ? IntervalMetricKind.untrimmedPace
      : IntervalMetricKind.trimmedPace;
}

/// Clean reps a verdict needs: three for a 4x4 (as Phase 2), otherwise
/// three or the whole session when it has fewer reps.
int minCleanRepsFor(String key, SessionSpec? spec) {
  if (key == ComparisonKey.norwegian4x4 || spec == null) {
    return EngineConstants.minReps;
  }
  final n = spec.repCount;
  return n < EngineConstants.minReps ? n : EngineConstants.minReps;
}

/// Engine output (plan §5): reps, recovery spans, metrics, verdict, flags.
class RunAnalysis {
  const RunAnalysis({
    required this.runId,
    required this.mode,
    required this.detection,
    required this.intervals,
    this.laps,
    required this.freeRun,
    required this.verdict,
    required this.verdictSource,
    required this.indoor,
    required this.noisy,
    required this.gpsQuality,
    required this.engineVersion,
    this.lapEditsInvalid = false,
    this.session,
    this.comparisonKey,
    this.fartlek,
    this.plannedRepCount,
    this.plannedRecoveryLabel,
  });

  final String runId;

  /// Fartlek (a Laps run with the fartlek session): surges and easy laps
  /// summarised, no verdict word (D3).
  final FartlekSummary? fartlek;

  /// The run's own planned reps and recovery (null for a by-feel 4x4); a
  /// prior carries them for the D4 "Last time: …" note.
  final int? plannedRepCount;
  final String? plannedRecoveryLabel;

  /// The session this run is judged as ([effectiveSession]); null for laps,
  /// free and summary-only runs.
  final SessionSpec? session;

  /// Which runs this one compares with (plan §3.7); null when it compares
  /// with nothing (laps, free).
  final String? comparisonKey;

  /// The effective mode (override applied).
  final RunMode mode;

  /// Only for the 4x4 path.
  final RepDetection? detection;
  final IntervalMetrics? intervals;

  /// Only for a Laps run (§18.2): lap table, fastest lap, spread, HR band.
  final LapsSummary? laps;

  /// Always computed (also useful as the header of a 4x4 detail screen).
  final FreeRunSummary freeRun;

  /// Only the 4x4 path has one, if only NO VERDICT. Laps, Free and Cooper
  /// runs carry no verdict word.
  final Verdict? verdict;
  final VerdictSource? verdictSource;
  final bool indoor;
  final bool noisy;
  final double gpsQuality;
  final int engineVersion;

  /// The sidecar's lap edits no longer apply to this run's laps (e.g. an
  /// edit written against a different lap list). They were ignored; the
  /// verdict is computed from the unedited laps and the UI should say so.
  final bool lapEditsInvalid;

  bool get lapsInconsistent => detection != null && !detection!.consistent;

  /// Whether this run may serve as a prior for later verdicts: a 4x4 with a
  /// pace verdict path (not indoor, not noisy, laps consistent, no rep
  /// interrupted, at least three clean reps after any drops).
  bool get eligibleAsPrior =>
      mode == RunMode.intervals &&
      !indoor &&
      !noisy &&
      detection != null &&
      detection!.consistent &&
      intervals != null &&
      !intervals!.hasInterrupted &&
      intervals!.cleanRepCount >=
          minCleanRepsFor(comparisonKey ?? ComparisonKey.norwegian4x4, session);

  /// This run as a comparison input for later runs, or null if ineligible.
  PriorRun? asPrior(DateTime start) => intervals == null
      ? null
      : PriorRun.fromMetrics(
          runId,
          start,
          intervals!,
          eligible: eligibleAsPrior,
          comparisonKey: comparisonKey ?? ComparisonKey.norwegian4x4,
          repCount: plannedRepCount ?? intervals!.reps.length,
          recoveryLabel: plannedRecoveryLabel,
        );

  /// The sidecar with this verdict frozen (plan §4, §17 R3).
  RunSidecar freezeInto(RunSidecar sidecar) =>
      verdict == null ? sidecar : sidecar.withFrozenVerdict(verdict!);
}

/// The engine entry point. Pure and deterministic: the same inputs give the
/// same output; `now` is injectable so `computed_at` is reproducible.
class RunEngine {
  const RunEngine({this.constants = EngineConstants.defaults});

  final EngineConstants constants;

  RunAnalysis analyze(
    RunFile run, {
    RunSidecar? sidecar,
    List<PriorRun> priors = const [],
    UserProfile profile = UserProfile.none,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final trace = Trace(run.samples);
    final calc = MetricsCalculator(constants);
    final mode = sidecar?.runTypeOverride ?? run.mode;
    final fixShare = trace.fixShare();
    final indoor = fixShare < constants.indoorFixShareBelow;
    final quality = trace.quality(
      maxGapMs: constants.qualityMaxGapMs,
      maxAccuracyM: constants.qualityMaxAccuracyM,
    );
    final noisy = !indoor && quality < constants.noisyQualityBelow;
    final freeRun = calc.freeRun(run, trace);
    final session = effectiveSession(run, mode);
    final key = comparisonKeyOf(session, mode);

    // Exhaustive (W7): a new mode fails to compile here instead of being
    // mislabelled as a 4x4.
    switch (mode) {
      case RunMode.free:
      case RunMode.cooper:
        // Cooper (Phase 3) gets its own result block later; until then a
        // cooper file reads as a summary-only run, never a 4x4.
        return RunAnalysis(
          runId: run.id,
          mode: mode,
          detection: null,
          intervals: null,
          freeRun: freeRun,
          verdict: null,
          verdictSource: null,
          indoor: indoor,
          noisy: noisy,
          gpsQuality: quality,
          engineVersion: engineVersion,
          session: session,
          comparisonKey: key,
        );
      case RunMode.laps:
        final lapsSummary = calc.laps(run, trace, profile);
        return RunAnalysis(
          runId: run.id,
          mode: mode,
          detection: null,
          intervals: null,
          laps: lapsSummary,
          fartlek: key == ComparisonKey.fartlek
              ? FartlekSummary.of(lapsSummary)
              : null,
          freeRun: freeRun,
          verdict: null,
          verdictSource: null,
          indoor: indoor,
          noisy: noisy,
          gpsQuality: quality,
          engineVersion: engineVersion,
          session: session,
          comparisonKey: key,
        );
      case RunMode.intervals:
        break;
    }
    // The Norwegian 4x4 key keeps the Phase 2 detector, windows, trimming
    // and speed-stream fallback unchanged (migration golden); every other
    // session goes through the step detector (Phase 3 §3.7).
    final isFourByFour = key == ComparisonKey.norwegian4x4;
    final spec = session!;
    final planned = run.mode == RunMode.intervals ? run.session : null;

    // Edit base: recorded laps (pause laps dropped, renumbered), or laps
    // derived from the speed stream when too few were recorded. Fix-laps
    // edits index this list. Invalid edits never brick a run: they are
    // ignored and flagged.
    final detector = RepDetector(constants);
    final editable = RepDetector.editableLaps(run.laps);
    // The speed-stream fallback stays 4x4-only; any other session without
    // laps gets no verdict.
    final fromSpeed = isFourByFour && RepDetector.needsSpeedFallback(editable);
    final base = fromSpeed ? detector.deriveLapsFromSpeed(trace) : editable;
    final edits = sidecar?.lapEdits ?? const <LapEdit>[];
    EditedLaps edited;
    var lapEditsInvalid = false;
    try {
      edited = applyLapEditsWithMarks(base, edits, trace);
    } on LapEditException {
      edited = EditedLaps(laps: base, kept: const {}, dropped: const {});
      lapEditsInvalid = true;
    }
    final detection = isFourByFour
        ? detector.detect(
            edited.laps,
            run.preset,
            fromSpeed: fromSpeed,
            pauses: run.pauses,
            accepted: edited.accepted,
            dropped: edited.dropped,
          )
        : SessionDetector(constants).detect(
            edited.laps,
            spec,
            pauses: run.pauses,
            accepted: edited.accepted,
            dropped: edited.dropped,
          );
    final kind = isFourByFour
        ? IntervalMetricKind.trimmedPace
        : metricKindOf(spec);
    final metrics = isFourByFour
        ? calc.intervals(run, detection, trace, profile)
        : calc.intervals(
            run,
            detection,
            trace,
            profile,
            kind: kind,
            nominalRepMetres: kind == IntervalMetricKind.repTime
                ? spec.workSteps.first.value
                : null,
            // Short reps: HR lags a 30 s effort, so no zone (§3.7).
            zone:
                kind == IntervalMetricKind.untrimmedPace ||
                    spec.hrBandLow == null
                ? null
                : (spec.hrBandLow!, spec.hrBandHigh!),
          );

    final frozen = sidecar?.frozenVerdict;
    final inputsKey = Verdict.inputsKeyFor(edits, sidecar?.runTypeOverride);
    final Verdict verdict;
    final VerdictSource source;
    if (frozen != null &&
        frozen.engineVersion == engineVersion &&
        frozen.inputsKey == inputsKey) {
      verdict = frozen;
      source = VerdictSource.frozen;
    } else {
      verdict = VerdictBuilder(constants).build(
        run: run,
        detection: detection,
        metrics: metrics,
        gates: VerdictGates(indoor: indoor, noisy: noisy, gpsQuality: quality),
        priors: priors,
        now: at,
        inputsKey: inputsKey,
        comparisonKey: key!,
        templateDefault: spec,
        session: planned,
        minCleanReps: minCleanRepsFor(key, spec),
      );
      source = VerdictSource.computed;
    }

    return RunAnalysis(
      runId: run.id,
      mode: mode,
      detection: detection,
      intervals: metrics,
      freeRun: freeRun,
      verdict: verdict,
      verdictSource: source,
      indoor: indoor,
      noisy: noisy,
      gpsQuality: quality,
      engineVersion: engineVersion,
      session: session,
      comparisonKey: key,
      lapEditsInvalid: lapEditsInvalid,
      plannedRepCount: planned?.repCount,
      plannedRecoveryLabel: planned == null
          ? null
          : VerdictBuilder.recoveryLabelOf(planned),
    );
  }
}
