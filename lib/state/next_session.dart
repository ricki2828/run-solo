import 'package:run_engine/run_engine.dart' as engine;

import '../app/format.dart';
import '../platform/gateway.dart';
import '../widgets/goal_picker.dart';
import 'history_store.dart';
import 'settings.dart';

enum NextKind { plan, interval, bronco, free, laps, fartlek, cooper, goal }

/// The one "next session" Home shows: the plan's when a plan is active, else
/// the last-used run type. The headline, the line under it and the Start
/// label all read it, so they cannot disagree.
class NextSession {
  const NextSession({
    required this.name,
    required this.kind,
    this.templateId,
    this.isEvent = false,
    this.goalIsDistance,
    this.goalValue,
  });

  factory NextSession.plan(String name) =>
      NextSession(name: name, kind: NextKind.plan);

  factory NextSession.lastUsed(AppSettings s, engine.SessionSpec picked) {
    if (s.goalRun) {
      final label = goalLabel(s);
      return NextSession(
        name: label == 'Distance or time' ? 'goal run' : label,
        kind: NextKind.goal,
        isEvent: s.eventRun,
        goalIsDistance: s.goalStep?.distance,
        goalValue: s.goalStep?.value,
      );
    }
    return switch (s.lastMode) {
      RecordMode.free => const NextSession(
        name: 'free run',
        kind: NextKind.free,
      ),
      RecordMode.laps =>
        picked.templateId == engine.SessionSpec.broncoId
            ? const NextSession(
                name: 'Bronco test',
                kind: NextKind.bronco,
                templateId: engine.SessionSpec.broncoId,
              )
            : const NextSession(name: 'laps run', kind: NextKind.laps),
      RecordMode.cooper => const NextSession(
        name: '12-minute test',
        kind: NextKind.cooper,
      ),
      // Fartlek is picked under Intervals but recorded as a Laps run.
      RecordMode.intervals =>
        picked.templateId == engine.SessionSpec.fartlekId
            ? NextSession(
                name: picked.name,
                kind: NextKind.fartlek,
                templateId: picked.templateId,
              )
            : NextSession(
                name: picked.name,
                kind: NextKind.interval,
                templateId: picked.templateId,
              ),
    };
  }

  final String name;
  final NextKind kind;
  final String? templateId;
  final bool isEvent;

  /// A goal run's target, matched by value (metres or seconds), never by
  /// label text, so switching units cannot break the match.
  final bool? goalIsDistance;
  final int? goalValue;

  String get startLabel => 'Start $name';

  bool matches(RunSummary r) => switch (kind) {
    NextKind.plan => false,
    NextKind.interval =>
      r.isFourByFour &&
          (r.spec?.templateId ?? engine.SessionSpec.norwegian4x4Id) ==
              templateId,
    NextKind.bronco =>
      r.mode == RecordMode.laps &&
          r.spec?.templateId == engine.SessionSpec.broncoId,
    NextKind.laps =>
      r.mode == RecordMode.laps &&
          r.spec?.templateId != engine.SessionSpec.broncoId &&
          r.spec?.templateId != engine.SessionSpec.fartlekId,
    NextKind.fartlek =>
      r.mode == RecordMode.laps &&
          r.spec?.templateId == engine.SessionSpec.fartlekId,
    NextKind.free => r.mode == RecordMode.free,
    NextKind.cooper => r.mode == RecordMode.cooper,
    NextKind.goal => isEvent ? r.isParkrun : _goalMatches(r),
  };
}

extension on NextSession {
  bool _goalMatches(RunSummary r) {
    final g = r.row?.goal ?? r.analysis?.goal;
    if (r.spec?.isGoal != true || g == null || goalValue == null) return false;
    return g.target == goalValue &&
        (g.kind == engine.GoalKind.distance) == goalIsDistance;
  }
}

/// The number to beat for a [NextSession] and the line that explains it.
class NextBeat {
  const NextBeat({required this.value, required this.line});
  final String value;
  final String line;
}

/// Judged on the metric the session itself is judged on, from the last
/// comparable run of that same session; null means "set your line".
NextBeat? nextBeat(NextSession next, List<RunSummary> runs, Units units) {
  final valid = runs.where((r) => !r.missing && next.matches(r)).toList()
    ..sort((a, b) => b.start.compareTo(a.start));
  // metric: lower is better, in seconds (pace in s/km); null = not usable.
  double? metric(RunSummary r) => switch (next.kind) {
    NextKind.interval => r.eligibleAsPrior ? r.workPaceSecPerKm : null,
    NextKind.free => r.distanceM >= 1000 ? r.avgSecPerKm : null,
    NextKind.bronco => r.durationMs > 0 ? r.durationMs / 1000 : null,
    NextKind.goal => _goalSeconds(r, next),
    _ => null,
  };
  final usable = valid.where((r) {
    if (next.kind == NextKind.cooper) return r.cooper?.valid ?? false;
    if (next.kind == NextKind.laps || next.kind == NextKind.fartlek) {
      return r.distanceM > 0;
    }
    if (next.kind == NextKind.goal && !next.isEvent) return _goalShown(r);
    return metric(r) != null;
  }).toList();
  if (usable.isEmpty) return null;
  final last = usable.first;
  final date = Fmt.dayDate(last.start);
  final (value, what) = switch (next.kind) {
    NextKind.interval => (
      Fmt.pace(last.workPaceSecPerKm, units),
      'Your last ${next.name} work pace, $date.',
    ),
    NextKind.free => (
      Fmt.pace(last.avgSecPerKm, units),
      'Your last free run, ${Fmt.distance(last.distanceM, units)}, $date.',
    ),
    // A fair average lap needs per-lap data the index lacks, so Laps and
    // Fartlek show the last run's distance until lap times land.
    NextKind.laps || NextKind.fartlek => (
      Fmt.distance(last.distanceM, units),
      'Your last ${next.name}, $date. Lap times come in a later update.',
    ),
    NextKind.bronco => (
      Fmt.clock(last.durationMs),
      'Your last Bronco test time, $date.',
    ),
    NextKind.cooper => (
      Fmt.distance(last.cooper!.testDistanceM, units),
      'Your last 12-minute test distance, $date.',
    ),
    _ => (
      next.isEvent ? Fmt.clock(last.durationMs) : _goalValue(last, units),
      'Your last ${next.name}, $date.',
    ),
  };
  var line = what;
  // Free pace only compares runs of a similar length (within 15%).
  final prev = usable
      .skip(1)
      .where(
        (r) =>
            next.kind != NextKind.free ||
            (r.distanceM - last.distanceM).abs() <= last.distanceM * 0.15,
      )
      .firstOrNull;
  final a = metric(last), b = prev == null ? null : metric(prev);
  if (a != null && b != null) {
    final isPace = next.kind == NextKind.interval || next.kind == NextKind.free;
    final d = isPace ? Fmt.deltaSecondsVsLast(a, b, units) : (a - b).round();
    line += d == 0
        ? ' Level with the run before.'
        : ' ${d.abs()} s ${d < 0 ? 'faster' : 'slower'} than the run before.';
  }
  return NextBeat(value: value, line: line);
}

/// True when a run of this session exists but cannot set a line.
bool hasUnusableRun(NextSession next, List<RunSummary> runs) =>
    runs.any((r) => !r.missing && next.matches(r));

bool _goalShown(RunSummary r) {
  final g = r.row?.goal ?? r.analysis?.goal;
  return g != null &&
      g.reached &&
      (g.kind == engine.GoalKind.distance
          ? g.goalMs != null
          : g.goalDistanceM != null);
}

double? _goalSeconds(RunSummary r, NextSession next) {
  if (next.isEvent) return r.durationMs > 0 ? r.durationMs / 1000 : null;
  final g = r.row?.goal ?? r.analysis?.goal;
  if (g == null || !g.reached) return null;
  return g.kind == engine.GoalKind.distance && g.goalMs != null
      ? g.goalMs! / 1000
      : null;
}

String _goalValue(RunSummary r, Units units) {
  final g = (r.row?.goal ?? r.analysis?.goal)!;
  return g.kind == engine.GoalKind.distance
      ? Fmt.clock(g.goalMs!)
      : Fmt.distance(g.goalDistanceM!, units);
}
