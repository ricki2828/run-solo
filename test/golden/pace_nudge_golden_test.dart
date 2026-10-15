import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/target_pace.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';
import '../widgets/pace_nudge_line_test.dart' show easyRuns, host, testPaces;

/// The Home nudge, and the Start card's pace lines (a VO2 set in the heat, a
/// trail run by effort), as CI renders them.
void main() {
  testWidgets('pace nudge 360x640', (tester) async {
    await pumpApp(
      tester,
      fakeServices(runs: easyRuns()),
      home: host(easyRuns()),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 4);
    expect(tester.takeException(), isNull);
    const name = 'pace_nudge_360x640';
    expect(
      File('test/golden/goldens/$name.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  });

  testWidgets('start pace lines 360x640', (tester) async {
    final vo2 = testPaces[engine.PaceIntensity.vo2max]!;
    final hot = engine.TargetPaces.adjust(vo2, tempC: 31, dewPointC: 22);
    final line = TargetPaceText.sessionLine(
      hot,
      Units.km,
      verb: 'Work reps at',
      source: 'From your 5K on Sat 12 Sep',
    );
    final steep = TargetPaceText.sessionLine(
      engine.TargetPaces.adjust(vo2, gradePct: 12),
      Units.km,
      verb: 'Work reps at',
    );
    await pumpApp(
      tester,
      fakeServices(),
      home: Builder(
        builder: (context) {
          final t = Theme.of(context).extension<RunSoloTokens>()!;
          return Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line,
                    style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    steep,
                    style: RunSoloType.body15.copyWith(color: t.inkPrimary),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 4);
    expect(tester.takeException(), isNull);
    const name = 'pace_start_lines_360x640';
    expect(
      File('test/golden/goldens/$name.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  });
}
