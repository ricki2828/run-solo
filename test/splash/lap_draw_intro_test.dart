import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/version.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/splash/intro_gate.dart';
import 'package:run_solo/splash/lap_draw_intro.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

Finder intro() => find.byKey(const ValueKey('lap-draw-intro'));

void main() {
  group('IntroGate.decide (plan §4, D8)', () {
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

    test('an ordinary cold start gets the 0.6 s intro', () {
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

  group('IntroGate.read asks the recorder before the first frame', () {
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

    test('idle: full until this version has played it, then short', () async {
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

  group('beats (brief A9)', () {
    final l = LapDrawLayout(const Size(360, 780));

    test('full: fade in, draw across, retract to the mark, wordmark, exit', () {
      final f0 = lapDrawFrameAt(IntroKind.full, 0, l);
      expect(f0.opacity, 0);
      final f150 = lapDrawFrameAt(IntroKind.full, 150, l);
      expect(f150.opacity, closeTo(1, 1e-9));
      expect(f150.lineEnd - f150.lineStart, 0, reason: 'nothing drawn yet');
      expect(f150.markScale, 1.04);

      final f650 = lapDrawFrameAt(IntroKind.full, 650, l);
      expect(f650.lineStart, 0);
      expect(f650.lineEnd, closeTo(360, 1e-6), reason: 'edge to edge');
      expect(f650.lineThickness, 3);
      expect(f650.cutThickness, closeTo(l.markCut, 1e-9), reason: 'cut open');

      final f850 = lapDrawFrameAt(IntroKind.full, 850, l);
      expect(f850.lineStart, closeTo(l.legEntry, 1e-6));
      expect(f850.lineEnd, closeTo(l.tailEnd, 1e-6));
      expect(f850.lineThickness, closeTo(l.markLine, 1e-9));
      expect(f850.wordOpacity, 0);

      expect(lapDrawFrameAt(IntroKind.full, 1050, l).markScale, 1.0);
      final f1100 = lapDrawFrameAt(IntroKind.full, 1100, l);
      expect(f1100.wordOpacity, closeTo(1, 1e-9));
      expect(f1100.wordDy, closeTo(0, 1e-9));
      expect(lapDrawFrameAt(IntroKind.full, 1150, l).opacity, 1);

      final f1500 = lapDrawFrameAt(IntroKind.full, 1500, l);
      expect(f1500.opacity, 0);
      expect(f1500.scale, closeTo(0.96, 1e-9));
    });

    test('the cut opens only once the line reaches the R', () {
      final early = lapDrawFrameAt(IntroKind.full, 160, l);
      expect(early.lineEnd, lessThan(l.rLeft));
      expect(early.cutThickness, 0);
    });

    test('0.6 s: R already cut, its own line draws, no wordmark', () {
      final f150 = lapDrawFrameAt(IntroKind.short, 150, l);
      expect(f150.cutThickness, closeTo(l.markCut, 1e-9));
      expect(f150.lineEnd, closeTo(l.legEntry, 1e-9));
      final f400 = lapDrawFrameAt(IntroKind.short, 400, l);
      expect(f400.lineEnd, closeTo(l.tailEnd, 1e-6));
      expect(f400.wordOpacity, 0);
      expect(lapDrawFrameAt(IntroKind.short, 600, l).opacity, 0);
    });

    test(
      'staging: R 40 % of the width tall at 42 % height, word 64 % wide',
      () {
        final rHeight = l.s * 700;
        expect(rHeight, closeTo(0.40 * 360, 1e-9));
        expect(l.rCentre.dy, closeTo(0.42 * 780, 1e-9));
      },
    );
  });

  group('intro over the app', () {
    testWidgets('full intro plays over Home and leaves at 1.5 s', (
      tester,
    ) async {
      await pumpApp(tester, fakeServices(), intro: IntroKind.full);
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1400));
      expect(intro(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      expect(intro(), findsNothing);
    });

    testWidgets('0.6 s intro leaves at 600 ms', (tester) async {
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
      expect(intro(), findsNothing, reason: 'gone well before 1.5 s');
    });

    testWidgets('reduced motion: final frame for 300 ms, then a cut', (
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
              as LapDrawPainter;
      expect(painter.frame.wordOpacity, 1, reason: 'static final frame');
      expect(painter.frame.opacity, 1);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(intro(), findsNothing);
    });

    testWidgets('no intro: nothing over the app', (tester) async {
      await pumpApp(tester, fakeServices());
      expect(intro(), findsNothing);
    });

    testWidgets('the full intro marks this version as seen', (tester) async {
      final services = fakeServices();
      await pumpApp(tester, services, intro: IntroKind.full);
      await tester.pump();
      expect(services.settings.settings.introSeenVersion, kAppVersion);
      await tester.pump(const Duration(milliseconds: 1600));
    });

    testWidgets('the 0.6 s intro leaves the seen version alone', (
      tester,
    ) async {
      final services = fakeServices();
      await pumpApp(tester, services, intro: IntroKind.short);
      await tester.pump(const Duration(milliseconds: 700));
      expect(services.settings.settings.introSeenVersion, isNull);
    });
  });
}
