import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/start_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/gps_bar.dart';

import '../helpers.dart';

void main() {
  testWidgets('treadmill Ready has no GPS probe, warning or fix gate', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
        countdownSeconds: 0,
      ),
    );
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.start,
      pushArguments: const StartArgs(readyFirst: true),
    );
    await pumpTimes(tester, 5);
    await settleAnimations(tester);
    expect(find.text('TREADMILL'), findsOneWidget);
    expect(fake.gpsProbeRunning, isFalse);
    expect(find.byKey(const ValueKey('ready-gps')), findsNothing);
    expect(find.byKey(const ValueKey('ready-gps-warning')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ready-start')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const ValueKey('ready-start')));
    await tester.pump(const Duration(milliseconds: 500));
    await pumpTimes(tester, 8);
    expect((await fake.status()).mode, RecordMode.treadmill);
    await fake.discard();
  });

  testWidgets(
    'treadmill times and records HR, validates finish distance before saving',
    (tester) async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(
        recorder: fake,
        settings: const AppSettings(
          onboardingDone: true,
          lastMode: RecordMode.treadmill,
        ),
      );
      await services.recording.start(RecordMode.treadmill, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      fake.advance(const Duration(minutes: 10));
      await pumpTimes(tester, 5);
      expect(find.byKey(const ValueKey('treadmill-time')), findsOneWidget);
      expect(find.byType(GpsBar), findsNothing);
      expect(services.recording.snapshot.gpsLost, isFalse);
      expect(services.recording.snapshot.hr, isNotNull);
      expect(services.recording.snapshot.totalDistanceM, 0);
      await tester.tap(find.byKey(const ValueKey('stop')));
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('finish-save')));
      await pumpTimes(tester, 4);
      await tester.enterText(
        find.byKey(const ValueKey('treadmill-distance')),
        'NaN',
      );
      await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
      await tester.pump();
      expect(fake.finalised, isEmpty);
      expect(
        find.textContaining('Enter a distance greater than zero'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('treadmill-distance')),
        '2.75',
      );
      await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
      await pumpTimes(tester, 6);
      expect(fake.finalised.single.mode, RecordMode.treadmill);
      expect(fake.finalised.single.distanceM, 2750);
    },
  );

  testWidgets('treadmill time freezes at STOP and SAVE ends the run there', (
    tester,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
      ),
    );
    await services.recording.start(RecordMode.treadmill, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    fake.advance(const Duration(minutes: 10));
    await pumpTimes(tester, 5);
    await tester.tap(find.byKey(const ValueKey('stop')));
    await pumpTimes(tester, 4);
    String finishTime() =>
        tester.widget<Text>(find.byKey(const ValueKey('finish-time'))).data!;
    expect(finishTime(), '10:00');
    fake.advance(const Duration(minutes: 5));
    await pumpTimes(tester, 4);
    expect(finishTime(), '10:00');
    await tester.tap(find.byKey(const ValueKey('finish-save')));
    await pumpTimes(tester, 4);
    fake.advance(const Duration(minutes: 5));
    await pumpTimes(tester, 2);
    await tester.enterText(
      find.byKey(const ValueKey('treadmill-distance')),
      '2.75',
    );
    await tester.tap(find.widgetWithText(TextButton, 'SAVE'));
    await pumpTimes(tester, 6);
    expect(fake.finalised.single.durationMs, 600000);
  });

  testWidgets('finish time stays frozen when native confirms the pause late', (
    tester,
  ) async {
    final fake = _LateEventsGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.treadmill,
      ),
    );
    await services.recording.start(RecordMode.treadmill, null, Units.km);
    await pumpApp(tester, services, pushRoute: Routes.recording);
    fake.advance(const Duration(minutes: 10));
    await tester.pump(const Duration(milliseconds: 200));
    await pumpTimes(tester, 3);
    fake.lagMs = 300; // native answers pause() before its state event lands
    await tester.tap(find.byKey(const ValueKey('stop')));
    await tester.pump(const Duration(milliseconds: 20));
    fake.advance(const Duration(minutes: 5));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    final shown = tester
        .widget<Text>(find.byKey(const ValueKey('finish-time')))
        .data;
    expect(shown, '10:00');
  });
}

/// Events reach the controller [lagMs] after native emitted them, as on a
/// device where the pigeon call returns before the state event.
class _LateEventsGateway extends FakeRecorderGateway {
  _LateEventsGateway({required super.now});
  int lagMs = 0;

  @override
  Stream<RecorderEvent> get events => super.events.asyncMap((e) async {
    if (lagMs > 0) await Future<void>.delayed(Duration(milliseconds: lagMs));
    return e;
  });
}
