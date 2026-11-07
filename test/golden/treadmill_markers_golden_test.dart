import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import 'screens_golden_test.dart' show golden;

/// 7-Nov: the treadmill run screen with two markers set: the strip, the
/// current and average speeds the marks give. PNGs come from CI.
void main() {
  for (final h in [800, 640]) {
    testWidgets('treadmill markers: two marks and live speeds at 360 x $h', (
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
      tester.view.physicalSize = Size(1080, h * 3.0);
      await pumpTimes(tester, 3);
      fake.advance(const Duration(minutes: 3));
      await fake.addTreadmillMark(500);
      fake.advance(const Duration(minutes: 2, seconds: 30));
      await fake.addTreadmillMark(1000);
      await services.recording.refreshStatus();
      fake.advance(const Duration(seconds: 20));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1));
      await settleAnimations(tester);
      expect(find.byKey(const ValueKey('treadmill-current-speed')), findsOne);
      await golden(tester, 'record_treadmill_markers_360x$h');
    });
  }
}
