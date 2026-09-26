import '../model/run_file.dart';
import '../model/session_spec.dart';
import 'constants.dart';
import 'format.dart';
import 'rep_detector.dart';

/// Rep detection for every structured session except the Norwegian 4x4
/// (Phase 3 plan §3.7), which keeps [RepDetector] unchanged so no migrated
/// verdict moves.
///
/// The recorder writes one lap per step (a 0:00 recovery writes none), after
/// an open warm-up lap and before an open cool-down lap. The detector aligns
/// the session's expanded steps against the laps:
/// - a time step matches within ± max(5 s, 12.5%), capped at 30 s;
/// - a distance step matches on lap distance within ± max(25 m, 7%);
/// - an equal-time recovery (Yasso, pyramid) matches the measured time of
///   the work lap before it, with the time window;
/// - work must be at least [EngineConstants.workVsRecoveryMinRatio] faster
///   than the recovery next to it (a standing recovery always passes).
/// The longest aligned run of steps wins, starting at any lap and any step
/// (so a cut rep 2 leaves reps 3–8 aligned as themselves, and rep 2 is named
/// as the phase out of window). On a tie the block whose step 1 would sit
/// earliest at or after the first lap wins. The laps before it are warm-up, the laps
/// after it cool-down. There is no speed-stream
/// fallback: a session without laps gets no verdict.
class SessionDetector {
  SessionDetector(this.constants);

  final EngineConstants constants;

  List<Span> _pauses = const [];
  Set<int> _accepted = const {};

  RepDetection detect(
    List<Lap> laps,
    SessionSpec spec, {
    List<Span> pauses = const [],
    Set<int> accepted = const {},
    Set<int> dropped = const {},
  }) {
    _pauses = pauses;
    _accepted = accepted;
    // A 0:00 recovery is "straight into the next rep": no lap.
    final expected = [
      for (final s in spec.steps)
        if (!(s.kind == StepKind.recovery &&
            s.target == TargetKind.time &&
            s.value == 0))
          s,
    ];
    final expectedReps = spec.repCount;
    // One lap can only be a one-step session with nothing around it (K1: a
    // parkrun started on the line and stopped at 5 km).
    if (laps.isEmpty ||
        expected.isEmpty ||
        (laps.length < 2 && expected.length > 1)) {
      return RepDetection(
        warmup: laps,
        reps: const [],
        cooldown: const [],
        consistent: false,
        inconsistency: InconsistencyKind.noPattern,
        inconsistencyDetail: 'No laps to match the session against.',
        laps: laps,
      );
    }

    var bestStart = -1;
    var bestOffset = 0;
    var bestMatched = 0;
    for (var e = 0; e < expected.length; e++) {
      // A block must start on a work step.
      if (!expected[e].isWork) continue;
      for (var s = 0; s < laps.length; s++) {
        final n = _alignFrom(laps, s, expected, e);
        if (n == 0) continue;
        // Uniform sessions are shift-invariant, so equal-length alignments
        // tie. Prefer the one whose step 1 would sit earliest at or after
        // lap 0 (lap − step offset): a runner who stopped early aligns from
        // step 1 after the warm-up; a rep cut short early aligns the rest as
        // themselves (rep 3 at the lap where rep 3 was), not as reps 1–6.
        final origin = s - e;
        final bestOrigin = bestStart - bestOffset;
        final better =
            n > bestMatched ||
            (n == bestMatched &&
                origin >= 0 &&
                (bestOrigin < 0 || origin < bestOrigin));
        if (better) {
          bestMatched = n;
          bestStart = s;
          bestOffset = e;
        }
      }
    }
    if (bestMatched == 0) {
      return RepDetection(
        warmup: laps,
        reps: const [],
        cooldown: const [],
        consistent: false,
        inconsistency: InconsistencyKind.noPattern,
        inconsistencyDetail:
            'No lap matches the session\'s first rep '
            '(${_target(expected.first)}).',
        laps: laps,
      );
    }
    // A block that ends on a recovery gives that recovery back to the
    // cool-down unless another rep follows it (no recovery after the last
    // rep, founder rule 25-Sep).
    final aligned = bestMatched;
    if (!expected[bestOffset + bestMatched - 1].isWork) bestMatched -= 1;

    final block = laps.sublist(bestStart, bestStart + bestMatched);
    final reps = <DetectedRep>[];
    for (var k = 0; k < block.length; k++) {
      final step = expected[bestOffset + k];
      if (!step.isWork) continue;
      final w = block[k];
      final hasRec =
          k + 1 < block.length && !expected[bestOffset + k + 1].isWork;
      final r = hasRec ? block[k + 1] : null;
      final rStep = hasRec ? expected[bestOffset + k + 1] : null;
      reps.add(
        DetectedRep(
          number: step.rep,
          work: w,
          recovery: r,
          workDropped: dropped.contains(w.index),
          recoveryDropped: r != null && dropped.contains(r.index),
          workOutsideWindow: !_fitsStrict(step, w, null),
          recoveryOutsideWindow:
              r != null && !_fitsStrict(rStep!, r, w.durationMs),
          workStep: step,
          recoveryStep: rStep,
        ),
      );
    }
    final warmup = laps.sublist(0, bestStart);
    final end = bestStart + bestMatched;
    final cooldown = laps.sublist(end);

    InconsistencyKind? kind;
    String? detail;
    final matchedReps = reps.length;
    // Where the alignment broke. Before the block: the step before it
    // against the lap before it. After it: the next step against the next
    // lap. A lap that looks like that phase but is out of window is a cut
    // or long phase (named, never relabelled warm-up or cool-down);
    // otherwise the runner started late or stopped early, which one missing
    // rep is allowed to be.
    // Walk back from the block while the laps still look like the steps
    // before it; the first one out of its window is the broken phase.
    for (var k = 1; bestOffset - k >= 0 && bestStart - k >= 0; k++) {
      final step = expected[bestOffset - k];
      final lap = laps[bestStart - k];
      if (!_phaseLike(step, lap, reps)) break;
      final before = bestStart - k - 1 >= 0 ? laps[bestStart - k - 1] : null;
      if (!_fitsStrict(step, lap, before?.durationMs)) {
        kind = InconsistencyKind.phaseOutsideWindow;
        detail = _phaseDetail(step, lap, before?.durationMs);
        break;
      }
    }
    if (kind == null && bestOffset + aligned < expected.length) {
      final nextStep = expected[bestOffset + aligned];
      final at = bestStart + aligned;
      final nextLap = at < laps.length ? laps[at] : null;
      // The run ending inside a recovery is a cool-down by definition (as
      // the 4x4 treats a truncated final recovery).
      final endsInRecovery = !nextStep.isWork && at == laps.length - 1;
      if (nextLap != null &&
          !endsInRecovery &&
          _phaseLike(nextStep, nextLap, reps)) {
        kind = InconsistencyKind.phaseOutsideWindow;
        detail = _phaseDetail(nextStep, nextLap, laps[at - 1].durationMs);
      }
    }
    if (kind == null) {
      if (matchedReps < expectedReps - 1) {
        kind = InconsistencyKind.repCountOutOfRange;
        detail =
            'Found $matchedReps '
            '${matchedReps == 1 ? 'rep' : 'reps'}, the session expected '
            '$expectedReps.';
      }
    }
    return RepDetection(
      warmup: warmup,
      reps: reps,
      cooldown: cooldown,
      consistent: kind == null,
      inconsistency: kind,
      inconsistencyDetail: detail,
      laps: laps,
    );
  }

  /// How many expected steps, from step [offset], line up from lap [start].
  int _alignFrom(
    List<Lap> laps,
    int start,
    List<SessionStep> expected,
    int offset,
  ) {
    var j = 0;
    Lap? prevWork;
    Lap? prevRecovery;
    while (start + j < laps.length && offset + j < expected.length) {
      final step = expected[offset + j];
      final lap = laps[start + j];
      if (!_fits(step, lap, prevWork?.durationMs)) break;
      if (step.isWork) {
        if (prevRecovery != null && !_workFaster(lap, prevRecovery)) break;
        prevWork = lap;
      } else {
        if (prevWork != null && !_workFaster(prevWork, lap)) break;
        prevRecovery = lap;
      }
      j++;
    }
    return j;
  }

  bool _workFaster(Lap work, Lap recovery) =>
      _speed(work) >= constants.workVsRecoveryMinRatio * _speed(recovery);

  bool _fits(SessionStep step, Lap lap, int? previousWorkMs) =>
      _accepted.contains(lap.index) || _fitsStrict(step, lap, previousWorkMs);

  bool _fitsStrict(SessionStep step, Lap lap, int? previousWorkMs) {
    switch (step.target) {
      case TargetKind.time:
        return _timeFits(step.value * 1000, lap.durationMs);
      case TargetKind.equalToPreviousWork:
        return previousWorkMs != null &&
            _timeFits(previousWorkMs, lap.durationMs);
      case TargetKind.distance:
        final tol = _max(25, 0.07 * step.value);
        return (lap.distanceM - step.value).abs() <= tol;
    }
  }

  /// ± max(5 s, 12.5%), capped at 30 s.
  static bool _timeFits(int expectedMs, int actualMs) {
    final tol = _min(30000, _max(5000, expectedMs * 0.125));
    return (actualMs - expectedMs).abs() <= tol;
  }

  /// Looks like the expected phase (right side of the work/recovery speed
  /// split, within ±30% of its size) without fitting its window.
  bool _phaseLike(SessionStep step, Lap lap, List<DetectedRep> reps) {
    final near = switch (step.target) {
      TargetKind.distance =>
        lap.distanceM >= step.value * 0.7 && lap.distanceM <= step.value * 1.3,
      TargetKind.time =>
        lap.durationMs >= step.value * 700 &&
            lap.durationMs <= step.value * 1300,
      TargetKind.equalToPreviousWork =>
        reps.isNotEmpty &&
            lap.durationMs >= reps.last.work.durationMs * 0.7 &&
            lap.durationMs <= reps.last.work.durationMs * 1.3,
    };
    if (!near) return false;
    final ratio = constants.workVsRecoveryMinRatio;
    final recoveries = reps.map((r) => r.recovery).whereType<Lap>().toList();
    if (step.isWork) {
      if (recoveries.isEmpty) return true;
      return _speed(lap) >= ratio * _median(recoveries.map(_speed).toList());
    }
    return _speed(lap) * ratio <=
        _median(reps.map((r) => _speed(r.work)).toList());
  }

  String _phaseDetail(SessionStep step, Lap lap, int? previousWorkMs) {
    final name = step.isWork ? 'Rep ${step.rep}' : 'Recovery ${step.rep}';
    final was = step.target == TargetKind.distance
        ? '${lap.distanceM.round()} m'
        : PaceFormat.mmss(lap.durationMs / 1000);
    final expected = step.target == TargetKind.equalToPreviousWork
        ? (previousWorkMs == null
              ? 'the rep before it'
              : PaceFormat.mmss(previousWorkMs / 1000))
        : _target(step);
    return '$name was $was, the session expected $expected.';
  }

  static String _target(SessionStep step) => switch (step.target) {
    TargetKind.distance => '${step.value} m',
    TargetKind.time => PaceFormat.mmss(step.value.toDouble()),
    TargetKind.equalToPreviousWork => 'the rep before it',
  };

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

  static double _median(List<double> v) {
    final s = List<double>.from(v)..sort();
    return s[s.length ~/ 2];
  }

  static double _max(num a, num b) => (a > b ? a : b).toDouble();
  static double _min(num a, num b) => (a < b ? a : b).toDouble();
}
