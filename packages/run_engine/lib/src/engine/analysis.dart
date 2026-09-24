import '../engine_version.dart';
import '../model/run_file.dart';
import '../model/sidecar.dart';
import '../model/verdict.dart';
import '../run_mode.dart';
import 'constants.dart';
import 'fix_laps.dart';
import 'metrics.dart';
import 'rep_detector.dart';
import 'trace.dart';
import 'verdict_builder.dart';

/// Where the verdict on a [RunAnalysis] came from.
enum VerdictSource {
  /// Restored from the sidecar: same engine version, nothing recomputed.
  frozen,

  /// Computed now (first analysis, after fix-laps/override, or a version bump).
  computed,
}

/// Engine output (plan §5): reps, recovery spans, metrics, verdict, flags.
class RunAnalysis {
  const RunAnalysis({
    required this.runId,
    required this.mode,
    required this.detection,
    required this.fourByFour,
    required this.freeRun,
    required this.verdict,
    required this.verdictSource,
    required this.indoor,
    required this.noisy,
    required this.gpsQuality,
    required this.engineVersion,
    this.lapEditsInvalid = false,
  });

  final String runId;

  /// The effective mode (override applied).
  final RunMode mode;

  /// Null for free runs.
  final RepDetection? detection;
  final FourByFourMetrics? fourByFour;

  /// Always computed (also useful as the header of a 4x4 detail screen).
  final FreeRunSummary freeRun;

  /// Null for free runs; a 4x4 always has one, if only NO VERDICT.
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
      mode == RunMode.fourByFour &&
      !indoor &&
      !noisy &&
      detection != null &&
      detection!.consistent &&
      fourByFour != null &&
      !fourByFour!.hasInterrupted &&
      fourByFour!.cleanRepCount >= EngineConstants.minReps;

  /// This run as a comparison input for later runs, or null if ineligible.
  PriorRun? asPrior(DateTime start) => fourByFour == null
      ? null
      : PriorRun.fromMetrics(
          runId,
          start,
          fourByFour!,
          eligible: eligibleAsPrior,
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

    if (mode == RunMode.free) {
      return RunAnalysis(
        runId: run.id,
        mode: mode,
        detection: null,
        fourByFour: null,
        freeRun: freeRun,
        verdict: null,
        verdictSource: null,
        indoor: indoor,
        noisy: noisy,
        gpsQuality: quality,
        engineVersion: engineVersion,
      );
    }

    // Edit base: recorded laps (pause laps dropped, renumbered), or laps
    // derived from the speed stream when too few were recorded. Fix-laps
    // edits index this list. Invalid edits never brick a run: they are
    // ignored and flagged.
    final detector = RepDetector(constants);
    final editable = RepDetector.editableLaps(run.laps);
    final fromSpeed = RepDetector.needsSpeedFallback(editable);
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
    final detection = detector.detect(
      edited.laps,
      run.preset,
      fromSpeed: fromSpeed,
      pauses: run.pauses,
      accepted: edited.accepted,
      dropped: edited.dropped,
    );
    final metrics = calc.fourByFour(run, detection, trace, profile);

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
      );
      source = VerdictSource.computed;
    }

    return RunAnalysis(
      runId: run.id,
      mode: mode,
      detection: detection,
      fourByFour: metrics,
      freeRun: freeRun,
      verdict: verdict,
      verdictSource: source,
      indoor: indoor,
      noisy: noisy,
      gpsQuality: quality,
      engineVersion: engineVersion,
      lapEditsInvalid: lapEditsInvalid,
    );
  }
}
