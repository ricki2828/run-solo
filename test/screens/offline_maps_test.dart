import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/offline_maps_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/topo/pack_manager.dart';
import 'package:run_solo/topo/pack_models.dart';

import '../helpers.dart';
import '../topo/fake_pack_server.dart';
import '../topo/scripted_pack_manager.dart';

/// Settings > Offline maps. Pack logic is in test/topo; here the screen's
/// states and taps.
void main() {
  final milos = fixtureRegion('milos', 'Milos, Greece', 3122553);
  final umbria = fixtureRegion('umbria', 'Umbria, Italy', 79400000);
  final sg = fixtureRegion('sg', 'Singapore', 16500000);

  Future<void> open(WidgetTester tester, ScriptedPackManager m) async {
    await pumpApp(tester, fakeServices(topo: m), pushRoute: Routes.offlineMaps);
    await pumpTimes(tester, 2);
  }

  String allText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  test('formatPackBytes', () {
    expect(formatPackBytes(512), '512 B');
    expect(formatPackBytes(3122553), '3.1 MB');
    expect(formatPackBytes(79400000), '79 MB');
    expect(formatPackBytes(1000000000), '1.0 GB');
    expect(formatPackBytes(999000000), '999 MB');
  });

  testWidgets('empty: no list yet, the only network call is a tap', (
    tester,
  ) async {
    final m = ScriptedPackManager();
    await open(tester, m);
    expect(find.byKey(const ValueKey('maps-empty')), findsOneWidget);
    expect(m.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('get-list')));
    await pumpTimes(tester, 2);
    expect(m.calls, ['refresh']);
  });

  testWidgets('list failed: reason and try again', (tester) async {
    final m = ScriptedPackManager();
    await pumpApp(tester, fakeServices(topo: m), pushRoute: Routes.offlineMaps);
    await pumpTimes(tester, 2);
    // A refresh that fails: the manager throws, the screen shows the reason.
    final failing = _FailingRefresh();
    await pumpApp(
      tester,
      fakeServices(topo: failing),
      pushRoute: Routes.offlineMaps,
    );
    await pumpTimes(tester, 2);
    await tester.tap(find.byKey(const ValueKey('get-list')));
    await pumpTimes(tester, 2);
    expect(find.text('Could not reach the map server.'), findsOneWidget);
    expect(
      find.text('SocketException: Failed host lookup'),
      findsOneWidget,
    );
    expect(find.text('TRY AGAIN'), findsOneWidget);
  });

  testWidgets('regions in every status, with taps', (tester) async {
    final m = ScriptedPackManager(
      scriptedRegions: [milos, umbria, sg],
      used: 3122553 + 33000000,
      statuses: {
        'milos': const PackStatus(PackStatusKind.installed),
        'umbria': PackStatus(
          PackStatusKind.downloading,
          doneBytes: 33348000,
          totalBytes: umbria.totalBytes,
        ),
      },
    );
    await open(tester, m);
    expect(find.text('Milos, Greece'), findsOneWidget);
    expect(find.text('Installed, 3.1 MB'), findsOneWidget);
    expect(find.text('42% of 79 MB'), findsOneWidget);
    expect(find.text('Singapore'), findsOneWidget);
    expect(find.text('Download on Wi-Fi only'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('get-sg')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('get-sg')));
    await tester.ensureVisible(find.byKey(const ValueKey('cancel-umbria')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cancel-umbria')));
    expect(m.calls, ['download:sg', 'cancel:umbria']);
  });

  testWidgets('delete asks first, keep leaves it', (tester) async {
    final m = ScriptedPackManager(
      scriptedRegions: [milos],
      used: 3122553,
      statuses: {'milos': const PackStatus(PackStatusKind.installed)},
    );
    await open(tester, m);
    await tester.tap(find.byKey(const ValueKey('delete-milos')));
    await pumpTimes(tester, 3);
    expect(find.text('DELETE MILOS, GREECE?'), findsOneWidget);
    expect(find.textContaining('frees 3.1 MB'), findsOneWidget);
    await tester.tap(find.text('KEEP'));
    await pumpTimes(tester, 3);
    expect(m.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('delete-milos')));
    await pumpTimes(tester, 3);
    await tester.tap(find.byKey(const ValueKey('confirm-delete')));
    await pumpTimes(tester, 3);
    expect(m.calls, ['delete:milos']);
  });

  testWidgets('update, failed and resume rows', (tester) async {
    final m = ScriptedPackManager(
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
    );
    await open(tester, m);
    expect(find.text('Update ready, 3.1 MB'), findsOneWidget);
    expect(find.text('UPDATE'), findsOneWidget);
    expect(
      find.text('The download stopped early. Tap to resume.'),
      findsOneWidget,
    );
    expect(find.text('TRY AGAIN'), findsOneWidget);
    expect(find.text('17 MB, 5.0 MB already downloaded'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
  });

  testWidgets('low storage: blocked with how much room, button disabled', (
    tester,
  ) async {
    final m = ScriptedPackManager(
      scriptedRegions: [milos, umbria],
      used: 990000000,
      capBytes: 1000000000,
      statuses: {'milos': const PackStatus(PackStatusKind.installed)},
    );
    await open(tester, m);
    expect(find.byKey(const ValueKey('storage-warning')), findsOneWidget);
    expect(find.byKey(const ValueKey('low-umbria')), findsOneWidget);
    expect(
      find.text('Needs 69 MB more room. Delete a map to make space.'),
      findsOneWidget,
    );
    final button = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byKey(const ValueKey('get-umbria')),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('get-umbria')));
    expect(m.calls, isEmpty);
  });

  testWidgets('wifi-only switch only when it can be enforced', (tester) async {
    final off = ScriptedPackManager(scriptedRegions: [milos], wifiProbe: false);
    await open(tester, off);
    expect(find.byKey(const ValueKey('wifi-only')), findsNothing);

    final on = ScriptedPackManager(scriptedRegions: [milos]);
    await open(tester, on);
    await tester.tap(find.byKey(const ValueKey('wifi-only')));
    await pumpTimes(tester, 2);
    expect(on.calls, ['wifi:false']);
  });

  testWidgets('credits sheet lists licences per pack', (tester) async {
    final m = ScriptedPackManager(scriptedRegions: [milos]);
    await open(tester, m);
    expect(
      find.text('© OpenStreetMap contributors | Protomaps | © Mapterhorn'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('credits-milos')));
    await tester.tap(find.byKey(const ValueKey('credits-milos')));
    await pumpTimes(tester, 3);
    expect(find.text('Licence: ODbL 1.0 (Produced Work)'), findsOneWidget);
    expect(find.text('https://mapterhorn.com/attribution'), findsOneWidget);
  });

  testWidgets('copy has no em or en dashes', (tester) async {
    final m = ScriptedPackManager(
      scriptedRegions: [milos, umbria, sg],
      used: 990000000,
      capBytes: 1000000000,
      statuses: {
        'milos': const PackStatus(PackStatusKind.installed),
        'umbria': const PackStatus(
          PackStatusKind.failed,
          error: PackException(PackErrorKind.offline, 'Stopped early.'),
        ),
      },
    );
    await open(tester, m);
    final text = allText(tester);
    expect(text, isNot(contains('—')));
    expect(text, isNot(contains('–')));
    final empty = ScriptedPackManager();
    await open(tester, empty);
    expect(allText(tester), isNot(contains('—')));
  });

  testWidgets('Settings: no row without hosting, row with summary and nav', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: SettingsScreen(now: now));
    await pumpTimes(tester, 3);
    expect(find.text('Offline maps'), findsNothing);

    final m = ScriptedPackManager(
      scriptedRegions: [milos],
      statuses: {'milos': const PackStatus(PackStatusKind.installed)},
    );
    await pumpApp(
      tester,
      fakeServices(topo: m),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 3);
    await tester.scrollUntilVisible(
      find.text('Offline maps'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Offline maps'));
    await tester.pump();
    expect(find.text('1 on phone'), findsOneWidget);
    await tester.tap(find.text('Offline maps'));
    await pumpTimes(tester, 4);
    expect(find.text('OFFLINE MAPS'), findsOneWidget);
    expect(find.text('Milos, Greece'), findsOneWidget);
  });

  testWidgets('end to end against a fake server: get list, download, delete', (
    tester,
  ) async {
    // The test binding swaps in a mock HttpClient that answers 400.
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    await tester.runAsync(() async {
      final server = await FakePackServer.start();
      final dir = Directory.systemTemp.createTempSync('runsolo-omaps-');
      addTearDown(() async {
        await server.close();
        dir.deleteSync(recursive: true);
      });
      server.setIndex([
        server.addPack('milos', name: 'Milos, Greece', bytes: 200000),
      ]);
      final m = PackManager(
        root: Directory('${dir.path}/topo'),
        baseUrl: server.base,
      );
      await m.load();
      await pumpApp(
        tester,
        fakeServices(topo: m),
        pushRoute: Routes.offlineMaps,
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(server.requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('get-list')));
      await _settle(tester, () => m.regions.isNotEmpty);
      expect(find.text('Milos, Greece'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('get-milos')));
      await _settle(
        tester,
        () => m.statusOf('milos').kind == PackStatusKind.installed,
      );
      expect(find.text('ON PHONE'), findsOneWidget);
      expect(m.packCovering(36.7, 24.4), isNotNull);

      await tester.tap(find.byKey(const ValueKey('delete-milos')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('confirm-delete')));
      await _settle(tester, () => m.installed.isEmpty);
      expect(m.usedBytes, 0);
    });
  });
}

/// Real IO needs real time: pump until the condition holds.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
  }
  expect(done(), isTrue);
  await tester.pump(const Duration(milliseconds: 50));
}

class _FailingRefresh extends ScriptedPackManager {
  @override
  Future<void> refreshRegions() async {
    throw const PackException(
      PackErrorKind.offline,
      'Could not reach the map server.',
      detail: 'SocketException: Failed host lookup',
    );
  }
}
