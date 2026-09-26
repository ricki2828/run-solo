import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test('engine version is pinned', () {
    expect(engineVersion, 4);
  });

  test('run modes are pinned in Pigeon/core-jvm order (§18.2, §18.4)', () {
    expect(RunMode.values, [
      RunMode.intervals,
      RunMode.laps,
      RunMode.free,
      RunMode.cooper,
    ]);
  });

  test('run file and sidecar write schema 3 and read from 1', () {
    expect(RunFile.schema, 3);
    expect(RunFile.minReadSchema, 1);
    expect(RunSidecar.schema, 3);
    expect(RunSidecar.minReadSchema, 1);
  });
}
