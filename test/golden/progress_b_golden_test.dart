import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/progress_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';

import '../helpers.dart';

/// Direction B "Your pack" Progress tab at day 1, week 2 and month 3.
void main() {
  for (final stage in ['day1', 'week2', 'month3']) {
    testWidgets('progress B $stage 360x800', (tester) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: ProgressScreen(snapshot: ProgressSnapshot.sample(stage)),
      );
      tester.view.physicalSize = const Size(1080, 800 * 3);
      await pumpTimes(tester, 8);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('pack-panel')), findsOneWidget);
      if (stage == 'day1') {
        expect(find.byKey(const ValueKey('pack-empty')), findsOneWidget);
      } else {
        expect(find.byKey(const ValueKey('pack-histogram')), findsOneWidget);
        expect(find.byKey(const ValueKey('pack-table')), findsOneWidget);
      }
      final name = 'progress_b_${stage}_360x800';
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
}
