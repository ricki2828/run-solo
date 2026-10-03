/// Run files for widget tests, produced by the engine's synthetic trace
/// generator so the verdict states come from the real engine path, not
/// hand-written analyses.
library;

import 'dart:math' as math;

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
  int secPerKm = 360,
}) => generator
    .generate(
      synth.SyntheticSpec(
        name: 'fixture_free_$n',
        id: runId(n),
        mode: engine.RunMode.free,
        lapStyle: synth.LapStyle.none,
        hr: hr,
        start: start,
        segments: [synth.Segment.free(seconds, speedFor(secPerKm))],
      ),
    )
    .run;

/// [run] with the phone's fused elevation on every sample: a gentle rise
/// with a rolling swell (about 36 m up and down per 2.8 km), so it books
/// climb, descent and a spread of grades.
engine.RunFile withElevation(
  engine.RunFile run, {
  engine.ElevSource src = engine.ElevSource.baro,
}) => run.copyWith(
  samples: [
    for (final s in run.samples)
      s.copyWith(elevM: 40 + 0.004 * s.distM + 18 * math.sin(s.distM / 450)),
  ],
  elevSrc: src,
);

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

/// Bronco (manual sets, founder 28-Sep): a Laps run carrying the bronco
/// session, 5 manual taps - one per 240 m set, each a touch quicker.
engine.RunFile broncoRunFile({required int n, required DateTime start}) =>
    generator
        .generate(
          synth.SyntheticSpec(
            name: 'fixture_bronco_$n',
            id: runId(n),
            mode: engine.RunMode.laps,
            session: engine.SessionSpec.bronco,
            lapStyle: synth.LapStyle.manual,
            start: start,
            segments: [
              synth.Segment.free(295, speedFor(295)),
              synth.Segment.free(290, speedFor(290)),
              synth.Segment.free(288, speedFor(288)),
              synth.Segment.free(285, speedFor(285)),
              synth.Segment.free(282, speedFor(282)),
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

/// A 12-minute test (C1): a warm-up ended by "Start reps", the recorder's
/// own 12:00 lap at [mps], then a cool-down. [pausedAtS] pauses 20 s inside
/// the test (no estimate). Hand-built so the minute marks are exact.
engine.RunFile cooperTestFile({
  required int n,
  required DateTime start,
  double mps = 4,
  int warmupS = 300,
  int cooldownS = 120,
  int? pausedAtS,
  bool hr = true,
}) {
  const testS = 720;
  final total = warmupS + testS + cooldownS;
  double dAt(int s) => s <= warmupS
      ? 2.5 * s
      : s <= warmupS + testS
      ? 2.5 * warmupS + mps * (s - warmupS)
      : 2.5 * warmupS + mps * testS + 2.2 * (s - warmupS - testS);
  // Due north: 1 m is about 8.99e-6 degrees of latitude.
  final samples = [
    for (var s = 0; s <= total; s++)
      engine.Sample(
        tMs: s * 1000,
        lat: -33.9 + dAt(s) * 8.99e-6,
        lon: 151.2,
        accM: 5,
        distM: dAt(s),
        hr: hr ? (s <= warmupS ? 135 : 172) : null,
      ),
  ];
  final testEnd = (warmupS + testS) * 1000;
  return engine.RunFile(
    id: runId(n),
    device: 'test',
    app: 'test',
    start: start,
    end: start.add(Duration(seconds: total)),
    tz: 'UTC',
    mode: engine.RunMode.cooper,
    session: engine.SessionSpec.cooper,
    units: engine.Units.km,
    laps: [
      engine.Lap(
        index: 0,
        t0Ms: 0,
        t1Ms: warmupS * 1000,
        d0M: 0,
        d1M: dAt(warmupS),
        kind: engine.LapKind.manual,
      ),
      engine.Lap(
        index: 1,
        t0Ms: warmupS * 1000,
        t1Ms: testEnd,
        d0M: dAt(warmupS),
        d1M: dAt(warmupS + testS),
        kind: engine.LapKind.auto,
      ),
    ],
    pauses: [
      if (pausedAtS != null)
        engine.Span(
          (warmupS + pausedAtS) * 1000,
          (warmupS + pausedAtS + 20) * 1000,
        ),
    ],
    samples: samples,
  );
}

/// A Trail run once round a lopsided loop (about 6 km at [secPerKm] a km,
/// with the phone's barometer climb) starting at the same place every time,
/// so two of them are the same trail. [reverse] runs it the other way,
/// [dLat] moves it 111 m per 0.001 degree north (a different trail), [noiseM]
/// wobbles the fixes, [climbAmpM] sets how hilly it is.
engine.RunFile trailLoopRun({
  required int n,
  required DateTime start,
  int secPerKm = 400,
  bool reverse = false,
  double dLat = 0,
  double noiseM = 4,
  double climbAmpM = 18,
}) {
  const km = 6;
  final base = freeRunFile(
    n: n,
    start: start,
    seconds: secPerKm * km,
    secPerKm: secPerKm,
  );
  final rnd = math.Random(n);
  const lat0 = 37.4, lon0 = 24.9, mPerDeg = 111194.9;
  final kx = math.cos(lat0 * math.pi / 180) * mPerDeg;
  final scale = base.distanceM / 2200;
  final total = base.distanceM;
  return base.copyWith(
    mode: engine.RunMode.trail,
    elevSrc: engine.ElevSource.baro,
    samples: [
      for (final s in base.samples)
        () {
          var f = s.distM / total;
          if (reverse) f = 1 - f;
          final th = f * 2 * math.pi;
          final r = (300 + 110 * math.cos(2 * th) + 70 * math.sin(th)) * scale;
          final x = r * math.cos(th) + (rnd.nextDouble() - 0.5) * 2 * noiseM;
          final y = r * math.sin(th) + (rnd.nextDouble() - 0.5) * 2 * noiseM;
          return s.copyWith(
            lat: lat0 + dLat + y / mPerDeg,
            lon: lon0 + x / kx,
            elevM: 40 + climbAmpM * math.sin(s.distM / 150),
          );
        }(),
    ],
  );
}
