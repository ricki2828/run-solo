import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/topo/pack_models.dart';

import '../helpers.dart';
import '../topo/scripted_pack_manager.dart';

/// Settings > Offline maps states. PNGs come from CI like every golden (see
/// screens_golden_test.dart).
Future<void> golden(WidgetTester tester, String name) async {
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens artifact',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  final milos = fixtureRegion('milos', 'Milos, Greece', 3122553);
  final umbria = fixtureRegion('umbria', 'Umbria, Italy', 79400000);
  final sg = fixtureRegion('sg', 'Singapore', 16500000);

  Future<void> shot(
    WidgetTester tester,
    ScriptedPackManager m,
    String name,
  ) async {
    await pumpApp(tester, fakeServices(topo: m), pushRoute: Routes.offlineMaps);
    await pumpTimes(tester, 3);
    await golden(tester, name);
  }

  testWidgets('offline maps: no list yet', (tester) async {
    await shot(tester, ScriptedPackManager(), 'offline_maps_empty');
  });

  testWidgets('offline maps: installed, downloading, available', (
    tester,
  ) async {
    await shot(
      tester,
      ScriptedPackManager(
        scriptedRegions: [milos, umbria, sg],
        used: 3122553 + 33348000,
        statuses: {
          'milos': const PackStatus(PackStatusKind.installed),
          'umbria': PackStatus(
            PackStatusKind.downloading,
            doneBytes: 33348000,
            totalBytes: umbria.totalBytes,
          ),
        },
      ),
      'offline_maps_list',
    );
  });

  testWidgets('offline maps: update, failed, resume', (tester) async {
    await shot(
      tester,
      ScriptedPackManager(
        scriptedRegions: [milos, umbria, sg],
        used: 3122553 + 40000000 + 5000000,
        statuses: {
          'milos': PackStatus(
            PackStatusKind.updateAvailable,
            totalBytes: milos.totalBytes,
          ),
          'umbria': const PackStatus(
            PackStatusKind.failed,
            partialBytes: 40000000,
            error: PackException(
              PackErrorKind.offline,
              'The download stopped early. Tap to resume.',
            ),
          ),
          'sg': const PackStatus(
            PackStatusKind.notInstalled,
            partialBytes: 5000000,
          ),
        },
      ),
      'offline_maps_attention',
    );
  });

  testWidgets('offline maps: low storage', (tester) async {
    await shot(
      tester,
      ScriptedPackManager(
        scriptedRegions: [milos, umbria],
        used: 990000000,
        capBytes: 1000000000,
        statuses: {'milos': const PackStatus(PackStatusKind.installed)},
      ),
      'offline_maps_low_storage',
    );
  });
}
