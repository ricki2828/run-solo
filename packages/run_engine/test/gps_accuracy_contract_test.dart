import 'dart:io';

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The engine treats a sample with accuracy worse than
/// [EngineConstants.noFixAccuracyM] as no fix, because the recorder's
/// PointFilter rejected it and froze the distance. The two values must not
/// drift apart: this reads the Kotlin source.
void main() {
  test('noFixAccuracyM equals Kotlin PointFilter.maxAccuracyM', () {
    final kt = File(
      '../../android/core-jvm/src/commonMain/kotlin/app/runsolo/core/gps/'
      'PointFilter.kt',
    );
    expect(kt.existsSync(), isTrue, reason: 'Kotlin source moved: ${kt.path}');
    final m = RegExp(r'maxAccuracyM:\s*Double\s*=\s*([0-9.]+)')
        .firstMatch(kt.readAsStringSync());
    expect(m, isNotNull, reason: 'PointFilter.maxAccuracyM default not found');
    expect(EngineConstants.defaults.noFixAccuracyM, double.parse(m!.group(1)!));
  });
}
