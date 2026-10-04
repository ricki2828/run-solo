import 'dart:typed_data';

import '../model/session_spec.dart';
import 'fit_writer.dart';

/// Run Supreme sessions as FIT workout files, the structured workout a
/// Garmin watch can run. Subset used (FIT SDK profile, file type `workout`):
///
/// - `file_id` (0): type = workout (5), manufacturer = development (255),
///   product 0, time_created.
/// - `workout` (26): sport = running (1), num_valid_steps, wkt_name (32 byte
///   buffer, 31 usable).
/// - `workout_step` (27), every step carries the same nine fields:
///   message_index (254), wkt_step_name (0, 16 byte buffer), duration_type
///   (1), duration_value (2), target_type (3), target_value (4),
///   custom_target_value_low (5), custom_target_value_high (6), intensity (7).
/// - Durations: `time` (0, milliseconds), `distance` (1, centimetres), `open`
///   (5, lap button), `repeat_until_steps_cmplt` (6).
/// - Targets: `speed` (0) with a custom range in mm/s (pace), `heart_rate`
///   (1) with a custom range in bpm + 100 (the profile's offset for absolute
///   bpm), `open` (2).
/// - Intensities: warmup (2), interval (5), recovery (4), rest (1),
///   cooldown (3).
/// - A repeat step has duration_type = repeat_until_steps_cmplt, duration_value
///   = message_index of the first step in the block and target_value = the
///   repetition count (target_type open), no intensity.
///
/// A step has one target, so a work step gets a pace range when one is given,
/// otherwise the session's heart rate band when the max HR is known.
/// Not produced: workout_step notes, secondary targets, power, cadence,
/// developer fields, multi-sport.

enum FitDuration {
  time(0),
  distance(1),
  open(5),
  repeat(6);

  const FitDuration(this.code);
  final int code;
}

enum FitIntensity {
  rest(1),
  warmup(2),
  cooldown(3),
  recovery(4),
  interval(5);

  const FitIntensity(this.code);
  final int code;
}

/// What a watch should hold a step to. [FitTarget.open] = no target.
class FitTarget {
  const FitTarget.open() : _type = 2, low = null, high = null;

  /// A pace window in seconds per km: [slowSecPerKm] is the slow edge.
  /// Encoded as speed in mm/s (the profile's `speed` target unit).
  FitTarget.pace({required int slowSecPerKm, required int fastSecPerKm})
    : _type = 0,
      low = _speedMmS(slowSecPerKm),
      high = _speedMmS(fastSecPerKm) {
    if (fastSecPerKm < 90 ||
        slowSecPerKm > 1800 ||
        fastSecPerKm >= slowSecPerKm) {
      throw ArgumentError(
        'pace window $fastSecPerKm to $slowSecPerKm s/km is not usable',
      );
    }
  }

  /// A heart rate window in beats per minute.
  FitTarget.heartRate({required int lowBpm, required int highBpm})
    : _type = 1,
      low = lowBpm + 100,
      high = highBpm + 100 {
    if (lowBpm < 30 || highBpm > 250 || lowBpm >= highBpm) {
      throw ArgumentError(
        'heart rate window $lowBpm to $highBpm is not usable',
      );
    }
  }

  static int _speedMmS(int secPerKm) => (1000000 / secPerKm).round();

  final int _type;

  /// The wire values of custom_target_value_low/high (null for open).
  final int? low;
  final int? high;

  int get typeCode => _type;
  bool get isOpen => _type == 2;

  @override
  bool operator ==(Object other) =>
      other is FitTarget &&
      other._type == _type &&
      other.low == low &&
      other.high == high;

  @override
  int get hashCode => Object.hash(_type, low, high);
}

/// One workout_step message before it is numbered.
class FitStep {
  const FitStep({
    required this.name,
    required this.duration,
    this.durationValue,
    this.target = const FitTarget.open(),
    required FitIntensity this.intensity,
  }) : repeatTimes = null;

  /// The repeat step: go back to step [fromIndex], [times] times in all.
  const FitStep.repeat({required int fromIndex, required int times})
    : name = '',
      duration = FitDuration.repeat,
      durationValue = fromIndex,
      target = const FitTarget.open(),
      intensity = null,
      repeatTimes = times;

  final String name;
  final FitDuration duration;

  /// Milliseconds for time, centimetres for distance, the block's first step
  /// index for a repeat, null for open.
  final int? durationValue;
  final FitTarget target;
  final FitIntensity? intensity;

  /// Repetitions of a repeat step; null for every other step.
  final int? repeatTimes;
}

/// A workout ready to encode: a name and numbered steps.
class FitWorkout {
  const FitWorkout({required this.name, required this.steps});

  final String name;
  final List<FitStep> steps;

  /// The most steps we write (a watch holds a bounded number; the app's own
  /// sessions expand to at most [SessionSpec.maxSteps] and compress with
  /// repeats well below this).
  static const int maxSteps = 100;

  /// A session as a workout. Warm-up and cool-down: null seconds = open (lap
  /// button), 0 = none. Work steps take [workPace] when given, else the
  /// session's heart rate band when [maxHr] is known, else no target.
  /// Recoveries never carry a target. A Yasso recovery ("equal to the work")
  /// becomes the work step's own time, or the lap button after a distance
  /// rep. Returns null for a session with no steps (fartlek, bronco): there
  /// is nothing for a watch to run.
  ///
  /// Identical (work, recovery) pairs compress into a repeat step; the last
  /// rep has no recovery after it, so it follows the repeat as its own step.
  static FitWorkout? fromSession(
    SessionSpec spec, {
    FitTarget? workPace,
    int? maxHr,
  }) {
    if (spec.steps.isEmpty) return null;
    final workTarget = workPace ?? _hrBand(spec, maxHr);

    FitStep work(SessionStep s) => FitStep(
      name: 'Work',
      duration: s.target == TargetKind.distance
          ? FitDuration.distance
          : FitDuration.time,
      durationValue: s.target == TargetKind.distance
          ? s.value * 100
          : s.value * 1000,
      target: workTarget,
      intensity: FitIntensity.interval,
    );

    FitStep recovery(SessionStep s, SessionStep? before) {
      final intensity =
          s.style == RecoveryStyle.run || s.style == RecoveryStyle.jog
          ? FitIntensity.recovery
          : FitIntensity.rest;
      switch (s.target) {
        case TargetKind.time:
          return FitStep(
            name: 'Recovery',
            duration: FitDuration.time,
            durationValue: s.value * 1000,
            intensity: intensity,
          );
        case TargetKind.distance:
          return FitStep(
            name: 'Recovery',
            duration: FitDuration.distance,
            durationValue: s.value * 100,
            intensity: intensity,
          );
        case TargetKind.equalToPreviousWork:
          if (before != null && before.target == TargetKind.time) {
            return FitStep(
              name: 'Recovery',
              duration: FitDuration.time,
              durationValue: before.value * 1000,
              intensity: intensity,
            );
          }
          return FitStep(
            name: 'Recovery',
            duration: FitDuration.open,
            intensity: intensity,
          );
      }
    }

    FitStep edge(int? seconds, String name, FitIntensity intensity) => FitStep(
      name: name,
      duration: seconds == null ? FitDuration.open : FitDuration.time,
      durationValue: seconds == null ? null : seconds * 1000,
      intensity: intensity,
    );

    final out = <FitStep>[];
    if (spec.warmupSeconds != 0) {
      out.add(edge(spec.warmupSeconds, 'Warm-up', FitIntensity.warmup));
    }

    final steps = spec.steps;
    // Uniform (work, recovery) x n, n >= 3: a repeat block of n - 1, then the
    // last work step.
    final uniform = _uniformPairs(steps);
    if (uniform != null && uniform >= 3) {
      final first = out.length;
      out
        ..add(work(steps[0]))
        ..add(recovery(steps[1], steps[0]))
        ..add(FitStep.repeat(fromIndex: first, times: uniform - 1))
        ..add(work(steps.last));
    } else {
      for (var i = 0; i < steps.length; i++) {
        final s = steps[i];
        out.add(s.isWork ? work(s) : recovery(s, i > 0 ? steps[i - 1] : null));
      }
    }

    if (spec.cooldownSeconds != 0) {
      out.add(edge(spec.cooldownSeconds, 'Cool-down', FitIntensity.cooldown));
    }
    if (out.length > maxSteps) return null;
    return FitWorkout(name: spec.name, steps: out);
  }

  /// n when [steps] is work, recovery, ..., work with every work step equal
  /// and every recovery equal (ignoring the rep number); null otherwise.
  static int? _uniformPairs(List<SessionStep> steps) {
    if (steps.length < 3 || steps.length.isEven) return null;
    bool same(SessionStep a, SessionStep b) =>
        a.kind == b.kind &&
        a.target == b.target &&
        a.value == b.value &&
        a.style == b.style;
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].isWork != i.isEven) return null;
      if (!same(steps[i], steps[i % 2])) return null;
    }
    return (steps.length + 1) ~/ 2;
  }

  static FitTarget _hrBand(SessionSpec spec, int? maxHr) {
    final lo = spec.hrBandLow, hi = spec.hrBandHigh;
    if (maxHr == null || lo == null || hi == null) {
      return const FitTarget.open();
    }
    final low = (maxHr * lo).round(), high = (maxHr * hi).round();
    if (low < 30 || high > 250 || low >= high) return const FitTarget.open();
    return FitTarget.heartRate(lowBpm: low, highBpm: high);
  }
}

/// Encodes a [FitWorkout] to the bytes of a `.fit` workout file.
abstract final class FitWorkoutEncoder {
  static const int _fileId = 0;
  static const int _workout = 26;
  static const int _workoutStep = 27;
  static const int _fileTypeWorkout = 5;
  static const int _manufacturerDevelopment = 255;
  static const int _sportRunning = 1;

  static const int nameBytes = 32;
  static const int stepNameBytes = 16;

  static Uint8List encode(FitWorkout w, {required DateTime created}) {
    if (w.steps.isEmpty) throw ArgumentError('a workout needs steps');
    if (w.steps.length > FitWorkout.maxSteps) {
      throw ArgumentError('too many steps: ${w.steps.length}');
    }
    final out = FitWriter();
    out.message(
      _fileId,
      const [
        FitFieldDef(0, FitBase.enum8), // type
        FitFieldDef(1, FitBase.uint16), // manufacturer
        FitFieldDef(2, FitBase.uint16), // product
        FitFieldDef(4, FitBase.uint32), // time_created
      ],
      [
        _fileTypeWorkout,
        _manufacturerDevelopment,
        0,
        FitWriter.fitTimestamp(created),
      ],
    );
    out.message(
      _workout,
      const [
        FitFieldDef(4, FitBase.enum8), // sport
        FitFieldDef(6, FitBase.uint16), // num_valid_steps
        FitFieldDef(8, FitBase.string, nameBytes), // wkt_name
      ],
      [_sportRunning, w.steps.length, w.name],
    );
    const stepFields = [
      FitFieldDef(254, FitBase.uint16), // message_index
      FitFieldDef(0, FitBase.string, stepNameBytes), // wkt_step_name
      FitFieldDef(1, FitBase.enum8), // duration_type
      FitFieldDef(2, FitBase.uint32), // duration_value
      FitFieldDef(3, FitBase.enum8), // target_type
      FitFieldDef(4, FitBase.uint32), // target_value
      FitFieldDef(5, FitBase.uint32), // custom_target_value_low
      FitFieldDef(6, FitBase.uint32), // custom_target_value_high
      FitFieldDef(7, FitBase.enum8), // intensity
    ];
    for (var i = 0; i < w.steps.length; i++) {
      final s = w.steps[i];
      if (s.duration == FitDuration.repeat) {
        final from = s.durationValue!;
        if (from < 0 || from >= i || (s.repeatTimes ?? 0) < 1) {
          throw ArgumentError('bad repeat step at $i');
        }
      }
      out.message(_workoutStep, stepFields, [
        i,
        s.name,
        s.duration.code,
        s.durationValue,
        s.target.typeCode,
        s.repeatTimes ??
            0, // target_value: reps for a repeat, else 0 = custom range
        s.target.low,
        s.target.high,
        s.intensity?.code,
      ]);
    }
    return out.finish();
  }
}
