import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/version.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/brand/track_bend_paths.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/splash/intro_gate.dart';
import 'package:run_solo/splash/track_bend_intro.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

Finder intro() => find.byKey(const ValueKey('track-bend-intro'));

void main() {
  group('IntroGate decide plan section 4 D8', () {
    test('first launch and a new version get the full intro', () {
      expect(
        IntroGate.decide(
          recordingLive: false,
          hasRecoveryJournal: false,
          seenVersion: null,
        ),
        IntroKind.full,
      );
      expect(
        IntroGate.decide(
          recordingLive: false,
          hasRecoveryJournal: false,
          seenVersion: '0.0.9+1',
          currentVersion: '0.1.0+1',
        ),
        IntroKind.full,
      );
    });

    test('an ordinary cold start gets the short intro', () {
      expect(
        IntroGate.decide(
          recordingLive: false,
          hasRecoveryJournal: false,
          seenVersion: kAppVersion,
        ),
        IntroKind.short,
      );
    });

    test('never while recording or with a recovery journal', () {
      for (final seen in [null, kAppVersion]) {
        expect(
          IntroGate.decide(
            recordingLive: true,
            hasRecoveryJournal: false,
            seenVersion: seen,
          ),
          IntroKind.none,
        );
        expect(
          IntroGate.decide(
            recordingLive: false,
            hasRecoveryJournal: true,
            seenVersion: seen,
          ),
          IntroKind.none,
        );
      }
    });
  });

  group('IntroGate read asks the recorder before the first frame', () {
    test('a live run means no intro', () async {
      final fake = FakeRecorderGateway(now: now);
      final services = fakeServices(recorder: fake);
      await fake.start(RecordMode.free, null, Units.km);
      expect(await IntroGate.read(services), IntroKind.none);
      await fake.pause();
      expect(await IntroGate.read(services), IntroKind.none, reason: 'paused');
    });

    test('a waiting recovery journal means no intro', () async {
      final fake = FakeRecorderGateway(
        now: now,
        orphans: [
          OrphanJournal(
            runId: 'orphan-1',
            lastLineAgeMs: 60000,
            mode: RecordMode.laps,
            readable: true,
            newer: false,
            endedPaused: false,
            elapsedMs: 600000,
          ),
        ],
      );
      expect(
        await IntroGate.read(fakeServices(recorder: fake)),
        IntroKind.none,
      );
    });

    test('idle full until this version has played it then short', () async {
      expect(await IntroGate.read(fakeServices()), IntroKind.full);
      expect(
        await IntroGate.read(
          fakeServices(
            settings: const AppSettings(
              onboardingDone: true,
              introSeenVersion: kAppVersion,
            ),
          ),
        ),
        IntroKind.short,
      );
    });
  });

  group('IntroGate read slow or failing platform means no intro', () {
    test('both calls hang no intro within the one budget', () async {
      final fake = _SlowGateway(
        statusDelay: const Duration(days: 1),
        recoverDelay: const Duration(days: 1),
      );
      final sw = Stopwatch()..start();
      final kind = await IntroGate.read(
        fakeServices(recorder: fake),
        timeout: const Duration(milliseconds: 200),
      );
      expect(kind, IntroKind.none);
      expect(sw.elapsedMilliseconds, lessThan(390), reason: 'one budget');
    });

    test('status and recover run concurrently under the budget', () async {
      // 250 ms each: serial would be 500 ms and blow a 400 ms budget.
      final fake = _SlowGateway(
        statusDelay: const Duration(milliseconds: 250),
        recoverDelay: const Duration(milliseconds: 250),
      );
      expect(
        await IntroGate.read(
          fakeServices(recorder: fake),
          timeout: const Duration(milliseconds: 400),
        ),
        IntroKind.full,
      );
    });

    test('a platform error in either call means no intro', () async {
      for (final fake in [
        _SlowGateway(statusError: true),
        _SlowGateway(recoverError: true),
      ]) {
        expect(
          await IntroGate.read(fakeServices(recorder: fake)),
          IntroKind.none,
        );
      }
    });
  });

  group('beats Track Bend', () {
    test('full lanes draw outer first wordmark sets stripes draw exit', () {
      final f0 = trackBendFrameAt(IntroKind.full, 0);
      expect(f0.opacity, 0);
      expect(f0.lanes, everyElement(0));

      final f200 = trackBendFrameAt(IntroKind.full, 200);
      expect(f200.opacity, closeTo(1, 1e-9));
      expect(f200.lanes[0], greaterThan(f200.lanes[1]), reason: 'Z1 leads');
      for (var k = 1; k < 5; k++) {
        expect(f200.lanes[k - 1], greaterThanOrEqualTo(f200.lanes[k]));
      }
      expect(f200.lanes[4], 0, reason: 'Z5 starts last');
      expect(f200.wordOpacity, 0);

      final f600 = trackBendFrameAt(IntroKind.full, 600);
      expect(f600.lanes, everyElement(closeTo(1, 1e-9)));
      expect(f600.wordOpacity, greaterThan(0));
      expect(f600.stripes, everyElement(0));

      final f800 = trackBendFrameAt(IntroKind.full, 800);
      expect(f800.wordOpacity, closeTo(1, 1e-9));
      expect(f800.wordDy, closeTo(0, 1e-9));
      expect(f800.stripes[0], greaterThan(f800.stripes[4]));

      final f1100 = trackBendFrameAt(IntroKind.full, 1100);
      expect(f1100.stripes, everyElement(closeTo(1, 1e-9)));
      expect(f1100.opacity, 1);

      final f1400 = trackBendFrameAt(IntroKind.full, 1400);
      expect(f1400.opacity, 0);
      expect(f1400.scale, closeTo(0.96, 1e-9));
    });

    test('short lanes only no wordmark', () {
      final f200 = trackBendFrameAt(IntroKind.short, 200);
      expect(f200.lanes[0], greaterThan(0));
      expect(f200.wordOpacity, 0);
      final f400 = trackBendFrameAt(IntroKind.short, 400);
      expect(f400.lanes, everyElement(closeTo(1, 1e-9)));
      expect(f400.stripes, everyElement(0));
      expect(trackBendFrameAt(IntroKind.short, 600).opacity, 0);
    });

    test('staging mark 56 % of the width wide at 40 % height', () {
      final l = TrackBendLayout(const Size(360, 780));
      expect(l.s * TrackBendGeometry.markWidth, closeTo(0.56 * 360, 1e-9));
      expect(l.markCentre.dy, closeTo(0.40 * 780, 1e-9));
      expect(l.markCentre.dx, closeTo(180, 1e-9));
    });
  });

  group('intro over the app', () {
    testWidgets('full intro plays over Home and leaves at 1400 ms', (
      tester,
    ) async {
      await pumpApp(tester, fakeServices(), intro: IntroKind.full);
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(intro(), findsNothing);
    });

    testWidgets('short intro leaves at 600 ms', (tester) async {
      await pumpApp(tester, fakeServices(), intro: IntroKind.short);
      await tester.pump(const Duration(milliseconds: 500));
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(intro(), findsNothing);
    });

    testWidgets('a tap skips to a 160 ms exit', (tester) async {
      await pumpApp(tester, fakeServices(), intro: IntroKind.full);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(intro());
      await tester.pump(); // the skip fade's ticker starts on this frame
      await tester.pump(const Duration(milliseconds: 100));
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      expect(intro(), findsNothing, reason: 'gone well before 1.4 s');
    });

    testWidgets('reduced motion final frame for 300 ms then a cut', (
      tester,
    ) async {
      await pumpApp(
        tester,
        fakeServices(
          settings: const AppSettings(
            onboardingDone: true,
            reducedMotion: true,
          ),
        ),
        intro: IntroKind.full,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(intro(), findsOneWidget);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: intro(),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as TrackBendPainter;
      expect(painter.frame.wordOpacity, 1, reason: 'static final frame');
      expect(painter.frame.opacity, 1);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(intro(), findsNothing);
    });

    testWidgets('no intro nothing over the app', (tester) async {
      await pumpApp(tester, fakeServices());
      expect(intro(), findsNothing);
    });

    testWidgets('the full intro marks this version as seen', (tester) async {
      final services = fakeServices();
      await pumpApp(tester, services, intro: IntroKind.full);
      await tester.pump();
      expect(services.settings.settings.introSeenVersion, kAppVersion);
      await tester.pump(const Duration(milliseconds: 1500));
    });

    testWidgets('the short intro leaves the seen version alone', (
      tester,
    ) async {
      final services = fakeServices();
      await pumpApp(tester, services, intro: IntroKind.short);
      await tester.pump(const Duration(milliseconds: 700));
      expect(services.settings.settings.introSeenVersion, isNull);
    });
  });
}

/// The fake recorder with a slow or failing `status()` / `recover()`.
class _SlowGateway extends FakeRecorderGateway {
  _SlowGateway({
    this.statusDelay = Duration.zero,
    this.recoverDelay = Duration.zero,
    this.statusError = false,
    this.recoverError = false,
  }) : super(now: now);

  final Duration statusDelay;
  final Duration recoverDelay;
  final bool statusError;
  final bool recoverError;

  @override
  Future<RecorderStatus> status() async {
    await Future<void>.delayed(statusDelay);
    if (statusError) throw StateError('channel down');
    return super.status();
  }

  @override
  Future<List<OrphanJournal>> recover() async {
    await Future<void>.delayed(recoverDelay);
    if (recoverError) throw StateError('channel down');
    return super.recover();
  }
}
