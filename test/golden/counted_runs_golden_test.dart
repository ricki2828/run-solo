import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/counted_runs_screen.dart';

import '../helpers.dart';
import '../screens/counted_runs_fixtures.dart';

void main() {
  testWidgets('counted runs 360x800', (tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: CountedRunsScreen(candidates: countedFixtures(), units: Units.km),
    );
    tester.view.physicalSize = const Size(1080, 2400);
    await pumpTimes(tester, 6);
    expect(tester.takeException(), isNull);
    expect(
      File('test/golden/goldens/counted_runs_360x800.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/counted_runs_360x800.png'),
    );
  });
}
