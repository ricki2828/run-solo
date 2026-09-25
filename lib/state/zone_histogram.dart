/// Display helpers for run detail that are not engine metrics.
library;

import 'package:run_engine/run_engine.dart' as engine;

/// Seconds spent in each HR zone 0–5 over the run (run detail strip; zones
/// per addendum A1 shares, no hysteresis needed for a histogram).
List<double> zoneSecondsOf(engine.RunFile run, int maxHrUsed) {
  final out = List<double>.filled(6, 0);
  for (final s in run.samples) {
    final hr = s.hr;
    if (hr == null) {
      out[0] += 1;
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
    out[z] += 1;
  }
  return out;
}
