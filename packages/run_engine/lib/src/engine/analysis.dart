import '../engine_version.dart';
import '../model/run_file.dart';
import '../model/session_spec.dart';
import '../model/sidecar.dart';
import '../model/verdict.dart';
import '../run_mode.dart';
import '../weather/heat_model.dart';
import '../weather/weather.dart';
import 'format.dart';
import 'constants.dart';
import 'event_names.dart';
import 'fix_laps.dart';
import 'goal.dart';
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
/// (a fartlek groups as `fartlek`). A parkrun with a course ([courseId],
/// K1) races only that course: `parkrun:<courseId>`.
String? comparisonKeyOf(
  SessionSpec? session,
  RunMode mode, {
  String? courseId,
}) => switch (mode) {
  RunMode.free => null,
  RunMode.laps =>
    session?.templateId == SessionSpec.fartlekId ? ComparisonKey.fartlek : null,
  RunMode.intervals =>
    session?.templateId == SessionSpec.parkrunId
        ? ComparisonKey.parkrunOf(courseId: courseId)
        : session?.comparisonKey,
  RunMode.cooper => session?.comparisonKey,
};

/// The line under a verdict when the run has weather (v1 plan §18.5):
/// the adjusted headline in the verdict's own unit, with the conditions.
String? heatLineFor(WeatherRecord? w, IntervalMetrics? m, Units units) {
  final heat = w?.heat;
  if (heat == null) return null;
  final conditions =
      '${heat.tempC.round()} °C, dew point ${heat.dewPointC.round()}';
  if (heat.tooHot) return 'Too hot to compare ($conditions).';
  final pace = m?.avgWorkPaceSecPerKm;
  if (!heat.adjusts || pace == null) return null;
  final adjusted = heat.pace(pace)!;
  final metres = m!.kind == IntervalMetricKind.repTime
      ? m.nominalRepMetres
      : null;
  final value = metres == null
      ? PaceFormat.pace(adjusted, units)
      : PaceFormat.mmss(adjusted * metres / 1000);
  return 'Heat-adjusted estimate: $value ($conditions).';
}

/// A parkrun recorded without its lap boundaries (Start pressed at the
/// line, no warm-up LAP; or an imported file): the 5 km from the start and,
/// when the runner kept going, the rest as a cool-down lap. Null when the
/// trace never reached the distance (no verdict, as before).
List<Lap>? parkrunLapsFromTrace(Trace trace, int metres) {
  final samples = trace.samples;
  if (samples.isEmpty || samples.last.distM < metres) return null;
  final d0 = samples.first.distM;
  var finishMs = samples.last.tMs;
  for (var i = 1; i < samples.length; i++) {
    final a = samples[i - 1], b = samples[i];
    if (b.distM - d0 >= metres) {
      final f = b.distM == a.distM
          ? 1.0
          : (d0 + metres - a.distM) / (b.distM - a.distM);
      finishMs = (a.tMs + (b.tMs - a.tMs) * f).round();
      break;
    }
  }
  final t0 = samples.first.tMs;
  return [
    Lap(
      index: 0,
      t0Ms: t0,
      t1Ms: finishMs,
      d0M: d0,
      d1M: d0 + metres,
      kind: LapKind.auto,
    ),
    if (samples.last.tMs - finishMs >= 1000)
      Lap(
        index: 1,
        t0Ms: finishMs,
        t1Ms: samples.last.tMs,
        d0M: d0 + metres,
        d1M: samples.last.distM,
        kind: LapKind.auto,
      ),
  ];
}

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
    this.officialTime = false,
    this.weather,
    this.heatLine,
    this.goal,
  });

  /// A GOAL run's locked-in result (Phase 4 plan §G); null otherwise. Goal
  /// runs carry no verdict word.
  final GoalResult? goal;

  /// The sidecar's weather (W1): pending, ok, failed or skipped; null
  /// before the first fetch. Never an input to the verdict (plan §18.5:
  /// computed and frozen without weather).
  final WeatherRecord? weather;

  /// "Heat-adjusted estimate: 4:41/km (28 °C, dew point 21)." shown under the
  /// verdict; "Too hot to compare …" above the table; null without weather
  /// or when the heat did not slow anything.
  final String? heatLine;

  HeatAdjustment? get heat => weather?.heat;

  /// The heat-adjusted twin of the headline work pace (and, through [heat],
  /// of any per-rep pace); null without usable weather.
  double? get heatAdjustedWorkPaceSecPerKm {
    final p = intervals?.avgWorkPaceSecPerKm;
    return p == null ? null : heat?.pace(p);
  }

  final String runId;

  /// Fartlek (a Laps run with the fartlek session): surges and easy laps
  /// summarised, no verdict word (D3).
  final FartlekSummary? fartlek;

  /// The run's own planned reps and recovery (null for a by-feel 4x4); a
  /// prior carries them for the D4 "Last time: …" note.
  final int? plannedRepCount;
  final String? plannedRecoveryLabel;

  /// K1: the headline is the runner's official time (plausible and set in
  /// the sidecar), not the GPS finish.
  final bool officialTime;

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
          officialTime: officialTime,
        );

  /// The sidecar with this verdict frozen (plan §4, §17 R3).
  RunSidecar freezeInto(RunSidecar sidecar) =>
      verdict == null ? sidecar : sidecar.withFrozenVerdict(verdict!);
}

/// The engine entry point. Pure and deterministic: the same inputs give the
/// same output; `now` is injectable so `computed_at` is reproducible.
class RunEngine {
  const RunEngine({
    this.constants = EngineConstants.defaults,
    this.names = EventNames.generic,
  });

  final EngineConstants constants;

  /// Flavour event names for verdict copy (K1); the app injects them.
  final EventNames names;

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
    final parkrunInfo = sidecar?.parkrun;
    final key = comparisonKeyOf(session, mode, courseId: parkrunInfo?.courseId);
    final weather = WeatherRecord.fromJson(sidecar?.weather);

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
          weather: weather,
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
          weather: weather,
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
    // A GOAL run (§G): the goal result, no detector, no verdict word.
    if (spec.isGoal) {
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
        weather: weather,
        session: session,
        comparisonKey: key,
        goal: GoalResult.of(run, spec),
      );
    }
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
    // K1: a parkrun with no lap boundary is still one 5 km from the start.
    final isParkrun = spec.templateId == SessionSpec.parkrunId;
    final parkrunLaps = isParkrun && editable.length < 2
        ? parkrunLapsFromTrace(trace, spec.workSteps.first.value)
        : null;
    final base = fromSpeed
        ? detector.deriveLapsFromSpeed(trace)
        : parkrunLaps ?? editable;
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

    // K1: the runner's official time replaces the GPS finish as the headline
    // (the rep's own GPS numbers stay for the detail table).
    // Ignored when implausible against the GPS finish (a typo must never
    // become a PB), whoever wrote the sidecar.
    final official = isParkrun ? parkrunInfo?.officialTimeSeconds : null;
    final gpsFinish = metrics.avgRepSeconds;
    final headline =
        official != null &&
            gpsFinish != null &&
            ParkrunInfo.plausibleOfficial(official, gpsFinish)
        ? metrics.withHeadlinePace(official * 1000 / metrics.nominalRepMetres!)
        : metrics;
    final officialTime = !identical(headline, metrics);

    final frozen = sidecar?.frozenVerdict;
    final inputsKey =
        sidecar?.inputsKey ?? Verdict.inputsKeyFor(const [], null);
    final Verdict verdict;
    final VerdictSource source;
    if (frozen != null &&
        frozen.engineVersion == engineVersion &&
        frozen.inputsKey == inputsKey) {
      verdict = frozen;
      source = VerdictSource.frozen;
    } else {
      verdict = VerdictBuilder(constants, names: names).build(
        run: run,
        detection: detection,
        metrics: headline,
        gates: VerdictGates(indoor: indoor, noisy: noisy, gpsQuality: quality),
        priors: priors,
        now: at,
        inputsKey: inputsKey,
        comparisonKey: key!,
        templateDefault: spec,
        session: planned,
        minCleanReps: minCleanRepsFor(key, spec),
        officialTime: officialTime,
      );
      source = VerdictSource.computed;
    }

    return RunAnalysis(
      runId: run.id,
      mode: mode,
      detection: detection,
      intervals: headline,
      freeRun: freeRun,
      verdict: verdict,
      verdictSource: source,
      indoor: indoor,
      noisy: noisy,
      gpsQuality: quality,
      engineVersion: engineVersion,
      weather: weather,
      heatLine: heatLineFor(weather, headline, run.units),
      session: session,
      comparisonKey: key,
      lapEditsInvalid: lapEditsInvalid,
      plannedRepCount: planned?.repCount,
      plannedRecoveryLabel: planned == null
          ? null
          : VerdictBuilder.recoveryLabelOf(planned),
      officialTime: officialTime,
    );
  }
}
