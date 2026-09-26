/// Phone timings for the live compare and History (dogfood only). Read off
/// Settings → Diagnostics after a few days of runs to clear the
/// LIVE_COMPARE flag (#59 review P2: prepare and Start on the A-series phone
/// with ~200 runs). Recorded whether or not the live compare is on; kept in
/// memory for this app session only.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

/// Every build except the store one shows the row and records timings.
const bool kPerfDiagnostics = appFlavor != 'play';

/// How a Start's planning pass ended.
enum BuildOutcome { ok, timedOut, failed }

class PerfDiagnostics extends ChangeNotifier {
  PerfDiagnostics._();

  static final PerfDiagnostics instance = PerfDiagnostics._();

  /// Last `LiveContextSource.prepare()` that read the index (background
  /// isolate, wall time).
  int? prepareMs;

  /// Last planning pass at a Start press (UI isolate), however it ended:
  /// a miss is the number this row exists for (#69 review P2).
  int? buildMs;
  BuildOutcome? buildOutcome;

  /// The slowest pass this session, and how it ended.
  int? worstBuildMs;
  BuildOutcome? worstBuildOutcome;

  /// Runs the last prepare saw in the index.
  int? runCount;

  /// The first History list of this app session (index read + refresh).
  int? historyFirstOpenMs;

  void recordPrepare(Duration d, int runs) {
    prepareMs = d.inMilliseconds;
    runCount = runs;
    notifyListeners();
  }

  void recordBuild(Duration d, {BuildOutcome outcome = BuildOutcome.ok}) {
    buildMs = d.inMilliseconds;
    buildOutcome = outcome;
    if (worstBuildMs == null || buildMs! >= worstBuildMs!) {
      worstBuildMs = buildMs;
      worstBuildOutcome = outcome;
    }
    notifyListeners();
  }

  void recordHistoryOpen(Duration d) {
    if (historyFirstOpenMs != null) return;
    historyFirstOpenMs = d.inMilliseconds;
    notifyListeners();
  }

  String _ms(int? v) => v == null ? 'not yet' : '$v ms';

  String _build(int? ms, BuildOutcome? o) => switch (o) {
    null => 'not yet',
    BuildOutcome.ok => '$ms ms',
    BuildOutcome.timedOut => '$ms ms (timed out)',
    BuildOutcome.failed => '$ms ms (failed)',
  };

  /// The Settings lines, plain.
  List<String> get lines => [
    'Live compare prepare: ${_ms(prepareMs)}'
        '${runCount == null ? '' : ' ($runCount runs)'}',
    // With the compare off, the timed pass runs beside recording.start on
    // the same isolate, so it reads a little slow (#69 review P3).
    'Live compare at Start: ${_build(buildMs, buildOutcome)}',
    'Slowest Start this session: '
        '${_build(worstBuildMs, worstBuildOutcome)}',
    'History first open: ${_ms(historyFirstOpenMs)}',
  ];

  @visibleForTesting
  void reset() {
    prepareMs = null;
    buildMs = null;
    buildOutcome = null;
    worstBuildMs = null;
    worstBuildOutcome = null;
    runCount = null;
    historyFirstOpenMs = null;
  }
}
