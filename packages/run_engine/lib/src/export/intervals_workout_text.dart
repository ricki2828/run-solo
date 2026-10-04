import 'fit_workout.dart';

/// A [FitWorkout] as Intervals.icu workout text (the `description` of a
/// planned workout), so one description of a session feeds both the .fit file
/// and the Intervals.icu push. Syntax per the Intervals.icu workout builder
/// guide (3 Mar 2026): `- <duration|distance> <target>`, `4x` repeat blocks
/// with a blank line each side (no nesting), text before a duration is a
/// prompt, `4:10-4:00/km Pace`, `85-95% HR`.
///
/// Intervals.icu needs a length for every step, so an open step (lap button)
/// cannot be written: an open warm-up or cool-down is left out, and a workout
/// with any other open step returns null.
abstract final class IntervalsWorkoutText {
  /// null when the workout has a step this text cannot hold. [maxHr] turns a
  /// heart rate window in bpm into a percent of max HR; without it HR targets
  /// are left out.
  static String? fromWorkout(FitWorkout w, {int? maxHr}) {
    final steps = w.steps;
    // Which steps a repeat step covers: fromIndex .. repeat index - 1.
    final inRepeat = <int, int>{}; // step index -> repeat step index
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.duration != FitDuration.repeat) continue;
      for (var k = s.durationValue!; k < i; k++) {
        inRepeat[k] = i;
      }
    }

    final out = StringBuffer();
    var i = 0;
    while (i < steps.length) {
      final s = steps[i];
      if (s.duration == FitDuration.repeat) {
        i++; // consumed with its block
        continue;
      }
      final rep = inRepeat[i];
      if (rep != null) {
        final r = steps[rep];
        out.writeln();
        out.writeln('${r.repeatTimes}x');
        for (var k = i; k < rep; k++) {
          final line = _line(steps[k], maxHr);
          if (line == null) return null;
          out.writeln(line);
        }
        out.writeln();
        i = rep + 1;
        continue;
      }
      if (s.duration == FitDuration.open) {
        if (s.intensity == FitIntensity.warmup ||
            s.intensity == FitIntensity.cooldown) {
          i++;
          continue;
        }
        return null;
      }
      final line = _line(s, maxHr);
      if (line == null) return null;
      out.writeln(line);
      i++;
    }
    final text = out.toString().trim();
    return text.isEmpty ? null : text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  static String? _line(FitStep s, int? maxHr) {
    final String length;
    switch (s.duration) {
      case FitDuration.time:
        length = _time(s.durationValue! ~/ 1000);
      case FitDuration.distance:
        length = _distance(s.durationValue! ~/ 100);
      default:
        return null;
    }
    final target = _target(s.target, maxHr);
    return '- ${s.name} $length${target == null ? '' : ' $target'}';
  }

  static String _time(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, sec = seconds % 60;
    return '${h > 0 ? '${h}h' : ''}${m > 0 ? '${m}m' : ''}'
        '${sec > 0 || seconds == 0 ? '${sec}s' : ''}';
  }

  static String _distance(int metres) => metres >= 1000 && metres % 1000 == 0
      ? '${metres ~/ 1000}km'
      : '${metres}mtr';

  static String? _target(FitTarget t, int? maxHr) {
    final lo = t.low, hi = t.high;
    if (t.isOpen || lo == null || hi == null) return null;
    if (t.typeCode == 0) {
      // Speed in mm/s: low is the slow edge. Slow-fast, as the guide writes it.
      return '${_pace(1000000 / lo)}-${_pace(1000000 / hi)}/km Pace';
    }
    if (maxHr == null) return null;
    final a = ((lo - 100) * 100 / maxHr).round();
    final b = ((hi - 100) * 100 / maxHr).round();
    return '$a-$b% HR';
  }

  static String _pace(double secPerKm) {
    final s = secPerKm.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
