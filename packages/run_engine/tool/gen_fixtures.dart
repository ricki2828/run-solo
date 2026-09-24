// Regenerates test/fixtures/synthetic/*.json from SyntheticSpecs.all.
// Run from packages/run_engine: `dart run tool/gen_fixtures.dart`.
// The fixture drift test fails if a committed fixture no longer matches
// what the generator emits, so regenerate after any generator change.
import 'dart:convert';
import 'dart:io';

import 'package:run_engine/testing.dart';

void main() {
  final dir = Directory('test/fixtures/synthetic');
  dir.createSync(recursive: true);
  const gen = TraceGenerator();
  for (final spec in SyntheticSpecs.all) {
    final result = gen.generate(spec);
    final file = File('${dir.path}/${spec.name}.json');
    file.writeAsStringSync(fixtureJson(result));
    stdout.writeln('wrote ${file.path} (${file.lengthSync()} bytes)');
  }
}

/// One document per fixture: the run file as the app would store it, the
/// analytic expectation, and the spec name that produced it.
String fixtureJson(SyntheticRun result) => jsonEncode({
  'spec': result.spec.name,
  'run': result.run.toJson(),
  'expected': result.expected.toJson(),
});
