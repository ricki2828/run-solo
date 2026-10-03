import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/recording_screen.dart' show liveRunTypeColor;
import 'package:run_solo/screens/trail_suggest_card.dart';
import 'package:run_solo/screens/trail_verdict_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The Trail run type: re-tag from a Free run, the suggestion on the result
/// screen, the History filter, and the mode through the file and the index.
void main() {
  final d1 = DateTime.utc(2026, 9, 24, 6);

  engine.RunFile withClimb(engine.RunFile run, {required double perKm}) {
    final km = run.distanceM / 1000;
    final hills = 5;
    final amp = perKm * km / (hills * 2);
    return run.copyWith(
      samples: [
        for (final s in run.samples)
          s.copyWith(
            altM:
                amp *
                (1 - math.cos(s.distM / run.distanceM * 2 * math.pi * hills)),
          ),
      ],
    );
  }

  // 30 min at 6:00/km is 5 km.
  final flat = withClimb(freeRunFile(n: 1, start: d1), perKm: 3);
  final hilly = withClimb(freeRunFile(n: 2, start: d1), perKm: 45);

  group('suggestion rule on the result screen', () {
    test('offered for a hilly Free run only', () {
      expect(trailSuggested(hilly, RecordMode.free), isTrue);
      expect(trailSuggested(flat, RecordMode.free), isFalse);
      expect(trailSuggested(hilly, RecordMode.laps), isFalse);
      expect(trailSuggested(hilly, RecordMode.trail), isFalse);
    });

    Future<void> open(
      WidgetTester tester,
      List<engine.RunFile> files,
      String id,
    ) async {
      await pumpApp(
        tester,
        fakeServices(
          files: files,
          settings: const AppSettings(onboardingDone: true),
        ),
        pushRoute: Routes.verdictJustFinished,
        pushArguments: id,
      );
      await pumpTimes(tester, 6);
      expect(find.byType(VerdictScreen), findsOneWidget);
    }

    testWidgets('a hilly Free run asks, Yes re-tags it as Trail', (
      tester,
    ) async {
      await open(tester, [hilly], hilly.id);
      expect(find.text('FREE RUN'), findsOneWidget);
      expect(find.byKey(const ValueKey('trail-suggest')), findsOneWidget);
      expect(
        find.textContaining('Looks like a trail run. Save it as Trail?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('trail-suggest-yes')));
      await pumpTimes(tester, 8);
      expect(find.textContaining('TRAIL RUN'), findsOneWidget);
      expect(find.text('FREE RUN'), findsNothing);
      expect(find.byKey(const ValueKey('trail-suggest')), findsNothing);
      // A Trail run gets the trail result (this file has GPS altitude only,
      // no barometer elevation, so no true pace to judge).
      expect(find.byType(TrailVerdictScreen), findsOneWidget);
      expect(find.text('NO VERDICT'), findsOneWidget);
    });

    testWidgets('Not now hides the card and changes nothing', (tester) async {
      await open(tester, [hilly], hilly.id);
      await tester.tap(find.byKey(const ValueKey('trail-suggest-no')));
      await pumpTimes(tester, 3);
      expect(find.byKey(const ValueKey('trail-suggest')), findsNothing);
      expect(find.text('FREE RUN'), findsOneWidget);
    });

    testWidgets('a flat Free run is not asked', (tester) async {
      await open(tester, [flat], flat.id);
      expect(find.byKey(const ValueKey('trail-suggest')), findsNothing);
      expect(find.text('FREE RUN'), findsOneWidget);
    });
  });

  group('file store: re-tag and the mode through file and index', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('runsolo-trail-');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    FileRunStore storeOf() {
      final s = FileRunStore(
        Directory('${dir.path}/runs'),
        profile: () => const engine.UserProfile(age: 40),
      );
      s.deriveBatch = FileRunStore.deriveInIsolate;
      return s;
    }

    test('re-tagging recomputes the title, the mode in the index and drops any verdict', () async {
      final store = storeOf();
      await store.importBundles([engine.RunBundle(run: hilly)]);
      var row = (await store.list()).single;
      expect(row.mode, RecordMode.free);
      final word = engine.RunIdentity.timeOfDay(row.localStart);
      expect(runIdentityTitle(row), '$word Free run');

      final detail = await store.setOverride(hilly.id, RecordMode.trail);
      expect(detail.summary.mode, RecordMode.trail);
      expect(detail.analysis.verdict, isNull);
      row = (await store.list()).single;
      expect(row.mode, RecordMode.trail);
      expect(runIdentityTitle(row), '$word Trail run');
      expect(runLabel(row), 'TRAIL');
      await store.derivedIdle;

      // A fresh store reads the same index: the mode survives the round trip.
      final again = storeOf();
      final back = (await again.list()).single;
      expect(back.mode, RecordMode.trail);
      expect(
        again.decoded,
        isEmpty,
        reason: 'read from the index, not decoded',
      );
      await again.derivedIdle;

      // Undo: clearing the override returns it to Free.
      await store.setOverride(hilly.id, null);
      expect((await store.list()).single.mode, RecordMode.free);
      await store.derivedIdle;
    });

    test(
      'a run recorded as Trail is a Trail run in the file and the index',
      () async {
        final recorded = hilly.copyWith(mode: engine.RunMode.trail);
        final store = storeOf();
        await store.importBundles([engine.RunBundle(run: recorded)]);
        final row = (await store.list()).single;
        expect(row.mode, RecordMode.trail);
        expect(row.verdict, isNull);
        final d = (await store.load(recorded.id))!;
        expect(d.run.mode, engine.RunMode.trail);
        expect(d.analysis.verdict, isNull);
        expect(
          runIdentityTitle(row),
          '${engine.RunIdentity.timeOfDay(row.localStart)} Trail run',
        );
        await store.derivedIdle;
      },
    );
  });

  testWidgets('History has a Trail filter', (tester) async {
    final recorded = hilly.copyWith(mode: engine.RunMode.trail);
    final other = freeRunFile(n: 3, start: d1.add(const Duration(days: 1)));
    await pumpApp(
      tester,
      fakeServices(
        files: [recorded, other],
        settings: const AppSettings(onboardingDone: true),
      ),
      home: const HistoryScreen(),
    );
    await pumpTimes(tester);
    await tester.tap(find.byKey(const ValueKey('history-view-1')));
    await pumpTimes(tester);
    expect(find.byType(HistoryRow), findsNWidgets(2));
    await tester.ensureVisible(find.text('Trail'));
    await pumpTimes(tester);
    await tester.tap(find.text('Trail'));
    await pumpTimes(tester);
    final rows = tester.widgetList<HistoryRow>(find.byType(HistoryRow));
    expect([for (final r in rows) r.run.id], [recorded.id]);
    expect(find.text('TRAIL'), findsWidgets);
  });

  test('the live map route draws in the Trail hue', () {
    expect(liveRunTypeColor('trail'), AuroraRunType.trail);
    expect(liveRunTypeColor('free'), AuroraRunType.free);
  });

  test('the Trail hue is a token, distinct from every other run type', () {
    double hue(Color c) => HSVColor.fromColor(c).hue;
    final others = {
      'free': AuroraRunType.free,
      'laps': AuroraRunType.laps,
      'goal': AuroraRunType.goal,
      'intervals': AuroraRunType.intervals,
      'tests': AuroraRunType.tests,
      'warn': NightSession.semWarn,
      'improving': NightSession.semImproving,
      'rose': NightSession.pulseRose,
    };
    for (final e in others.entries) {
      var d = (hue(AuroraRunType.trail) - hue(e.value)).abs();
      if (d > 180) d = 360 - d;
      expect(d, greaterThan(20), reason: 'trail vs ${e.key}');
    }
    // Readable on the card ground.
    double lum(Color c) => c.computeLuminance();
    final ratio =
        (lum(AuroraRunType.trail) + 0.05) / (lum(NightSession.bgRaised) + 0.05);
    expect(ratio, greaterThan(7));
  });
}
