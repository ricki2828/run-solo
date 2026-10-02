/// Trail runs as the same-trail verdict and the trail boards read them:
/// index-row fields only (route, moving time, climb, effort pace), never a
/// run file. The matching and the wording live in the engine
/// (`route_match.dart`, `trail_verdict.dart`).
library;

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'history_store.dart';

/// [r] as a Trail run's facts, or null when it is not a Trail run.
engine.TrailRunFacts? trailFactsOf(RunSummary r) {
  if (r.mode != RecordMode.trail || r.missing) return null;
  final row = r.row;
  return engine.TrailRunFacts(
    id: r.id,
    start: r.localStart,
    movingMs: row?.movingMs ?? r.durationMs,
    distanceM: r.distanceM,
    climbM: row?.climbM,
    gapSecPerKm: row?.gapSecPerKm,
    route: row?.route,
    place: r.place,
    street: r.street,
  );
}

/// Every Trail run in [all], as facts.
List<engine.TrailRunFacts> trailFactsOfAll(Iterable<RunSummary> all) => [
  for (final r in all) ?trailFactsOf(r),
];

/// The trails with two or more runs, newest-run first: what the boards show.
List<engine.TrailGroup> trailBoards(Iterable<RunSummary> all) {
  final groups = engine.Trails.group(trailFactsOfAll(all))
    ..removeWhere((g) => g.runs.length < 2);
  groups.sort((a, b) => b.runs.last.start.compareTo(a.runs.last.start));
  return groups;
}

/// The facts of the run on screen: its index row when it has one (the same
/// figures the boards read), else straight from the run file (the in-memory
/// test store has no row).
engine.TrailRunFacts trailFactsOfDetail(RunDetail d) {
  if (d.summary.row != null) {
    return trailFactsOf(d.summary) ?? _fromFile(d);
  }
  return _fromFile(d);
}

engine.TrailRunFacts _fromFile(RunDetail d) {
  final elev = engine.RunElevation.of(d.run);
  return engine.TrailRunFacts(
    id: d.run.id,
    start: d.summary.localStart,
    movingMs: engine.RunTimes.movingMs(d.run),
    distanceM: d.summary.distanceM,
    climbM: elev?.ascentM,
    gapSecPerKm: elev?.gapSecPerKm,
    route: engine.RouteSignature.of(d.run),
    place: d.summary.place,
    street: d.summary.street,
  );
}
