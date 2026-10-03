import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/boards_overview.dart';
import 'package:run_solo/screens/score_analysis.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/trail_board_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/spoken_summary.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// The Trail verdict on screen: same trail when there is a match, else effort
/// pace; the runs-on-this-trail chart on the detail; the trail board. Earlier
/// runs reach the screens as index rows (route, moving time, climb, effort
/// pace), exactly as a phone's History does; the file-store round trip is in
/// test/state/trail_index_test.dart.
void main() {
  final d1 = DateTime.utc(2026, 9, 12, 6);
  final d2 = DateTime.utc(2026, 9, 20, 6);
  final d3 = DateTime.utc(2026, 9, 28, 6);

  /// [f] as History holds it: a summary with its index row.
  RunSummary indexed(engine.RunFile f, {String street = 'Kastro'}) {
    final a = const engine.RunEngine().analyze(f, now: now());
    return RunSummary(
      id: f.id,
      mode: RecordMode.trail,
      start: f.start,
      durationMs: f.end.difference(f.start).inMilliseconds,
      distanceM: f.distanceM,
      laps: 0,
      street: street,
      row: IndexRow.of(
        f,
        a,
        null,
        sidecar: engine.RunSidecar(runId: f.id, street: street),
      ),
    );
  }

  AppServices open(
    engine.RunFile current,
    List<engine.RunFile> earlier, {
    bool haptics = false,
    AppSettings? settings,
  }) => fakeServices(
    files: [current],
    // The run on screen is in History too, as a phone's index has it.
    runs: [
      for (final e in [...earlier, current]) indexed(e),
    ],
    sidecars: {
      current.id: engine.RunSidecar(runId: current.id, street: 'Kastro'),
    },
    settings: settings ?? AppSettings(onboardingDone: true, haptics: haptics),
  );

  Future<void> show(
    WidgetTester tester,
    engine.RunFile current,
    List<engine.RunFile> earlier,
  ) async {
    await pumpApp(
      tester,
      open(current, earlier),
      pushRoute: Routes.verdictJustFinished,
      pushArguments: current.id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 1800));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(VerdictScreen), findsOneWidget);
  }

  Color wordColor(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('verdict-word')))
      .style!
      .color!;
  String word(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('verdict-word'))).data!;
  String sub(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('trail-verdict-subline')))
      .data!;

  group('same trail', () {
    final old = trailLoopRun(n: 1, start: d1, secPerKm: 420);

    testWidgets('faster: mint word, the gap to the last run, the climb', (
      tester,
    ) async {
      final now = trailLoopRun(n: 2, start: d2, secPerKm: 400);
      await show(tester, now, [old]);
      expect(word(tester), 'FASTER');
      expect(wordColor(tester), NightSession.semImproving);
      expect(
        find.byKey(const ValueKey('trail-verdict-kicker')),
        findsOneWidget,
      );
      expect(find.text('ON THIS TRAIL'), findsOneWidget);
      expect(sub(tester), '2:00 quicker than 12 Sep, your last run here.');
      expect(find.textContaining('Climb '), findsOneWidget);
      expect(
        find.textContaining('Moving time 40:00, was 42:00.'),
        findsOneWidget,
      );
      // The best on the trail so far: the cyan PB chip.
      expect(find.byKey(const ValueKey('pb-chip')), findsOneWidget);
      expect(find.text('Best on Kastro loop'), findsOneWidget);
      expect(find.byKey(const ValueKey('trail-board-chip')), findsOneWidget);
    });

    testWidgets('slower: vermillion, says where the best is, no PB chip', (
      tester,
    ) async {
      final now = trailLoopRun(n: 3, start: d3, secPerKm: 450);
      await show(tester, now, [old]);
      expect(word(tester), 'SLOWER');
      expect(wordColor(tester), NightSession.semSlower);
      expect(sub(tester), '3:00 slower than 12 Sep, your last run here.');
      expect(find.byKey(const ValueKey('pb-chip')), findsNothing);
      expect(find.textContaining('also your best here'), findsOneWidget);
    });

    testWidgets('level reads as no real change, in Bone', (tester) async {
      final now = trailLoopRun(n: 4, start: d3, secPerKm: 421);
      await show(tester, now, [old]);
      expect(word(tester), 'NO REAL CHANGE');
      expect(sub(tester), contains('Inside the run-to-run noise'));
      expect(find.byKey(const ValueKey('pb-chip')), findsNothing);
    });
  });

  group('no match: true pace', () {
    final old = trailLoopRun(n: 1, start: d1, secPerKm: 420);

    testWidgets('a reversed loop is a different trail', (tester) async {
      final now = trailLoopRun(n: 5, start: d2, secPerKm: 400, reverse: true);
      await show(tester, now, [old]);
      expect(find.text('ON THIS TRAIL'), findsNothing);
      expect(sub(tester), startsWith('True pace '));
      expect(sub(tester), contains('recent trail runs'));
      expect(find.textContaining('First time on this trail'), findsOneWidget);
    });

    testWidgets('no earlier trail run is a baseline', (tester) async {
      final now = trailLoopRun(n: 6, start: d2);
      await show(tester, now, []);
      expect(word(tester), 'BASELINE SET');
      expect(sub(tester), contains(' true pace'));
      expect(sub(tester), endsWith('Your next trail run gets a verdict.'));
    });

    testWidgets('no elevation, no verdict', (tester) async {
      final flat = trailLoopRun(n: 7, start: d2).copyWith(elevSrc: null);
      await show(tester, flat, []);
      expect(word(tester), 'NO VERDICT');
      expect(sub(tester), 'No elevation on this run, so no true pace.');
    });
  });

  group('runs on this trail', () {
    final a = trailLoopRun(n: 1, start: d1, secPerKm: 420);
    final b = trailLoopRun(n: 2, start: d2, secPerKm: 400);
    final c = trailLoopRun(n: 3, start: d3, secPerKm: 410);

    testWidgets('the detail shows the bars and opens the trail board', (
      tester,
    ) async {
      final services = open(c, [a, b]);
      await pumpApp(tester, services, home: RunDetailScreen(runId: c.id));
      await pumpTimes(tester, 6);
      await scrollTo(tester, find.text('YOUR RUNS ON THIS TRAIL'));
      expect(find.text('YOUR RUNS ON THIS TRAIL'), findsOneWidget);
      expect(find.byKey(const ValueKey('trail-runs-chart')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('trail-board-link')),
      );
      await tester.tap(find.byKey(const ValueKey('trail-board-link')));
      await pumpTimes(tester, 6);
      expect(find.byType(TrailBoardScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('trail-board-best')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('trail-board-best')))
            .data,
        '40:00',
      );
      expect(find.text('Best'), findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
    });

    testWidgets('a first run on a trail says so, with no chart', (
      tester,
    ) async {
      await pumpApp(tester, open(a, []), home: RunDetailScreen(runId: a.id));
      await pumpTimes(tester, 6);
      await scrollTo(tester, find.textContaining('First run on Kastro loop'));
      expect(find.textContaining('First run on Kastro loop'), findsOneWidget);
      expect(find.byKey(const ValueKey('trail-runs-chart')), findsNothing);
    });

    testWidgets('the Boards tab lists a trail with two runs only', (
      tester,
    ) async {
      final lone = trailLoopRun(n: 9, start: d3, dLat: 0.05);
      final services = fakeServices(
        runs: [
          indexed(a),
          indexed(b),
          indexed(lone, street: 'Elsewhere'),
        ],
        settings: const AppSettings(onboardingDone: true),
      );
      await pumpApp(
        tester,
        services,
        home: const Scaffold(body: BoardsOverview()),
      );
      await pumpTimes(tester, 6);
      expect(find.text('TRAILS'), findsOneWidget);
      expect(find.text('Kastro loop'), findsOneWidget);
      expect(find.text('Elsewhere loop'), findsNothing);
      expect(find.text('40:00'), findsOneWidget);
    });
  });

  testWidgets('the score detail says trail runs count at true pace', (
    tester,
  ) async {
    final hilly = engine.LiveCandidate(
      engine.BoardInput(
        runId: 'trail-1',
        date: now().subtract(const Duration(days: 2)),
        mode: engine.RunMode.trail,
        trailDistanceM: 15500,
        trailMovingMs: (15.5 * 440 * 1000).round(),
        gradeFactor: 0.75,
      ),
      const engine.RunDerived(
        bestEfforts: engine.RunBestEfforts(efforts: {}, fromStartSplitsMs: []),
      ),
    );
    final services = fakeServices(
      live: LiveContextSource.prepared([hilly], now: now),
      settings: const AppSettings(
        onboardingDone: true,
        birthYear: 1985,
        profileSex: ProfileSex.male,
      ),
    );
    await pumpApp(
      tester,
      services,
      home: const Scaffold(body: ScoreAnalysis()),
    );
    await pumpTimes(tester, 8);
    expect(find.byKey(const ValueKey('analysis-long-trail')), findsOneWidget);
    expect(find.text('Trail runs count at true pace.'), findsWidgets);
    // A lane no trail run set carries no such line.
    expect(find.byKey(const ValueKey('analysis-mid-trail')), findsNothing);
  });

  group('spoken summary (end of run)', () {
    final old = trailLoopRun(n: 1, start: d1, secPerKm: 420);

    Future<FakeRecorderGateway> finish(
      WidgetTester tester,
      engine.RunFile current, {
      AppSettings? settings,
      bool justFinished = true,
    }) async {
      final services = open(current, [old], settings: settings);
      await pumpApp(
        tester,
        services,
        pushRoute: justFinished ? Routes.verdictJustFinished : Routes.verdict,
        pushArguments: current.id,
      );
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 2000));
      return services.recorder as FakeRecorderGateway;
    }

    testWidgets('says the stats and the on-screen verdict, once', (
      tester,
    ) async {
      final now = trailLoopRun(n: 2, start: d2, secPerKm: 400);
      final rec = await finish(tester, now);
      final said = rec.lastSpokenSummary!;
      expect(
        said.verdict,
        'Faster on this trail, 2 minutes quicker than last time.',
      );
      // The word on screen and the word said agree.
      expect(word(tester), 'FASTER');
      expect(
        said.verdict!.toLowerCase(),
        startsWith(word(tester).toLowerCase()),
      );
      expect(said.timeMs, 2400000);
      expect(said.distanceM, now.distanceM);
      expect(said.climbM, isNotNull);
      expect(said.units, Units.km);
    });

    testWidgets('a Free run with auto-pauses says moving time, not the clock', (
      tester,
    ) async {
      final base = freeRunFile(n: 20, start: d2);
      final run = base.copyWith(
        pauses: [
          const engine.Span(300000, 480000),
          const engine.Span(900000, 960000),
        ],
      );
      final moving = engine.RunTimes.movingMs(run);
      expect(moving, lessThan(run.end.difference(run.start).inMilliseconds));
      final services = fakeServices(
        files: [run],
        settings: const AppSettings(onboardingDone: true),
      );
      await pumpApp(
        tester,
        services,
        pushRoute: Routes.verdictJustFinished,
        pushArguments: run.id,
      );
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(milliseconds: 2000));
      final said =
          (services.recorder as FakeRecorderGateway).lastSpokenSummary!;
      expect(said.timeMs, moving);
      expect(said.includePace, isTrue);
      expect(said.verdict, isNull);
    });

    test('whole-run pace is left out for a 4x4 and Cooper only', () {
      RunSummary of(RecordMode m, {engine.SessionSpec? spec}) => RunSummary(
        id: 'x',
        mode: m,
        start: d2,
        durationMs: 1,
        distanceM: 1,
        laps: 0,
        spec: spec,
      );
      expect(spokenPaceOf(of(RecordMode.free)), isTrue);
      expect(spokenPaceOf(of(RecordMode.laps)), isTrue);
      expect(spokenPaceOf(of(RecordMode.trail)), isTrue);
      expect(spokenPaceOf(of(RecordMode.cooper)), isFalse);
      expect(spokenPaceOf(of(RecordMode.intervals)), isFalse);
      expect(
        spokenPaceOf(
          of(
            RecordMode.intervals,
            spec: engine.SessionSpec.goalDistance(10000, "10K"),
          ),
        ),
        isTrue,
      );
    });

    testWidgets('silent with voice cues off or the switch off', (tester) async {
      final now = trailLoopRun(n: 2, start: d2, secPerKm: 400);
      var rec = await finish(
        tester,
        now,
        settings: const AppSettings(onboardingDone: true, cues: false),
      );
      expect(rec.lastSpokenSummary, isNull);
      rec = await finish(
        tester,
        now,
        settings: const AppSettings(onboardingDone: true, spokenSummary: false),
      );
      expect(rec.lastSpokenSummary, isNull);
    });

    testWidgets('opening an old run from History says nothing', (tester) async {
      final now = trailLoopRun(n: 2, start: d2, secPerKm: 400);
      final rec = await finish(tester, now, justFinished: false);
      expect(rec.lastSpokenSummary, isNull);
    });
  });
}
