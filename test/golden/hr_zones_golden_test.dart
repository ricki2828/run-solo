import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/hr_zones_section.dart';

import '../helpers.dart';

/// Settings → Heart rate zones, one golden per method at 360 x 640. PNGs
/// come from the CI goldens artifact like the others.
void main() {
  const base = AppSettings(typedMaxHr: 188, restingHr: 54);
  final cases = {
    'percent': base,
    'reserve': base.copyWith(hrZoneMethod: engine.HrZoneMethod.reserve),
    'custom': base.copyWith(
      hrZoneMethod: engine.HrZoneMethod.custom,
      customZones: [108, 136, 149, 162, 176],
    ),
  };
  for (final e in cases.entries) {
    testWidgets('settings heart rate zones, ${e.key}, 360 x 640', (
      tester,
    ) async {
      final name = 'hr_zones_${e.key}_360x640';
      final file = File('test/golden/goldens/$name.png');
      expect(
        file.existsSync() || autoUpdateGoldenFiles,
        isTrue,
        reason: 'golden $name.png missing: commit it from the CI artifact',
      );
      await loadRunSoloFonts();
      tester.view.physicalSize = const Size(360 * 3, 640 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: runSoloTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.screenGutter,
              ),
              child: HrZonesSection(
                settings: e.value,
                now: now(),
                onChange: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
