import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/health_gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/send_sheet.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/send_runs.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Send runs: the Send sheet on run detail and the Settings section.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);

  Future<FakeTransferGateway> openSheet(WidgetTester tester) async {
    final r = fourByFourFile(n: 1, start: d1);
    final transfer = FakeTransferGateway();
    await pumpApp(
      tester,
      fakeServices(files: [r], transfer: transfer),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    await scrollTo(tester, find.text('Send'));
    await tester.tap(find.text('Send'));
    await settleAnimations(tester);
    return transfer;
  }

  /// Real file I/O (temp dir) needs real async time: wait for the share
  /// itself, not a fixed delay (see settings_screen_test, #30).
  Future<void> tapAndWaitShare(
    WidgetTester tester,
    FakeTransferGateway transfer,
    String key,
  ) async {
    await tester.runAsync(() async {
      final shared = transfer.nextShare();
      await tester.tap(find.byKey(ValueKey(key)));
      await shared.timeout(const Duration(seconds: 20));
    });
    await settleAnimations(tester);
  }

  Finder switchFor(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
    matching: find.byType(Switch),
  );

  testWidgets('sheet lists every target and the privacy line', (tester) async {
    await openSheet(tester);
    expect(find.text('SEND THIS RUN'), findsOneWidget);
    expect(find.text(kSendPrivacyLine), findsOneWidget);
    expect(find.text('Share file'), findsOneWidget);
    expect(find.text('TCX file'), findsOneWidget);
    expect(find.text('GPX file'), findsOneWidget);
    expect(find.text('Strava'), findsOneWidget);
    expect(find.text(kStravaLine), findsOneWidget);
    expect(find.text('Health Connect'), findsOneWidget);
    expect(find.text('Send to Health Connect'), findsOneWidget);
    expect(find.text('Intervals.icu'), findsOneWidget);
    expect(find.text('Coming soon'), findsNothing);
    expect(find.textContaining('Compatible with'), findsNothing);
  });

  testWidgets('TCX file shares a .tcx and logs it on run detail', (
    tester,
  ) async {
    final transfer = await openSheet(tester);
    await tapAndWaitShare(tester, transfer, 'send-tcx');
    expect(transfer.shared.single.single, endsWith('.tcx'));
    expect(transfer.shared.single.single, contains('Run Supreme - '));
    expect(transfer.opened, isEmpty);
    expect(find.byType(SendSheet), findsNothing);
    await scrollTo(tester, find.text('Send'));
    expect(find.textContaining('Shared '), findsOneWidget);
  });

  testWidgets('GPX file shares a .gpx', (tester) async {
    final transfer = await openSheet(tester);
    await tapAndWaitShare(tester, transfer, 'send-gpx');
    expect(transfer.shared.single.single, endsWith('.gpx'));
  });

  testWidgets('Strava shares the file, then opens the upload page', (
    tester,
  ) async {
    final transfer = await openSheet(tester);
    await tapAndWaitShare(tester, transfer, 'send-strava');
    expect(transfer.shared.single.single, endsWith('.tcx'));
    expect(transfer.opened.single.toString(), kStravaUploadUrl);
  });

  testWidgets('a share sheet that fails shows a line, opens nothing', (
    tester,
  ) async {
    final transfer = await openSheet(tester);
    transfer.failShare = true;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('send-strava')));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.byKey(const ValueKey('send-error')).evaluate().isNotEmpty) {
          break;
        }
      }
    });
    expect(find.byKey(const ValueKey('send-error')), findsOneWidget);
    expect(transfer.opened, isEmpty);
    expect(find.byType(SendSheet), findsOneWidget);
  });

  testWidgets('Settings: Send runs to, share file manual, others coming soon', (
    tester,
  ) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    expect(find.text(kSendPrivacyLine), findsOneWidget);
    expect(find.text('Share file'), findsOneWidget);
    expect(find.text('Only when you tap Send on a run.'), findsOneWidget);
    expect(find.text('Health Connect'), findsOneWidget);
    expect(find.text('Intervals.icu'), findsOneWidget);
    expect(find.text('Coming soon'), findsNothing);
    // Health starts off; Intervals needs a key before it can be switched on.
    expect(tester.widget<Switch>(switchFor('Health Connect')).value, isFalse);
    expect(tester.widget<Switch>(switchFor('Intervals.icu')).value, isFalse);
    expect(find.text('Not connected'), findsOneWidget);
    expect(services.settings.settings.autoSend, isEmpty);
  });

  testWidgets('Settings: Health Connect on asks for access, then persists', (
    tester,
  ) async {
    final health = FakeHealthGateway(coreGranted: false, routeGranted: false);
    final services = fakeServices(health: health);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    await tester.tap(switchFor('Health Connect'));
    await pumpTimes(tester, 4);
    expect(health.requests, [false, true]);
    expect(services.settings.settings.autoSend, {'health'});
    expect(services.settings.settings.autoSendSince['health'], isNotNull);
  });

  testWidgets('Settings: access refused keeps it off and says why', (
    tester,
  ) async {
    final health = FakeHealthGateway(
      coreGranted: false,
      grantCoreOnRequest: false,
    );
    final services = fakeServices(health: health);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    await tester.tap(switchFor('Health Connect'));
    await pumpTimes(tester, 4);
    expect(services.settings.settings.autoSend, isEmpty);
    expect(find.textContaining('Allow Run Supreme to write'), findsOneWidget);
  });

  testWidgets('Settings: Health Connect missing offers the Play Store', (
    tester,
  ) async {
    final health = FakeHealthGateway(
      availability: HealthAvailability.notInstalled,
      coreGranted: false,
    );
    final services = fakeServices(health: health);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    await tester.tap(switchFor('Health Connect'));
    await pumpTimes(tester, 4);
    expect(find.text('Health Connect is not installed.'), findsOneWidget);
    await scrollTo(tester, find.text('Open the Play Store'));
    await tester.tap(find.text('Open the Play Store'));
    await pumpTimes(tester, 2);
    expect(health.installOpened, 1);
    expect(services.settings.settings.autoSend, isEmpty);
  });

  testWidgets('Send sheet: Send to Health Connect writes the run', (
    tester,
  ) async {
    final health = FakeHealthGateway();
    final r = fourByFourFile(n: 1, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r], health: health),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    await scrollTo(tester, find.text('Send'));
    await tester.tap(find.text('Send'));
    await settleAnimations(tester);
    await tester.tap(find.byKey(const ValueKey('send-health')));
    await pumpTimes(tester, 8);
    await settleAnimations(tester);
    expect(health.written.single.clientRecordId, r.id);
    expect(find.byType(SendSheet), findsNothing);
    await scrollTo(tester, find.text('Send'));
    expect(find.textContaining('Sent '), findsOneWidget);
  });

  testWidgets('Settings: a live automatic target toggles and persists', (
    tester,
  ) async {
    final live = _LiveTarget();
    final services = fakeServices(exportTargets: [live]);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    expect(find.text('Sends each run when it finishes.'), findsOneWidget);
    await tester.tap(switchFor('Live service'));
    await pumpTimes(tester, 2);
    expect(services.settings.settings.autoSend, {'live'});
    await tester.tap(switchFor('Live service'));
    await pumpTimes(tester, 2);
    expect(services.settings.settings.autoSend, isEmpty);
  });
  testWidgets('Settings: Intervals.icu switch asks for a key, then connects, '
      'tests and disconnects', (tester) async {
    final store = MemorySecretStore();
    final http = _OkHttp();
    final target = IntervalsIcuTarget(store: store, http: http);
    final services = fakeServices(exportTargets: [target]);
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    expect(find.text('Not connected'), findsOneWidget);

    // Switching on with no key opens the Connect sheet and stays off.
    await tester.tap(switchFor('Intervals.icu'));
    await settleAnimations(tester);
    expect(find.text('CONNECT INTERVALS.ICU'), findsOneWidget);
    expect(find.textContaining('Developer settings'), findsOneWidget);
    expect(services.settings.settings.autoSend, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('intervals-key')), 'k3y');
    await tester.enterText(
      find.byKey(const ValueKey('intervals-athlete')),
      'i99',
    );
    await tester.tap(find.byKey(const ValueKey('intervals-test')));
    await pumpTimes(tester, 4);
    expect(find.text('Connected'), findsOneWidget);
    expect(store.values, isEmpty, reason: 'testing does not save');

    await tester.tap(find.byKey(const ValueKey('intervals-save')));
    await settleAnimations(tester);
    expect(store.values[IntervalsIcuTarget.keyName], 'k3y');
    expect(store.values[IntervalsIcuTarget.athleteName], 'i99');
    expect(services.settings.settings.autoSend, {IntervalsIcuTarget.targetId});
    expect(find.text('Connected'), findsOneWidget);

    // Disconnect removes the key and switches automatic sending off.
    await tester.tap(find.text('Manage connection'));
    await settleAnimations(tester);
    await tester.tap(find.byKey(const ValueKey('intervals-disconnect')));
    await settleAnimations(tester);
    expect(store.values, isEmpty);
    expect(services.settings.settings.autoSend, isEmpty);
    expect(find.text('Not connected'), findsOneWidget);
  });
}

class _OkHttp implements IntervalsHttp {
  @override
  Future<IntervalsResponse> send(IntervalsRequest req) async =>
      const IntervalsResponse(200, '{}');
}

class _LiveTarget extends ExportTarget {
  @override
  String get id => 'live';
  @override
  String get label => 'Live service';
  @override
  String get blurb => '';
  @override
  bool get supportsAutomatic => true;
  @override
  Future<SendResult> send(SendRequest req) async => const SendResult.ok();
}
