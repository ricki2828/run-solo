import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

/// Settings rows for "Move all runs (one file)" and "Import runs". The PNG
/// comes from CI like every golden (see screens_golden_test.dart).
void main() {
  testWidgets('settings: Move all runs (one file) and Import runs', (
    tester,
  ) async {
    expect(
      File('test/golden/goldens/settings_move_runs.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
      reason: 'golden settings_move_runs.png missing: commit it from CI',
    );
    await pumpApp(
      tester,
      fakeServices(settings: const AppSettings(onboardingDone: true)),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('Move all runs (one file)'));
    await Scrollable.ensureVisible(
      tester.element(find.text('Move all runs (one file)')),
      alignment: 0.3,
    );
    await pumpTimes(tester, 2);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_move_runs.png'),
    );
  });
}
