import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/recording_screen.dart';
import 'package:run_solo/screens/recovery_dialog.dart';

import '../helpers.dart';

OrphanJournal orphan({
  int ageMinutes = 13,
  bool readable = true,
  bool endedPaused = false,
}) => OrphanJournal(
  runId: 'orphan-1',
  lastLineAgeMs: ageMinutes * 60 * 1000,
  mode: RecordMode.fourByFour,
  readable: readable,
  newer: false,
  endedPaused: endedPaused,
  elapsedMs: 10 * 60 * 1000,
);

void main() {
  testWidgets('orphan on open: dialog names the mode and last-written time', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now, orphans: [orphan()]);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RecoveryDialog), findsOneWidget);
    expect(find.text('RECOVERED YOUR RUN'), findsOneWidget);
    expect(find.textContaining('4x4, 10:00 recorded'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    expect(find.text('RESUME'), findsOneWidget);
  });

  testWidgets('FINISH finalises the journal without resuming', (tester) async {
    final fake = FakeRecorderGateway(now: now, orphans: [orphan()]);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('FINISH'));
    await pumpTimes(tester, 6);
    await settleAnimations(tester);
    expect(find.byType(RecoveryDialog), findsNothing);
    expect(fake.orphans, isEmpty);
    expect(fake.finalised.single.runId, 'orphan-1');
    expect(fake.state, RecorderState.idle);
    expect(find.byType(RecordingScreen), findsNothing);
  });

  testWidgets('RESUME re-attaches and opens the record screen', (tester) async {
    final fake = FakeRecorderGateway(now: now, orphans: [orphan()]);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.widgetWithText(FilledButton, 'RESUME'));
    await pumpTimes(tester, 8);
    expect(fake.state, RecorderState.recording);
    expect(fake.orphans, isEmpty);
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.text('TOTAL 10:00'), findsOneWidget);
    expect(find.text('REP 1 OF 4'), findsOneWidget, reason: 'phase rebuilt');
  });

  testWidgets('older than 30 min: SAVE only, finalises', (tester) async {
    final fake = FakeRecorderGateway(
      now: now,
      orphans: [orphan(ageMinutes: 45)],
    );
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('RESUME'), findsNothing);
    expect(find.textContaining('Too long ago to resume'), findsOneWidget);
    await tester.tap(find.text('SAVE'));
    await pumpTimes(tester, 6);
    expect(fake.finalised.single.runId, 'orphan-1');
  });

  testWidgets('unreadable: DISCARD only, never finalised', (tester) async {
    final fake = FakeRecorderGateway(
      now: now,
      orphans: [orphan(readable: false)],
    );
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('UNREADABLE RUN'), findsOneWidget);
    expect(find.text('RESUME'), findsNothing);
    expect(find.text('FINISH'), findsNothing);
    await tester.tap(find.text('DISCARD'));
    await pumpTimes(tester, 6);
    expect(fake.discarded, ['orphan-1']);
    expect(fake.finalised, isEmpty);
    expect(fake.orphans, isEmpty);
  });

  testWidgets('a resume refused by the OS is reported, run kept', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now, orphans: [orphan()]);
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    fake.startError = StartError.fgsNotAllowed;
    await tester.tap(find.widgetWithText(FilledButton, 'RESUME'));
    await pumpTimes(tester, 8);
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.textContaining('would not restart recording'), findsOneWidget);
    expect(fake.finalised, isEmpty);
  });

  testWidgets('no orphan: no dialog', (tester) async {
    final services = fakeServices();
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RecoveryDialog), findsNothing);
  });

  testWidgets('a run still live in the service reopens the record screen', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    await fake.start(RecordMode.free, null, Units.km);
    fake.advance(const Duration(minutes: 7));
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 8);
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.text('TOTAL 7:00'), findsOneWidget);
  });

  testWidgets('paused-at-kill resumes paused', (tester) async {
    final fake = FakeRecorderGateway(
      now: now,
      orphans: [orphan(endedPaused: true)],
    );
    final services = fakeServices(recorder: fake);
    await pumpApp(tester, services, checkRecoveryOnOpen: true);
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(', paused.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'RESUME'));
    await pumpTimes(tester, 8);
    expect(find.text('PAUSED'), findsOneWidget);
  });
}
