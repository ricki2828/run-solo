import '../model/run_file.dart';
import 'constants.dart';
import 'rep_detector.dart';
import 'trace.dart';

/// Why a rep is excluded from bests, medians and the verdict (plan §5).
enum InterruptReason {
  /// A sample gap longer than 10 s inside the rep.
  gpsDropped,

  /// A pause longer than 20 s inside the rep.
  paused,

  /// A kill→resume `gap` span inside the rep.
  recordingStopped,
}

/// What the user told the engine about themselves (plan §16 decision 3).
class UserProfile {
  const UserProfile({this.age, this.maxHr, this.observedMaxHr});

  final int? age;

  /// Explicit max HR setting; wins over everything.
  final int? maxHr;

  /// Highest 30 s HR seen across the user's history (kept in settings by the
  /// store from [FourByFourMetrics.observedMaxHrThisRun]). Wins over 220−age
  /// when higher. Never per run: every run must share one denominator so
  /// "same effort: 91% both runs" is comparable.
  final double? observedMaxHr;

  static const UserProfile none = UserProfile();
}

class RepMetrics {
  const RepMetrics({
    required this.number,
    required this.lap,
    required this.trimmedT0Ms,
    required this.trimmedT1Ms,
    this.pausedMs = 0,
    required this.distanceM,
    required this.paceSecPerKm,
    required this.interrupted,
    this.interruptReason,
    this.dropped = false,
    this.outsideWindow = false,
    this.meanHr,
    this.peakHr,
    this.zoneSeconds,
    this.hrRecoveryDrop,
    this.metresPerBeat,
  });

  final int number;
  final Lap lap;
  final int trimmedT0Ms;
  final int trimmedT1Ms;

  /// Paused time inside the trimmed window; excluded from the pace.
  final int pausedMs;

  /// Distance over the trimmed window.
  final double distanceM;

  /// Δdistance ÷ Δtime over the trimmed window, s/km. Null when the trimmed
  /// window is empty or no distance was covered.
  final double? paceSecPerKm;
  final bool interrupted;
  final InterruptReason? interruptReason;

  /// Excluded by a fix-laps `drop` (shown greyed like an interrupted rep).
  final bool dropped;

  /// Accepted by a fix-laps `keep` although outside the preset window.
  final bool outsideWindow;
  final double? meanHr;
  final int? peakHr;

  /// Seconds of the whole rep with HR in the 85–95% zone.
  final double? zoneSeconds;

  /// HR at the rep end minus HR 60 s later (bpm).
  final double? hrRecoveryDrop;

  /// Metres per heartbeat over the trimmed window ("faster at the same HR").
  final double? metresPerBeat;

  /// Moving seconds in the trimmed window (paused time excluded).
  double get trimmedSeconds => (trimmedT1Ms - trimmedT0Ms - pausedMs) / 1000;
  bool get clean => !interrupted && !dropped && paceSecPerKm != null;
}

class RecoveryMetrics {
  const RecoveryMetrics({
    required this.number,
    required this.lap,
    required this.paceSecPerKm,
    this.meanHr,
    this.dropped = false,
  });

  final int number;
  final Lap lap;
  final double? paceSecPerKm;
  final double? meanHr;

  /// Excluded by a fix-laps `drop`.
  final bool dropped;
}

/// 4x4 metrics (plan §5). Aggregates use clean reps only.
class FourByFourMetrics {
  const FourByFourMetrics({
    required this.reps,
    required this.recoveries,
    required this.avgWorkPaceSecPerKm,
    required this.repSpreadSecPerKm,
    required this.fadeSecPerKm,
    required this.recoveryPaceSecPerKm,
    required this.workRecoveryRatio,
    required this.workDistanceM,
    required this.workSeconds,
    required this.hrPresent,
    this.maxHrUsed,
    this.timeInZoneSeconds,
    this.meanWorkHr,
    this.meanWorkHrFraction,
    this.metresPerBeat,
    this.observedMaxHrThisRun,
  });

  final List<RepMetrics> reps;
  final List<RecoveryMetrics> recoveries;

  /// Headline: total trimmed work distance ÷ total trimmed work time.
  final double? avgWorkPaceSecPerKm;

  /// Slowest minus fastest clean rep, s/km.
  final double? repSpreadSecPerKm;

  /// Last clean rep minus first clean rep, s/km (positive = slowed).
  final double? fadeSecPerKm;
  final double? recoveryPaceSecPerKm;

  /// Work speed ÷ recovery speed.
  final double? workRecoveryRatio;
  final double workDistanceM;

  /// Whole-rep work seconds over all reps ("of 16:00").
  final double workSeconds;
  final bool hrPresent;
  final double? maxHrUsed;
  final double? timeInZoneSeconds;
  final double? meanWorkHr;

  /// meanWorkHr ÷ maxHrUsed, e.g. 0.91.
  final double? meanWorkHrFraction;
  final double? metresPerBeat;

  /// Highest 30 s mean HR in this run; the store folds it into
  /// `UserProfile.observedMaxHr` (settings) when it exceeds the stored value.
  final double? observedMaxHrThisRun;

  int get cleanRepCount => reps.where((r) => r.clean).length;
  bool get allRepsClean => reps.isNotEmpty && cleanRepCount == reps.length;
  bool get hasInterrupted => reps.any((r) => r.interrupted);
  int get droppedRepCount => reps.where((r) => r.dropped).length;
}

/// Free run summary (plan §5): distance, moving time, avg pace, splits, HR.
class FreeRunSummary {
  const FreeRunSummary({
    required this.distanceM,
    required this.elapsedSeconds,
    required this.movingSeconds,
    required this.avgPaceSecPerKm,
    required this.splitsSecPerUnit,
    this.avgHr,
  });

  final double distanceM;
  final double elapsedSeconds;
  final double movingSeconds;
  final double? avgPaceSecPerKm;

  /// Pace per full km or mi (by file units); a trailing partial unit is
  /// dropped.
  final List<double> splitsSecPerUnit;
  final double? avgHr;
}

/// One row of the Laps run table (§18.2): recorded lap, untrimmed, with
/// paused time and any ground covered while paused taken out of the pace.
class LapRowMetrics {
  const LapRowMetrics({
    required this.number,
    required this.lap,
    required this.movingSeconds,
    required this.distanceM,
    required this.paceSecPerKm,
    required this.scored,
    this.meanHr,
  });

  /// 1-based, over non-pause laps in recorded order.
  final int number;
  final Lap lap;

  /// Lap duration minus paused time inside it.
  final double movingSeconds;

  /// Lap distance minus any distance the recorder accumulated while paused.
  final double distanceM;

  /// movingSeconds ÷ distance, s/km; null when the lap covered no ground.
  final double? paceSecPerKm;

  /// Whether the lap counts for fastest lap and spread: at least
  /// [EngineConstants.scoredLapMinSeconds] moving and
  /// [EngineConstants.scoredLapMinMetres] covered. A 4 s tail lap after the
  /// last press is listed but never "fastest".
  final bool scored;
  final double? meanHr;
}

/// Laps run post-run block (§18.2): lap table, fastest lap, lap spread against
/// the rep band, HR avg/max and time in the 85–95% band. No verdict word, no
/// trend entry. Pure description: nothing here compares to another run.
class LapsSummary {
  const LapsSummary({
    required this.laps,
    required this.fastestLapNumber,
    required this.spreadSecPerKm,
    required this.spreadWithinBand,
    required this.bandSecPerKm,
    required this.hrPresent,
    this.maxHrUsed,
    this.avgHr,
    this.maxHr,
    this.timeInBandSeconds,
    this.observedMaxHrThisRun,
  });

  final List<LapRowMetrics> laps;

  /// Number of the fastest scored lap, or null when fewer than one scored.
  final int? fastestLapNumber;

  /// Slowest minus fastest scored lap, s/km; null with fewer than two scored.
  final double? spreadSecPerKm;

  /// `spread <= rep band` (the same 10 s/km band a 4x4 uses), null when no
  /// spread.
  final bool? spreadWithinBand;
  final double bandSecPerKm;
  final bool hrPresent;

  /// The resolved max HR the band used ([MetricsCalculator.maxHrFor]).
  final double? maxHrUsed;
  final double? avgHr;
  final int? maxHr;

  /// Seconds of the whole run with HR inside the 85–95% band.
  final double? timeInBandSeconds;

  /// Highest 30 s mean HR in this run (same contract as the 4x4 field).
  final double? observedMaxHrThisRun;

  int get scoredLapCount => laps.where((l) => l.scored).length;
}

/// Computes metrics from a detection; pure.
class MetricsCalculator {
  const MetricsCalculator(this.constants);

  final EngineConstants constants;

  FourByFourMetrics fourByFour(
    RunFile run,
    RepDetection detection,
    Trace trace,
    UserProfile profile,
  ) {
    final hrPresent = run.hasHr;
    final maxHr = hrPresent ? maxHrFor(profile) : null;
    final zoneLow = maxHr == null ? null : maxHr * constants.zoneLowFraction;
    final zoneHigh = maxHr == null ? null : maxHr * constants.zoneHighFraction;

    final reps = <RepMetrics>[];
    final recoveries = <RecoveryMetrics>[];
    for (final rep in detection.reps) {
      final lap = rep.work;
      var t0 = lap.t0Ms + constants.trimStartMs;
      var t1 = lap.t1Ms - constants.trimEndMs;
      if (t1 <= t0) {
        // Too short to trim: fall back to the whole lap rather than nothing.
        t0 = lap.t0Ms;
        t1 = lap.t1Ms;
      }
      final pausedMs = _pausedWithin(run, t0, t1);
      // Paused time AND any ground covered while paused come out together,
      // so walking across a road during a pause cannot make the rep faster.
      final d =
          trace.distAt(t1) -
          trace.distAt(t0) -
          _pausedDistWithin(run, trace, t0, t1);
      final seconds = (t1 - t0 - pausedMs) / 1000;
      final pace = d <= 0 || seconds <= 0 ? null : seconds / d * 1000;
      final reason = _interruption(run, trace, lap);
      final meanHr = hrPresent ? trace.meanHr(lap.t0Ms, lap.t1Ms) : null;
      final zone = zoneLow == null
          ? null
          : trace.secondsInZone(lap.t0Ms, lap.t1Ms, zoneLow, zoneHigh!);
      double? drop;
      if (hrPresent) {
        final atEnd = trace.hrNear(lap.t1Ms);
        final later = trace.hrNear(lap.t1Ms + 60000);
        if (atEnd != null && later != null) drop = (atEnd - later).toDouble();
      }
      final trimmedMeanHr = hrPresent ? trace.meanHr(t0, t1) : null;
      final mpb = trimmedMeanHr == null || trimmedMeanHr <= 0 || d <= 0
          ? null
          : d / (trimmedMeanHr * seconds / 60);
      reps.add(
        RepMetrics(
          number: rep.number,
          lap: lap,
          trimmedT0Ms: t0,
          trimmedT1Ms: t1,
          pausedMs: pausedMs,
          distanceM: d < 0 ? 0 : d,
          paceSecPerKm: pace,
          interrupted: reason != null,
          interruptReason: reason,
          dropped: rep.workDropped,
          outsideWindow: rep.workOutsideWindow,
          meanHr: meanHr,
          peakHr: hrPresent ? trace.peakHr(lap.t0Ms, lap.t1Ms) : null,
          zoneSeconds: zone,
          hrRecoveryDrop: drop,
          metresPerBeat: mpb,
        ),
      );
      final rec = rep.recovery;
      if (rec != null) {
        var r0 = rec.t0Ms + constants.trimStartMs;
        var r1 = rec.t1Ms - constants.trimEndMs;
        if (r1 <= r0) {
          r0 = rec.t0Ms;
          r1 = rec.t1Ms;
        }
        final rd =
            trace.distAt(r1) -
            trace.distAt(r0) -
            _pausedDistWithin(run, trace, r0, r1);
        final rs = (r1 - r0 - _pausedWithin(run, r0, r1)) / 1000;
        recoveries.add(
          RecoveryMetrics(
            number: rep.number,
            lap: rec,
            paceSecPerKm: rd <= 0 || rs <= 0 ? null : rs / rd * 1000,
            meanHr: hrPresent ? trace.meanHr(rec.t0Ms, rec.t1Ms) : null,
            dropped: rep.recoveryDropped,
          ),
        );
      }
    }

    final clean = reps.where((r) => r.clean).toList();
    double? avgPace;
    double? spread;
    double? fade;
    var workDistance = 0.0;
    if (clean.isNotEmpty) {
      var dist = 0.0;
      var secs = 0.0;
      for (final r in clean) {
        dist += r.distanceM;
        secs += r.trimmedSeconds;
      }
      avgPace = secs / dist * 1000;
      final paces = clean.map((r) => r.paceSecPerKm!).toList();
      spread =
          paces.reduce((a, b) => a > b ? a : b) -
          paces.reduce((a, b) => a < b ? a : b);
      // Fade compares first and last full reps: a kept rep under half the
      // expected length (a bail-out) would only measure how short it was.
      final expectedWorkMs =
          (run.preset?.workSeconds ?? EngineConstants.byFeelWorkMinMs ~/ 1000) *
          1000;
      final full = clean
          .where((r) => r.lap.durationMs >= expectedWorkMs * 0.5)
          .toList();
      fade = full.length >= 2
          ? full.last.paceSecPerKm! - full.first.paceSecPerKm!
          : null;
    }
    for (final r in reps) {
      workDistance += r.lap.distanceM;
    }
    final workSeconds = reps.fold<double>(
      0,
      (sum, r) => sum + r.lap.durationMs / 1000,
    );

    double? recoveryPace;
    final recWithPace = recoveries.where(
      (r) => r.paceSecPerKm != null && !r.dropped,
    );
    if (recWithPace.isNotEmpty) {
      var dist = 0.0;
      var secs = 0.0;
      for (final r in recWithPace) {
        var a = r.lap.t0Ms + constants.trimStartMs;
        var b = r.lap.t1Ms - constants.trimEndMs;
        if (b <= a) {
          a = r.lap.t0Ms;
          b = r.lap.t1Ms;
        }
        final seconds = (b - a - _pausedWithin(run, a, b)) / 1000;
        secs += seconds;
        dist += seconds / r.paceSecPerKm! * 1000;
      }
      recoveryPace = secs / dist * 1000;
    }
    final ratio = avgPace == null || recoveryPace == null
        ? null
        : recoveryPace / avgPace;

    double? tiz;
    double? meanWorkHr;
    double? mpb;
    if (hrPresent && reps.isNotEmpty) {
      tiz = maxHr == null
          ? null
          : reps.fold<double>(0, (sum, r) => sum + (r.zoneSeconds ?? 0));
      var beats = 0.0;
      var secs = 0.0;
      var mpbDist = 0.0;
      var mpbBeats = 0.0;
      for (final r in reps) {
        if (r.meanHr != null) {
          final s = r.lap.durationMs / 1000;
          beats += r.meanHr! * s;
          secs += s;
        }
        if (r.clean && r.metresPerBeat != null) {
          mpbDist += r.distanceM;
          mpbBeats += r.distanceM / r.metresPerBeat!;
        }
      }
      meanWorkHr = secs == 0 ? null : beats / secs;
      mpb = mpbBeats == 0 ? null : mpbDist / mpbBeats;
    }

    return FourByFourMetrics(
      reps: reps,
      recoveries: recoveries,
      avgWorkPaceSecPerKm: avgPace,
      repSpreadSecPerKm: spread,
      fadeSecPerKm: fade,
      recoveryPaceSecPerKm: recoveryPace,
      workRecoveryRatio: ratio,
      workDistanceM: workDistance,
      workSeconds: workSeconds,
      hrPresent: hrPresent,
      maxHrUsed: maxHr,
      timeInZoneSeconds: tiz,
      meanWorkHr: meanWorkHr,
      meanWorkHrFraction: meanWorkHr == null || maxHr == null
          ? null
          : meanWorkHr / maxHr,
      metresPerBeat: mpb,
      observedMaxHrThisRun: hrPresent ? trace.highest30sHr() : null,
    );
  }

  /// Laps-run table and aggregates (§18.2) from the recorded laps (pause
  /// laps dropped and renumbered, like the 4x4 edit base). The run's laps
  /// are used as recorded: fix-laps edits only apply to the 4x4 path.
  LapsSummary laps(RunFile run, Trace trace, UserProfile profile) {
    final hrPresent = run.hasHr;
    final maxHr = hrPresent ? maxHrFor(profile) : null;
    final rows = <LapRowMetrics>[];
    var n = 0;
    for (final lap in run.laps) {
      if (lap.kind == LapKind.pause) continue;
      n++;
      final pausedMs = _pausedWithin(run, lap.t0Ms, lap.t1Ms);
      final d =
          trace.distAt(lap.t1Ms) -
          trace.distAt(lap.t0Ms) -
          _pausedDistWithin(run, trace, lap.t0Ms, lap.t1Ms);
      final seconds = (lap.durationMs - pausedMs) / 1000;
      final dist = d < 0 ? 0.0 : d;
      rows.add(
        LapRowMetrics(
          number: n,
          lap: lap,
          movingSeconds: seconds,
          distanceM: dist,
          paceSecPerKm: dist <= 0 || seconds <= 0
              ? null
              : seconds / dist * 1000,
          scored:
              seconds >= constants.scoredLapMinSeconds &&
              dist >= constants.scoredLapMinMetres,
          meanHr: hrPresent ? trace.meanHr(lap.t0Ms, lap.t1Ms) : null,
        ),
      );
    }
    final scored = rows.where((l) => l.scored && l.paceSecPerKm != null);
    LapRowMetrics? fastest;
    LapRowMetrics? slowest;
    for (final l in scored) {
      if (fastest == null || l.paceSecPerKm! < fastest.paceSecPerKm!) {
        fastest = l;
      }
      if (slowest == null || l.paceSecPerKm! > slowest.paceSecPerKm!) {
        slowest = l;
      }
    }
    final spread = scored.length < 2
        ? null
        : slowest!.paceSecPerKm! - fastest!.paceSecPerKm!;
    return LapsSummary(
      laps: rows,
      fastestLapNumber: fastest?.number,
      spreadSecPerKm: spread,
      spreadWithinBand: spread == null
          ? null
          : spread <= constants.repBandSecPerKm,
      bandSecPerKm: constants.repBandSecPerKm,
      hrPresent: hrPresent,
      maxHrUsed: maxHr,
      // Whole-run HR with paused spans excluded, like the lap rows.
      avgHr: hrPresent
          ? trace.meanHrExcluding(trace.startMs, trace.endMs, run.pauses)
          : null,
      maxHr: hrPresent
          ? trace.peakHrExcluding(trace.startMs, trace.endMs + 1, run.pauses)
          : null,
      timeInBandSeconds: maxHr == null
          ? null
          : trace.secondsInZone(
              trace.startMs,
              trace.endMs,
              maxHr * constants.zoneLowFraction,
              maxHr * constants.zoneHighFraction,
            ),
      observedMaxHrThisRun: hrPresent ? trace.highest30sHr() : null,
    );
  }

  FreeRunSummary freeRun(RunFile run, Trace trace) {
    final elapsed = run.elapsedMs / 1000;
    final paused = run.pauses.fold<int>(0, (s, p) => s + p.durationMs) / 1000;
    final moving = (elapsed - paused).clamp(0, elapsed).toDouble();
    final dist = run.distanceM;
    final unitM = run.units == Units.mi ? 1609.344 : 1000.0;
    final splits = <double>[];
    var mark = unitM;
    var prevT = trace.startMs;
    // Walk samples to find the time each full unit is crossed.
    for (var i = 1; i < trace.samples.length && mark <= dist; i++) {
      final a = trace.samples[i - 1];
      final b = trace.samples[i];
      while (mark <= dist && b.distM >= mark) {
        final f = b.distM == a.distM
            ? 1.0
            : (mark - a.distM) / (b.distM - a.distM);
        final tAt = a.tMs + ((b.tMs - a.tMs) * f).round();
        splits.add((tAt - prevT) / 1000);
        prevT = tAt;
        mark += unitM;
      }
    }
    return FreeRunSummary(
      distanceM: dist,
      elapsedSeconds: elapsed,
      movingSeconds: moving,
      avgPaceSecPerKm: dist <= 0 || moving <= 0 ? null : moving / dist * 1000,
      splitsSecPerUnit: splits,
      avgHr: run.hasHr ? trace.meanHr(trace.startMs, trace.endMs) : null,
    );
  }

  InterruptReason? _interruption(RunFile run, Trace trace, Lap lap) {
    for (final gap in run.gaps) {
      if (gap.overlaps(lap.t0Ms, lap.t1Ms)) {
        return InterruptReason.recordingStopped;
      }
    }
    for (final pause in run.pauses) {
      if (pause.overlaps(lap.t0Ms, lap.t1Ms) &&
          pause.durationMs > constants.pauseInterruptMs) {
        return InterruptReason.paused;
      }
    }
    // A genuine pause writes no samples; its span is not a GPS gap.
    if (trace.maxSampleGapMs(lap.t0Ms, lap.t1Ms, excluding: run.pauses) >
        constants.sampleGapInterruptMs) {
      return InterruptReason.gpsDropped;
    }
    return null;
  }

  /// Distance the recorder accumulated on samples written *inside* pause
  /// spans overlapping `[aMs, bMs]`: zero when the writer froze `dist` or
  /// wrote no samples while paused (a silent pause must not have the
  /// lagged pre-pause running interpolated into it and taken away).
  static double _pausedDistWithin(RunFile run, Trace trace, int aMs, int bMs) {
    var total = 0.0;
    for (final p in run.pauses) {
      final lo = p.t0Ms > aMs ? p.t0Ms : aMs;
      final hi = p.t1Ms < bMs ? p.t1Ms : bMs;
      if (hi <= lo) continue;
      Sample? first;
      Sample? last;
      for (final s in trace.between(lo, hi)) {
        first ??= s;
        last = s;
      }
      if (first != null && last != null) total += last.distM - first.distM;
    }
    return total < 0 ? 0 : total;
  }

  static int _pausedWithin(RunFile run, int aMs, int bMs) {
    var total = 0;
    for (final p in run.pauses) {
      final lo = p.t0Ms > aMs ? p.t0Ms : aMs;
      final hi = p.t1Ms < bMs ? p.t1Ms : bMs;
      if (hi > lo) total += hi - lo;
    }
    return total;
  }

  /// The one max-HR resolver (plan D3, §18.11 N1). **Observed wins**:
  /// `max(typed ?? (age != null ? 220 − age : 190), observed30s)`. A strap's
  /// sustained 30 s HR above any lower value, typed included, is evidence
  /// that value is too low. Never null, so zones always resolve. Never this
  /// run's own peak: the store folds `observedMaxHrThisRun` into
  /// `UserProfile.observedMaxHr` (through the artefact guard in
  /// `ObservedMaxHr`) after the run, so every analysis shares one denominator.
  static double maxHrFor(UserProfile profile) {
    final base =
        profile.maxHr?.toDouble() ??
        (profile.age == null ? fallbackMaxHr : (220 - profile.age!).toDouble());
    final observed = profile.observedMaxHr;
    return observed != null && observed > base ? observed : base;
  }

  /// Used when nothing is typed and no age is known.
  static const double fallbackMaxHr = 190;
}
