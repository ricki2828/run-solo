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

class PerfDiagnostics extends ChangeNotifier {
  PerfDiagnostics._();

  static final PerfDiagnostics instance = PerfDiagnostics._();

  /// Last `LiveContextSource.prepare()` that read the index (background
  /// isolate, wall time).
  int? prepareMs;

  /// Last planning pass at a Start press (UI isolate).
  int? buildMs;

  /// Runs the last prepare saw in the index.
  int? runCount;

  /// The first History list of this app session (index read + refresh).
  int? historyFirstOpenMs;

  void recordPrepare(Duration d, int runs) {
    prepareMs = d.inMilliseconds;
    runCount = runs;
    notifyListeners();
  }

  void recordBuild(Duration d) {
    buildMs = d.inMilliseconds;
    notifyListeners();
  }

  void recordHistoryOpen(Duration d) {
    if (historyFirstOpenMs != null) return;
    historyFirstOpenMs = d.inMilliseconds;
    notifyListeners();
  }

  String _ms(int? v) => v == null ? 'not yet' : '$v ms';

  /// The Settings lines, plain.
  List<String> get lines => [
    'Live compare prepare: ${_ms(prepareMs)}'
        '${runCount == null ? '' : ' ($runCount runs)'}',
    'Live compare at Start: ${_ms(buildMs)}',
    'History first open: ${_ms(historyFirstOpenMs)}',
  ];

  @visibleForTesting
  void reset() {
    prepareMs = null;
    buildMs = null;
    runCount = null;
    historyFirstOpenMs = null;
  }
}
