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
  const UserProfile({this.age, this.maxHr});

  final int? age;

  /// Explicit max HR setting; wins over the age estimate.
  final int? maxHr;

  static const UserProfile none = UserProfile();
}

class RepMetrics {
  const RepMetrics({
    required this.number,
    required this.lap,
    required this.trimmedT0Ms,
    required this.trimmedT1Ms,
    required this.distanceM,
    required this.paceSecPerKm,
    required this.interrupted,
    this.interruptReason,
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

  /// Distance over the trimmed window.
  final double distanceM;

  /// Δdistance ÷ Δtime over the trimmed window, s/km. Null when the trimmed
  /// window is empty or no distance was covered.
  final double? paceSecPerKm;
  final bool interrupted;
  final InterruptReason? interruptReason;
  final double? meanHr;
  final int? peakHr;

  /// Seconds of the whole rep with HR in the 85–95% zone.
  final double? zoneSeconds;

  /// HR at the rep end minus HR 60 s later (bpm).
  final double? hrRecoveryDrop;

  /// Metres per heartbeat over the trimmed window ("faster at the same HR").
  final double? metresPerBeat;

  double get trimmedSeconds => (trimmedT1Ms - trimmedT0Ms) / 1000;
  bool get clean => !interrupted && paceSecPerKm != null;
}

class RecoveryMetrics {
  const RecoveryMetrics({
    required this.number,
    required this.lap,
    required this.paceSecPerKm,
    this.meanHr,
  });

  final int number;
  final Lap lap;
  final double? paceSecPerKm;
  final double? meanHr;
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

  int get cleanRepCount => reps.where((r) => r.clean).length;
  bool get allRepsClean => reps.isNotEmpty && cleanRepCount == reps.length;
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
    final maxHr = hrPresent ? _maxHr(profile, trace) : null;
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
      final d = trace.distAt(t1) - trace.distAt(t0);
      final seconds = (t1 - t0) / 1000;
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
          distanceM: d < 0 ? 0 : d,
          paceSecPerKm: pace,
          interrupted: reason != null,
          interruptReason: reason,
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
        final rd = trace.distAt(r1) - trace.distAt(r0);
        final rs = (r1 - r0) / 1000;
        recoveries.add(
          RecoveryMetrics(
            number: rep.number,
            lap: rec,
            paceSecPerKm: rd <= 0 || rs <= 0 ? null : rs / rd * 1000,
            meanHr: hrPresent ? trace.meanHr(rec.t0Ms, rec.t1Ms) : null,
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
      fade = paces.last - paces.first;
    }
    for (final r in reps) {
      workDistance += r.lap.distanceM;
    }
    final workSeconds = reps.fold<double>(
      0,
      (sum, r) => sum + r.lap.durationMs / 1000,
    );

    double? recoveryPace;
    final recWithPace = recoveries.where((r) => r.paceSecPerKm != null);
    if (recWithPace.isNotEmpty) {
      var dist = 0.0;
      var secs = 0.0;
      for (final r in recWithPace) {
        final s =
            ((r.lap.t1Ms - constants.trimEndMs) -
                (r.lap.t0Ms + constants.trimStartMs)) /
            1000;
        final seconds = s > 0 ? s : r.lap.durationMs / 1000;
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
      tiz = reps.fold<double>(0, (sum, r) => sum + (r.zoneSeconds ?? 0));
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
    if (trace.maxSampleGapMs(lap.t0Ms, lap.t1Ms) >
        constants.sampleGapInterruptMs) {
      return InterruptReason.gpsDropped;
    }
    return null;
  }

  /// Max HR precedence (plan §5, §16): setting → 220−age → highest 30 s
  /// observed; a paired strap showing a higher 30 s value wins over the
  /// estimate.
  double? _maxHr(UserProfile profile, Trace trace) {
    final observed = trace.highest30sHr();
    if (profile.maxHr != null) return profile.maxHr!.toDouble();
    final estimate = profile.age == null
        ? null
        : (220 - profile.age!).toDouble();
    if (estimate == null) return observed;
    if (observed != null && observed > estimate) return observed;
    return estimate;
  }
}
