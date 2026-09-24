import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

void main() {
  test('engine version is pinned', () {
    expect(engineVersion, 1);
  });

  test('exactly two run modes exist in v1', () {
    expect(RunMode.values, [RunMode.fourByFour, RunMode.free]);
  });
}
