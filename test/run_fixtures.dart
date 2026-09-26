/// Run files for widget tests, produced by the engine's synthetic trace
/// generator so the verdict states come from the real engine path, not
/// hand-written analyses.
library;

import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;

const generator = synth.TraceGenerator();

String runId(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// Work speed for a "m:ss/km" pace.
double speedFor(int secPerKm) => 1000 / secPerKm;

engine.RunFile fourByFourFile({
  required int n,
  required DateTime start,
  int workSecPerKm = 284,
  List<double>? workSpeeds,
  bool hr = true,
  bool missedPress = false,
  bool indoor = false,
  engine.Preset? preset,
}) => fourByFourSynthetic(
  n: n,
  start: start,
  workSecPerKm: workSecPerKm,
  workSpeeds: workSpeeds,
  hr: hr,
  missedPress: missedPress,
  indoor: indoor,
  preset: preset,
).run;

/// The full synthetic run, with the generator's analytic expectation
/// (rescue edits for the missed-press case, expected paces).
synth.SyntheticRun fourByFourSynthetic({
  required int n,
  required DateTime start,
  int workSecPerKm = 284,
  List<double>? workSpeeds,
  bool hr = true,
  bool missedPress = false,
  bool indoor = false,
  engine.Preset? preset,
}) => generator.generate(
  synth.SyntheticSpec(
    name: 'fixture_4x4_$n',
    id: runId(n),
    lapStyle: preset == null ? synth.LapStyle.manual : synth.LapStyle.auto,
    preset: preset,
    hr: hr,
    indoor: indoor,
    start: start,
    missedBoundaries: missedPress ? const {3} : const {},
    segments: synth.SyntheticSpecs.fourByFour(
      workSpeeds:
          workSpeeds ??
          [
            speedFor(workSecPerKm - 2),
            speedFor(workSecPerKm - 1),
            speedFor(workSecPerKm + 1),
            speedFor(workSecPerKm + 3),
          ],
    ),
  ),
);

engine.RunFile freeRunFile({
  required int n,
  required DateTime start,
  bool hr = true,
  int seconds = 1800,
}) => generator
    .generate(
      synth.SyntheticSpec(
        name: 'fixture_free_$n',
        id: runId(n),
        mode: engine.RunMode.free,
        lapStyle: synth.LapStyle.none,
        hr: hr,
        start: start,
        segments: [synth.Segment.free(seconds, speedFor(360))],
      ),
    )
    .run;

/// Four manual laps of varying pace, no phases (plan §18.2 Laps run).
engine.RunFile lapsRunFile({
  required int n,
  required DateTime start,
  bool hr = true,
}) => generator
    .generate(
      synth.SyntheticSpec(
        name: 'fixture_laps_$n',
        id: runId(n),
        mode: engine.RunMode.laps,
        lapStyle: synth.LapStyle.manual,
        hr: hr,
        start: start,
        segments: [
          synth.Segment.free(300, speedFor(330)),
          synth.Segment.free(300, speedFor(300)),
          synth.Segment.free(300, speedFor(310)),
          synth.Segment.free(300, speedFor(340)),
        ],
      ),
    )
    .run;

/// Event run ids differ in their first 8 hex digits, as real uuids do: a
/// new course takes its id from them (`ParkrunCourses.newCourseId`).
String eventRunId(int n) =>
    '${(0xa0000000 + n).toRadixString(16)}-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// K1: a timed 5 km (the event session) at [mps] after a 10 min warm-up LAP,
/// starting [latShiftDeg] north of the generator's start line (0.002° ≈
/// 220 m, another course).
engine.RunFile eventRunFile({
  required int n,
  required DateTime start,
  required String eventName,
  double mps = 3.5,
  double latShiftDeg = 0,
  bool indoor = false,
}) {
  final run = generator
      .generate(
        synth.SyntheticSpec(
          name: 'event_$n',
          id: eventRunId(n),
          session: engine.SessionSpec.parkrun(eventName),
          segments: [
            synth.Segment.warmup(600, 2.8),
            synth.Segment.work((5000 / mps).round(), mps),
          ],
          hr: true,
          indoor: indoor,
          start: start,
        ),
      )
      .run;
  if (latShiftDeg == 0) return run;
  return run.copyWith(
    samples: [
      for (final s in run.samples)
        s.copyWith(lat: s.lat == null ? null : s.lat! + latShiftDeg),
    ],
  );
}
