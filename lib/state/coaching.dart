/// CR2 (Phase 4 plan §3.6, design A10.4 / A10.6): the after-run coaching
/// and the Home "try next" card, from the index entries (W5b: never the
/// run analysis, which is empty on a device). CR1's [engine.CoachReporter]
/// does the thinking; this only feeds it the runner's history.
library;

import 'package:run_engine/run_engine.dart' as engine;

import 'run_index.dart';

/// The "try next" suggestion Home shows, and the run it came from.
class TryNext {
  const TryNext({
    required this.runId,
    required this.suggestion,
    required this.reason,
  });

  /// The run whose report made it (dismissal is per run).
  final String runId;
  final engine.CoachSuggestion suggestion;

  /// Why, in one plain line (A10.4's grey second line).
  final String reason;
}

class Coaching {
  Coaching._(this._runs);

  /// Every entry with derived data, oldest first. An entry still waiting
  /// for its derived data is left out, so its coaching appears once the
  /// background batch lands (fold again on `derivedChanged`).
  factory Coaching.fold(Iterable<RunIndexEntry> entries) => Coaching._(
    [
      for (final e in entries)
        if (e.derived case final d?)
          engine.CoachRun(
            runId: e.id,
            date: e.start,
            mode: e.mode,
            derived: d,
            durationMs: e.durationMs,
            comparisonKey: e.comparisonKey,
            cooperVo2: e.row?.cooper?.valid == true ? e.row!.cooper!.vo2 : null,
          ),
    ]..sort((a, b) => a.date.compareTo(b.date)),
  );

  static final Coaching empty = Coaching._(const []);

  final List<engine.CoachRun> _runs;
  static const _reporter = engine.CoachReporter();

  /// The run's observation and suggestion, from the runs before it; null
  /// while the run has no derived data (or is not indexed).
  engine.CoachReport? reportFor(String runId) {
    final run = _runs.where((r) => r.runId == runId).firstOrNull;
    if (run == null) return null;
    return _reporter.report(run: run, history: _runs);
  }

  /// How many recent runs Home looks back through for a suggestion.
  static const int lookBack = 10;

  /// Home's one card (A10.4): the latest run's suggestion that no later
  /// run has done yet and the runner has not dismissed; null otherwise.
  TryNext? tryNext({String? dismissedRunId}) {
    final start = _runs.length > lookBack ? _runs.length - lookBack : 0;
    for (var i = _runs.length - 1; i >= start; i--) {
      final s = _reporter.report(run: _runs[i], history: _runs).suggestion;
      if (s == null) continue;
      if (_runs[i].runId == dismissedRunId) return null;
      final done = _runs.skip(i + 1).any(s.doneBy);
      return done
          ? null
          : TryNext(runId: _runs[i].runId, suggestion: s, reason: reasonOf(s));
    }
    return null;
  }

  /// The rule behind each suggestion (plan §3.6 table), in plain words.
  static String reasonOf(engine.CoachSuggestion s) => switch (s.kind) {
    engine.SuggestionKind.zone2LongRun =>
      'Two of your last three 10K efforts slowed in the second half, and '
          'you have had no run of an hour or more in 4 weeks.',
    engine.SuggestionKind.fewerReps =>
      'Three of your last four sessions dropped off by the last rep.',
    engine.SuggestionKind.norwegian4x4 =>
      'Your last three 12-minute tests came out about the same.',
  };
}
