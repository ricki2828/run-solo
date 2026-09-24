import '../model/run_file.dart';
import 'constants.dart';
import 'trace.dart';

/// One detected rep: the work lap and, unless it was the last rep with the
/// final recovery missing, the recovery lap that followed it.
class DetectedRep {
  const DetectedRep({required this.number, required this.work, this.recovery});

  /// 1-based, as shown in the UI ("Rep 1..4").
  final int number;
  final Lap work;
  final Lap? recovery;
}

/// Why the recorded laps do not form a 4x4 (plan §5 `lapsInconsistent`).
enum InconsistencyKind {
  /// No laps at all and the speed stream showed no work/recovery pattern.
  noPattern,

  /// Fewer or more reps than the preset (±1) or the 3–6 range allows.
  repCountOutOfRange,
}

class RepDetection {
  const RepDetection({
    required this.warmup,
    required this.reps,
    required this.cooldown,
    required this.consistent,
    this.inconsistency,
    this.inconsistencyDetail,
    this.fromSpeedStream = false,
    required this.laps,
  });

  final List<Lap> warmup;
  final List<DetectedRep> reps;
  final List<Lap> cooldown;
  final bool consistent;
  final InconsistencyKind? inconsistency;

  /// Plain-language detail for the fix-laps screen, e.g.
  /// "Rep 2 was 3:20, the preset expected 4:00."
  final String? inconsistencyDetail;

  /// Laps were derived from the speed stream because none were recorded.
  final bool fromSpeedStream;

  /// The laps the detection ran over (after edits, pause laps dropped, or
  /// derived from speed).
  final List<Lap> laps;
}

class _Window {
  const _Window(this.minMs, this.maxMs);
  final int minMs;
  final int maxMs;
  bool fits(Lap lap) => lap.durationMs >= minMs && lap.durationMs <= maxMs;
}

/// Preset-aware rep detection from laps (plan §5, §17 B5). Precedence is the
/// caller's: fix-laps edits are applied before this runs.
class RepDetector {
  const RepDetector(this.constants);

  final EngineConstants constants;

  RepDetection detect(List<Lap> recordedLaps, Preset? preset, Trace trace) {
    final laps = recordedLaps.where((l) => l.kind != LapKind.pause).toList();
    if (laps.length < 2) {
      final derived = _lapsFromSpeed(trace);
      if (derived.length < 2) {
        return RepDetection(
          warmup: laps,
          reps: const [],
          cooldown: const [],
          consistent: false,
          inconsistency: InconsistencyKind.noPattern,
          inconsistencyDetail: 'No laps and no clear fast/easy pattern.',
          fromSpeedStream: true,
          laps: derived,
        );
      }
      return _detectFromLaps(derived, preset, fromSpeed: true);
    }
    return _detectFromLaps(laps, preset, fromSpeed: false);
  }

  RepDetection _detectFromLaps(
    List<Lap> laps,
    Preset? preset, {
    required bool fromSpeed,
  }) {
    final work = preset == null
        ? const _Window(
            EngineConstants.byFeelWorkMinMs,
            EngineConstants.byFeelWorkMaxMs,
          )
        : _Window(
            preset.workSeconds * 1000 - constants.presetToleranceMs,
            preset.workSeconds * 1000 + constants.presetToleranceMs,
          );
    final recovery = preset == null
        ? const _Window(
            EngineConstants.byFeelRecoveryMinMs,
            EngineConstants.byFeelRecoveryMaxMs,
          )
        : _Window(
            preset.recoverySeconds * 1000 - constants.presetToleranceMs,
            preset.recoverySeconds * 1000 + constants.presetToleranceMs,
          );
    final minReps = preset == null
        ? EngineConstants.minReps
        : (preset.reps - 1).clamp(
            EngineConstants.minReps,
            EngineConstants.maxReps,
          );
    final maxReps = preset == null
        ? EngineConstants.maxReps
        : (preset.reps + 1).clamp(
            EngineConstants.minReps,
            EngineConstants.maxReps,
          );

    // Longest alternating work/recovery run starting at any lap; first wins ties.
    var bestStart = -1;
    var bestReps = <DetectedRep>[];
    var bestEnd = 0;
    for (var s = 0; s < laps.length; s++) {
      final reps = <DetectedRep>[];
      var i = s;
      while (i < laps.length && work.fits(laps[i])) {
        final w = laps[i];
        Lap? r;
        if (i + 1 < laps.length &&
            recovery.fits(laps[i + 1]) &&
            _speed(w) >=
                constants.workVsRecoveryMinRatio * _speed(laps[i + 1])) {
          r = laps[i + 1];
        }
        // Work must also be faster than the recovery before it (when present).
        if (reps.isNotEmpty) {
          final prevRecovery = reps.last.recovery;
          if (prevRecovery == null ||
              _speed(w) <
                  constants.workVsRecoveryMinRatio * _speed(prevRecovery)) {
            break;
          }
        }
        reps.add(DetectedRep(number: reps.length + 1, work: w, recovery: r));
        if (r == null) {
          i += 1;
          break;
        }
        i += 2;
      }
      if (reps.length > bestReps.length) {
        bestStart = s;
        bestReps = reps;
        bestEnd = i;
      }
    }

    if (bestReps.isEmpty) {
      return RepDetection(
        warmup: laps,
        reps: const [],
        cooldown: const [],
        consistent: false,
        inconsistency: InconsistencyKind.noPattern,
        inconsistencyDetail: preset == null
            ? 'No lap matches a 4x4 work and recovery pattern.'
            : 'No lap matches the preset ${_mmss(preset.workSeconds * 1000)} '
                  'work and ${_mmss(preset.recoverySeconds * 1000)} recovery.',
        fromSpeedStream: fromSpeed,
        laps: laps,
      );
    }

    final warmup = laps.sublist(0, bestStart);
    final cooldown = laps.sublist(bestEnd);
    final count = bestReps.length;
    final inRange = count >= minReps && count <= maxReps;
    String? detail;
    if (!inRange) {
      detail = _explain(laps, bestReps, preset, work, recovery, count);
    }
    return RepDetection(
      warmup: warmup,
      reps: bestReps,
      cooldown: cooldown,
      consistent: inRange,
      inconsistency: inRange ? null : InconsistencyKind.repCountOutOfRange,
      inconsistencyDetail: detail,
      fromSpeedStream: fromSpeed,
      laps: laps,
    );
  }

  /// Walks the earliest candidate sequence (from the first lap that fits the
  /// work window) and names the lap that broke it, so the fix-laps screen
  /// can say "Rep 2 was 3:20, the preset expected 4:00."
  String _explain(
    List<Lap> laps,
    List<DetectedRep> reps,
    Preset? preset,
    _Window work,
    _Window recovery,
    int count,
  ) {
    var i = laps.indexWhere(work.fits);
    if (i < 0) i = 0;
    var repNo = 0;
    var expectWork = true;
    while (i < laps.length) {
      final lap = laps[i];
      if (expectWork) {
        if (!work.fits(lap)) {
          return _phaseDetail('Rep ${repNo + 1}', lap, preset?.workSeconds);
        }
        repNo++;
        if (repNo > EngineConstants.maxReps) break;
      } else {
        if (!recovery.fits(lap)) {
          return _phaseDetail('Recovery $repNo', lap, preset?.recoverySeconds);
        }
        final prevWork = laps[i - 1];
        if (_speed(prevWork) < constants.workVsRecoveryMinRatio * _speed(lap)) {
          return 'Recovery $repNo was as fast as rep $repNo. Merge or split?';
        }
      }
      expectWork = !expectWork;
      i++;
    }
    if (preset != null) {
      return 'Found $count reps, the preset expected ${preset.reps}.';
    }
    return 'Found $count reps, a 4x4 needs 3 to 6.';
  }

  static String _phaseDetail(String phase, Lap lap, int? expectedSeconds) {
    if (expectedSeconds != null) {
      return '$phase was ${_mmss(lap.durationMs)}, the preset expected '
          '${_mmss(expectedSeconds * 1000)}. Keep it, merge it, or drop it?';
    }
    return '$phase was ${_mmss(lap.durationMs)}, outside the 4x4 window.';
  }

  static double _speed(Lap lap) =>
      lap.durationMs == 0 ? 0 : lap.distanceM / (lap.durationMs / 1000);

  /// Speed-stream fallback: a 20 s centred window speed per sample, a
  /// two-level threshold between the fast and easy modes, then contiguous
  /// segments become laps. Segments under 30 s are absorbed by their
  /// neighbours so a single GPS spike cannot create a rep.
  List<Lap> _lapsFromSpeed(Trace trace) {
    final samples = trace.samples;
    if (samples.length < 60) return const [];
    const halfMs = 10000;
    final speeds = List<double>.generate(samples.length, (i) {
      final t = samples[i].tMs;
      final a = (t - halfMs).clamp(trace.startMs, trace.endMs);
      final b = (t + halfMs).clamp(trace.startMs, trace.endMs);
      final dt = (b - a) / 1000;
      return dt <= 0 ? 0 : (trace.distAt(b) - trace.distAt(a)) / dt;
    });
    final sorted = List<double>.from(speeds)..sort();
    final fast =
        sorted[(sorted.length * 0.8).floor().clamp(0, sorted.length - 1)];
    final slow =
        sorted[(sorted.length * 0.3).floor().clamp(0, sorted.length - 1)];
    if (slow <= 0 || fast / slow < constants.workVsRecoveryMinRatio) {
      return const [];
    }
    final threshold = (fast + slow) / 2;
    final isFast = speeds.map((v) => v >= threshold).toList();

    // Segment boundaries as sample indices.
    var bounds = <int>[0];
    for (var i = 1; i < isFast.length; i++) {
      if (isFast[i] != isFast[i - 1]) bounds.add(i);
    }
    bounds.add(isFast.length);

    // Absorb short segments into the previous one until none remain.
    const minSegmentMs = 30000;
    var changed = true;
    while (changed && bounds.length > 2) {
      changed = false;
      for (var k = 1; k < bounds.length - 1; k++) {
        final segStart = samples[bounds[k - 1]].tMs;
        final segEnd = samples[bounds[k]].tMs;
        if (segEnd - segStart < minSegmentMs) {
          bounds.removeAt(k);
          // Merging also merges the segment after it with the one before.
          if (k < bounds.length - 1) bounds.removeAt(k);
          changed = true;
          break;
        }
      }
    }
    final laps = <Lap>[];
    for (var k = 1; k < bounds.length; k++) {
      final t0 = samples[bounds[k - 1]].tMs;
      final t1 = k == bounds.length - 1
          ? samples[bounds[k] - 1].tMs
          : samples[bounds[k]].tMs;
      if (t1 <= t0) continue;
      laps.add(
        Lap(
          index: laps.length,
          t0Ms: t0,
          t1Ms: t1,
          d0M: trace.distAt(t0),
          d1M: trace.distAt(t1),
          kind: LapKind.auto,
        ),
      );
    }
    return laps;
  }
}

String _mmss(int ms) {
  final totalSeconds = (ms / 1000).round();
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
