import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/send_sheet.dart';
import 'package:run_solo/screens/settings_screen.dart';
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
    expect(find.text('Intervals.icu'), findsOneWidget);
    expect(find.text('Coming soon'), findsNWidgets(2));
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
    expect(find.text('Coming soon'), findsNWidgets(2));
    // Disabled rows cannot be switched on; nothing is on by default.
    expect(
      tester.widget<Switch>(switchFor('Health Connect')).onChanged,
      isNull,
    );
    expect(tester.widget<Switch>(switchFor('Intervals.icu')).onChanged, isNull);
    expect(services.settings.settings.autoSend, isEmpty);
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
