/// A run file as the health store takes it (Send runs → Health). Pure Dart so
/// the mapping is tested without a device; Kotlin only turns the result into
/// Health Connect records.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/platform_api.g.dart';

int _min(int a, int b) => a < b ? a : b;

/// Pauses sorted, with touching and overlapping ones joined: the store wants
/// non-overlapping segments (auto-pause adds many short ones).
List<engine.Span> _mergedPauses(List<engine.Span> pauses) {
  final sorted = [
    for (final p in pauses)
      if (p.t1Ms > p.t0Ms) p,
  ]..sort((a, b) => a.t0Ms.compareTo(b.t0Ms));
  final out = <engine.Span>[];
  for (final p in sorted) {
    if (out.isNotEmpty && p.t0Ms <= out.last.t1Ms) {
      final last = out.removeLast();
      out.add(engine.Span(last.t0Ms, p.t1Ms > last.t1Ms ? p.t1Ms : last.t1Ms));
    } else {
      out.add(p);
    }
  }
  return out;
}

abstract final class HealthWorkoutBuilder {
  /// Heart rate and route points closer than this are thinned: a 1 Hz run
  /// would otherwise write thousands of points per hour.
  static const int minGapMs = 5000;

  /// The first and last 200 m of the route are left out, like the shared
  /// files (the start and finish are usually home).
  static const double homeTrimM = 200;

  static HealthWorkout build(
    engine.RunFile run, {
    required String title,
    required int utcOffsetSeconds,
    required int version,
  }) {
    final startMs = run.start.millisecondsSinceEpoch;
    final total = run.distanceM;
    // The store needs a session of at least one second.
    final endMs = run.end.millisecondsSinceEpoch <= startMs
        ? startMs + 1000
        : run.end.millisecondsSinceEpoch;

    final hr = <HealthHrSample>[];
    final route = <HealthRoutePoint>[];
    var lastHr = -minGapMs;
    var lastPoint = -minGapMs;
    for (final s in run.samples) {
      final at = startMs + s.tMs;
      final bpm = s.hr;
      if (bpm != null && bpm > 0 && s.tMs - lastHr >= minGapMs) {
        hr.add(HealthHrSample(epochMs: at, bpm: bpm));
        lastHr = s.tMs;
      }
      final inside = s.distM >= homeTrimM && total - s.distM >= homeTrimM;
      if (s.hasFix && inside && s.tMs - lastPoint >= minGapMs) {
        route.add(
          HealthRoutePoint(
            epochMs: at,
            lat: s.lat!,
            lon: s.lon!,
            altM: s.altM,
            accuracyM: s.accM,
          ),
        );
        lastPoint = s.tMs;
      }
    }

    return HealthWorkout(
      clientRecordId: run.id,
      version: version,
      title: title,
      startEpochMs: startMs,
      endEpochMs: endMs,
      utcOffsetSeconds: utcOffsetSeconds,
      distanceM: total,
      laps: [
        for (final l in run.laps)
          if (l.kind != engine.LapKind.pause &&
              l.t1Ms > l.t0Ms &&
              startMs + l.t0Ms < endMs)
            HealthLap(
              startEpochMs: startMs + l.t0Ms,
              endEpochMs: _min(startMs + l.t1Ms, endMs),
              distanceM: l.distanceM,
            ),
      ],
      pauses: [
        for (final p in _mergedPauses(run.pauses))
          if (startMs + p.t0Ms < endMs)
            HealthPause(
              startEpochMs: startMs + p.t0Ms,
              endEpochMs: _min(startMs + p.t1Ms, endMs),
            ),
      ],
      hr: hr,
      route: route,
    );
  }
}
