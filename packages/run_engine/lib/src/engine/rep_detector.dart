import '../model/run_file.dart';
import '../model/session_spec.dart';
import 'constants.dart';
import 'trace.dart';

/// One detected rep: the work lap and, unless it was the last rep with the
/// final recovery missing, the recovery lap that followed it.
class DetectedRep {
  const DetectedRep({
    required this.number,
    required this.work,
    this.recovery,
    this.workDropped = false,
    this.recoveryDropped = false,
    this.workOutsideWindow = false,
    this.recoveryOutsideWindow = false,
    this.workStep,
    this.recoveryStep,
  });

  /// 1-based, as shown in the UI ("Rep 1..4").
  final int number;
  final Lap work;
  final Lap? recovery;

  /// The user dropped this phase (fix-laps `drop`): excluded from metrics.
  final bool workDropped;
  final bool recoveryDropped;

  /// Accepted by a `keep`/`drop` edit although outside the preset window.
  final bool workOutsideWindow;
  final bool recoveryOutsideWindow;

  /// The session steps this rep was matched against (Phase 3 generalised
  /// detection); null on the 4x4 path, which matches the legacy preset.
  final SessionStep? workStep;
  final SessionStep? recoveryStep;
}

/// Why the recorded laps do not form a 4x4 (plan §5 `lapsInconsistent`).
enum InconsistencyKind {
  /// No laps at all and the speed stream showed no work/recovery pattern.
  noPattern,

  /// Fewer or more reps than the preset (±1) or the 3–6 range allows.
  repCountOutOfRange,

  /// A phase next to the detected block was cut short or ran long beyond
  /// the tolerance (§6), e.g. rep 1 at 3:20 or rep 4 at 4:31.
  phaseOutsideWindow,
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

  /// The laps the detection ran over: pause laps dropped, fix-laps edits
  /// applied, renumbered so `Lap.index` == list position (or derived from
  /// speed when [fromSpeedStream]). **Fix-laps edits are indexed against this
  /// list**, never against the raw `RunFile.laps`.
  final List<Lap> laps;
}

class _Window {
  const _Window(this.minMs, this.maxMs);
  final int minMs;
  final int maxMs;
  bool fits(Lap lap) => lap.durationMs >= minMs && lap.durationMs <= maxMs;
  int get midMs => (minMs + maxMs) ~/ 2;
}

/// Preset-aware rep detection from laps (plan §5, §17 B5). Precedence is the
/// caller's: fix-laps edits are applied before this runs.
class RepDetector {
  RepDetector(this.constants);

  final EngineConstants constants;

  /// Pauses of the run being detected: lap speed uses moving time so a rep
  /// with a standstill inside it still reads as work.
  List<Span> _pauses = const [];
  Set<int> _accepted = const {};
  Set<int> _dropped = const {};

  bool _fits(_Window w, Lap lap) =>
      w.fits(lap) || _accepted.contains(lap.index);

  /// Recorded laps with `pause` laps dropped and indices renumbered to list
  /// position. This is the coordinate system fix-laps edits use.
  static List<Lap> editableLaps(List<Lap> recordedLaps) {
    final laps = recordedLaps.where((l) => l.kind != LapKind.pause).toList();
    return [for (var i = 0; i < laps.length; i++) laps[i].copyWith(index: i)];
  }

  /// True when a run has too few recorded laps to detect from and the speed
  /// stream must be used instead.
  static bool needsSpeedFallback(List<Lap> editable) => editable.length < 2;

  /// Laps derived from the speed stream (public so the caller can use them as
  /// the base for fix-laps edits on a no-lap run).
  List<Lap> deriveLapsFromSpeed(Trace trace) => _lapsFromSpeed(trace);

  /// Detects reps from [laps] (already pause-free and renumbered, see
  /// [editableLaps]; derived from speed when [fromSpeed]).
  /// [accepted] laps bypass the window check (fix-laps keep/drop);
  /// [dropped] ones are also marked excluded on the detected rep.
  RepDetection detect(
    List<Lap> laps,
    Preset? preset, {
    required bool fromSpeed,
    List<Span> pauses = const [],
    Set<int> accepted = const {},
    Set<int> dropped = const {},
  }) {
    _pauses = pauses;
    _accepted = accepted;
    _dropped = dropped;
    if (laps.length < 2) {
      return RepDetection(
        warmup: laps,
        reps: const [],
        cooldown: const [],
        consistent: false,
        inconsistency: InconsistencyKind.noPattern,
        inconsistencyDetail: fromSpeed
            ? 'No laps and no clear fast/easy pattern.'
            : 'Fewer than two laps.',
        fromSpeedStream: fromSpeed,
        laps: laps,
      );
    }
    return _detectFromLaps(laps, preset, fromSpeed: fromSpeed);
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
      while (i < laps.length && _fits(work, laps[i])) {
        final w = laps[i];
        Lap? r;
        if (i + 1 < laps.length &&
            _fits(recovery, laps[i + 1]) &&
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
        reps.add(
          DetectedRep(
            number: reps.length + 1,
            work: w,
            recovery: r,
            workDropped: _dropped.contains(w.index),
            recoveryDropped: r != null && _dropped.contains(r.index),
            workOutsideWindow: !work.fits(w),
            recoveryOutsideWindow: r != null && !recovery.fits(r),
          ),
        );
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
    InconsistencyKind? kind;
    if (!inRange) {
      kind = InconsistencyKind.repCountOutOfRange;
      detail = _explain(laps, bestReps, preset, work, recovery, count);
    } else {
      detail = _edgePhaseCutShort(
        laps,
        bestStart,
        bestEnd,
        bestReps,
        preset,
        work,
        recovery,
      );
      if (detail != null) kind = InconsistencyKind.phaseOutsideWindow;
    }
    return RepDetection(
      warmup: warmup,
      reps: bestReps,
      cooldown: cooldown,
      consistent: kind == null,
      inconsistency: kind,
      inconsistencyDetail: detail,
      fromSpeedStream: fromSpeed,
      laps: laps,
    );
  }

  /// §6: a phase cut short (or run long) beyond the tolerance on the edge of
  /// the block must not be relabelled warm-up or cool-down. Walk outwards
  /// from the block: a neighbouring lap that is phase-like (its speed says
  /// work or recovery and its length is within 30% of the expected phase)
  /// but does not fit the window is the cut phase. A lap that is not
  /// phase-like (a slow 8 min warm-up) ends the walk.
  String? _edgePhaseCutShort(
    List<Lap> laps,
    int blockStart,
    int blockEnd,
    List<DetectedRep> reps,
    Preset? preset,
    _Window work,
    _Window recovery,
  ) {
    final recoveries = reps.map((r) => r.recovery).whereType<Lap>().toList();
    if (recoveries.isEmpty) return null;
    final recoverySpeeds = recoveries.map(_speed).toList()..sort();
    final recoverySpeed = recoverySpeeds[recoverySpeeds.length ~/ 2];
    // No speed information (treadmill): nothing to judge a neighbour by.
    if (recoverySpeed <= 0) return null;
    final workSpeeds = reps.map((r) => _speed(r.work)).toList()..sort();
    final workSpeed = workSpeeds[workSpeeds.length ~/ 2];
    final ratio = constants.workVsRecoveryMinRatio;
    bool workLike(Lap l) =>
        _speed(l) >= ratio * recoverySpeed && _near(l, work.midMs);
    bool recoveryLike(Lap l) =>
        _speed(l) * ratio <= workSpeed && _near(l, recovery.midMs);

    // Backwards: the lap before the first work is expected to be a recovery.
    // Collect the phase-like chain first, then number it from the outside so
    // the cut phase gets its true number ("Rep 1", not "Rep 0").
    final chain = <(Lap, bool)>[]; // (lap, isWork), nearest to the block first
    var expectWork = false;
    for (var i = blockStart - 1; i >= 0; i--) {
      final lap = laps[i];
      if (expectWork ? !workLike(lap) : !recoveryLike(lap)) break;
      chain.add((lap, expectWork));
      expectWork = !expectWork;
    }
    final before = chain.reversed.toList();
    // A recovery-like lap with no work lap before it is a warm-up (a 2:15
    // warm-up is not "Recovery 0").
    if (before.isNotEmpty && !before.first.$2) before.removeAt(0);
    var repNo = 0;
    for (final (lap, isWork) in before) {
      if (isWork) repNo++;
      if (isWork && !_fits(work, lap)) {
        return _phaseDetail('Rep $repNo', lap, preset?.workSeconds);
      }
      if (!isWork && !_fits(recovery, lap)) {
        return _phaseDetail('Recovery $repNo', lap, preset?.recoverySeconds);
      }
    }
    final offset = before.where((e) => e.$2).length;

    // Forwards: after the block comes a work lap (recovery present) or the
    // missing final recovery.
    expectWork = reps.last.recovery != null;
    repNo = offset + reps.length;
    for (var i = blockEnd; i < laps.length; i++) {
      final lap = laps[i];
      if (expectWork) {
        if (!workLike(lap)) break;
        repNo++;
        if (!_fits(work, lap)) {
          return _phaseDetail('Rep $repNo', lap, preset?.workSeconds);
        }
      } else {
        if (!recoveryLike(lap)) break;
        // The run ending inside the final recovery is a cool-down by
        // definition (§5 tolerates a missing final recovery, so a truncated
        // one is tolerated too).
        if (i == laps.length - 1) break;
        if (!_fits(recovery, lap)) {
          return _phaseDetail('Recovery $repNo', lap, preset?.recoverySeconds);
        }
      }
      expectWork = !expectWork;
    }
    return null;
  }

  /// Within ±30% of the expected phase length: wide enough to catch a 3:20
  /// rep or a 2:20 recovery, narrow enough that an 8 min warm-up next to a
  /// 5:00 recovery is not mistaken for one.
  static bool _near(Lap lap, int expectedMs) =>
      lap.durationMs >= expectedMs * 0.7 && lap.durationMs <= expectedMs * 1.3;

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
    final maxReps = preset == null
        ? EngineConstants.maxReps
        : (preset.reps + 1).clamp(
            EngineConstants.minReps,
            EngineConstants.maxReps,
          );
    if (count > maxReps) {
      return preset != null
          ? 'Found $count reps, the preset expected ${preset.reps}.'
          : 'Found $count reps, a 4x4 needs 3 to 6.';
    }
    var i = laps.indexWhere((l) => _fits(work, l));
    if (i < 0) i = 0;
    var repNo = 0;
    var expectWork = true;
    while (i < laps.length) {
      final lap = laps[i];
      if (expectWork) {
        if (!_fits(work, lap)) {
          return _phaseDetail('Rep ${repNo + 1}', lap, preset?.workSeconds);
        }
        repNo++;
        if (repNo > EngineConstants.maxReps) break;
      } else {
        if (!_fits(recovery, lap)) {
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

  double _speed(Lap lap) {
    var paused = 0;
    for (final p in _pauses) {
      final lo = p.t0Ms > lap.t0Ms ? p.t0Ms : lap.t0Ms;
      final hi = p.t1Ms < lap.t1Ms ? p.t1Ms : lap.t1Ms;
      if (hi > lo) paused += hi - lo;
    }
    final moving = lap.durationMs - paused;
    return moving <= 0 ? 0 : lap.distanceM / (moving / 1000);
  }

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
