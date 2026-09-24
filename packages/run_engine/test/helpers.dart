import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart';

const engine = RunEngine();
const generator = TraceGenerator();
final fixedNow = DateTime.utc(2026, 9, 24, 8);
const profile = UserProfile(age: 40);

class Fixture {
  Fixture(this.name, this.run, this.expected, this.raw);
  final String name;
  final RunFile run;
  final SyntheticExpectation expected;
  final Map<String, Object?> raw;
}

Directory get fixtureDir => Directory('test/fixtures/synthetic');

List<Fixture> loadFixtures() {
  final files = fixtureDir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      if (f.path.endsWith('.json')) loadFixture(f),
  ];
}

Fixture loadFixture(File f) {
  final raw = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
  return Fixture(
    raw['spec'] as String,
    RunFile.fromJson(raw['run'] as Map<String, Object?>),
    SyntheticExpectation.fromJson(raw['expected'] as Map<String, Object?>),
    raw,
  );
}

Fixture fixture(String name) =>
    loadFixture(File('${fixtureDir.path}/$name.json'));

SyntheticSpec spec(String name) =>
    SyntheticSpecs.all.firstWhere((s) => s.name == name);

/// A 4x4 run with the given per-rep paces (s/km) and recovery pace, manual
/// laps, optional HR; used to pin verdict copy to exact numbers.
RunFile runWithPaces(
  List<double> repPaces, {
  double recoveryPace = 370,
  bool hr = false,
  String id = '00000000-0000-4000-8000-0000000000aa',
  DateTime? start,
  Preset? preset,
}) {
  final s = SyntheticSpec(
    name: 'inline',
    id: id,
    start: start,
    preset: preset,
    lapStyle: LapStyle.manual,
    manualDelayMs: 0,
    hr: hr,
    segments: SyntheticSpecs.fourByFour(
      reps: repPaces.length,
      workSpeeds: repPaces.map((p) => 1000 / p).toList(),
      recoverySpeed: 1000 / recoveryPace,
    ),
  );
  return generator.generate(s).run;
}

PriorRun prior(
  String id,
  DateTime start,
  double pace, {
  double? fade,
  double? recovery,
  double? tiz,
  double? meanHr,
  double? hrFraction,
  double? mpb,
}) => PriorRun(
  id: id,
  start: start,
  avgWorkPaceSecPerKm: pace,
  fadeSecPerKm: fade,
  recoveryPaceSecPerKm: recovery,
  timeInZoneSeconds: tiz,
  meanWorkHr: meanHr,
  meanWorkHrFraction: hrFraction,
  metresPerBeat: mpb,
);
