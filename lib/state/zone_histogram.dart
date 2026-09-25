/// Display helpers for run detail that are not engine metrics.
library;

import 'package:run_engine/run_engine.dart' as engine;

/// Seconds spent in each HR zone 0–5 over the run (run detail strip; zones
/// per addendum A1 shares, no hysteresis needed for a histogram).
List<double> zoneSecondsOf(engine.RunFile run, int maxHrUsed) {
  final out = List<double>.filled(6, 0);
  final samples = run.samples;
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    // Weight by the gap to the next sample, capped so a dropout or a pause
    // does not credit minutes to one reading.
    final dt = i + 1 < samples.length
        ? ((samples[i + 1].tMs - s.tMs) / 1000).clamp(0.0, 5.0)
        : 1.0;
    final hr = s.hr;
    if (hr == null) {
      out[0] += dt;
      continue;
    }
    final f = hr / maxHrUsed;
    final z = f < 0.6
        ? 1
        : f < 0.7
        ? 2
        : f < 0.8
        ? 3
        : f < 0.9
        ? 4
        : 5;
    out[z] += dt;
  }
  return out;
}
