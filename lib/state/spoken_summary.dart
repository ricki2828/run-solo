/// The spoken summary at the end of a run (founder 3 Oct): distance, time,
/// pace and climb, then the verdict in the result screen's own words. Native
/// composes and speaks the line (`SummaryWords`, JVM-tested); this picks the
/// verdict words per run type and hands everything over once the result is
/// loaded. Voice cues or Settings → Voice → Spoken summary off: silent.
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'history_store.dart';
import 'settings.dart';
import 'trails.dart';

/// The words after the stats: a 4x4's headline, a Trail run's result. Null
/// when the run has no verdict (a Free or Laps run, a goal, a Cooper test) or
/// it is not computed yet; the stats are then said alone.
String? spokenVerdictOf(RunDetail d, List<RunSummary> all) {
  final s = d.summary;
  switch (s.mode) {
    case RecordMode.trail:
      return engine.SpokenVerdict.ofTrail(
        engine.TrailVerdict.of(trailFactsOfDetail(d), trailFactsOfAll(all)),
      );
    case RecordMode.intervals:
      if (s.spec?.isGoal == true) return null;
      return engine.SpokenVerdict.ofSession(
        s.verdict,
        sessionName: s.spec?.templateId == engine.SessionSpec.norwegian4x4Id
            ? 'Norwegian 4x4'
            : null,
      );
    case RecordMode.free:
    case RecordMode.laps:
    case RecordMode.cooper:
      return null;
  }
}

/// Says the end-of-run line for a run that has just finished. Never throws:
/// a missing voice is not worth a broken result screen.
Future<void> speakRunSummary(
  RecorderGateway recorder,
  AppSettings settings,
  RunDetail d,
  List<RunSummary> all,
) async {
  if (!settings.cues || !settings.spokenSummary) return;
  try {
    final climb =
        d.summary.row?.climbM ?? engine.RunElevation.of(d.run)?.ascentM;
    await recorder.speakRunSummary(
      distanceM: d.summary.distanceM,
      timeMs: d.summary.mode == RecordMode.trail
          ? trailFactsOfDetail(d).movingMs
          : d.summary.durationMs,
      climbM: climb,
      verdict: spokenVerdictOf(d, all),
      units: settings.units,
    );
  } catch (_) {}
}
