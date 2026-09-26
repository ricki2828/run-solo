import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Verdict states through the real engine (design brief §4.6, plan §5).
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);
  final d2 = DateTime.utc(2026, 9, 14, 6);
  final d3 = DateTime.utc(2026, 9, 18, 6);

  Future<void> openVerdict(
    WidgetTester tester,
    List<engine.RunFile> files,
    String id, {
    bool justFinished = false,
    AppSettings settings = const AppSettings(onboardingDone: true),
  }) async {
    await pumpApp(
      tester,
      fakeServices(files: files, settings: settings),
      pushRoute: justFinished ? Routes.verdictJustFinished : Routes.verdict,
      pushArguments: id,
    );
    await pumpTimes(tester, 6);
    expect(find.byType(VerdictScreen), findsOneWidget);
  }

  /// Play M4 to the end.
  Future<void> reveal(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pump(const Duration(milliseconds: 200));
  }

  String word(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('verdict-word'))).data!;

  testWidgets('run 1: BASELINE SET, bars in Bone, no bloom', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    await openVerdict(tester, [r1], r1.id);
    await reveal(tester);
    expect(word(tester), 'BASELINE SET');
    expect(find.textContaining('Next 4x4 gets a verdict'), findsOneWidget);
    expect(find.byKey(const ValueKey('fix-laps')), findsNothing);
    expect(find.text('DETAILS'), findsOneWidget);
  });

  testWidgets(
    'run 2 faster: FASTER in Arc with the arrow, haptics beat fires',
    (tester) async {
      final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
      final r2 = fourByFourFile(n: 2, start: d2, workSecPerKm: 260);
      await openVerdict(tester, [r1, r2], r2.id);
      // Before the word beat (700 ms) the word is still below the lap line.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 300));
      await reveal(tester);
      expect(word(tester), 'FASTER');
      expect(find.byKey(const ValueKey('verdict-arrow-up')), findsOneWidget);
      final t = tester.widget<Text>(find.byKey(const ValueKey('verdict-word')));
      expect(t.style?.color, RunSoloTokens.dark.accentArc);
      expect(find.textContaining('faster than your first 4x4'), findsOneWidget);
    },
  );

  testWidgets('run 2 slower: SLOWER, no Arc', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 260);
    final r2 = fourByFourFile(n: 2, start: d2, workSecPerKm: 290);
    await openVerdict(tester, [r1, r2], r2.id);
    await reveal(tester);
    expect(word(tester), 'SLOWER');
    expect(find.byKey(const ValueKey('verdict-arrow-down')), findsOneWidget);
    final t = tester.widget<Text>(find.byKey(const ValueKey('verdict-word')));
    expect(t.style?.color, RunSoloTokens.dark.inkPrimary);
  });

  testWidgets('run 2 within the floor: NO REAL CHANGE', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
    final r2 = fourByFourFile(n: 2, start: d2, workSecPerKm: 280);
    await openVerdict(tester, [r1, r2], r2.id);
    await reveal(tester);
    expect(word(tester), 'NO REAL CHANGE');
    expect(find.byKey(const ValueKey('verdict-arrow-flat')), findsOneWidget);
    expect(
      find.textContaining('Inside what phone GPS can tell'),
      findsOneWidget,
    );
  });

  testWidgets('run 3+: verdict vs median, rank line', (tester) async {
    final files = [
      fourByFourFile(n: 1, start: d1, workSecPerKm: 290),
      fourByFourFile(n: 2, start: d2, workSecPerKm: 288),
      fourByFourFile(n: 3, start: d3, workSecPerKm: 262),
    ];
    await openVerdict(tester, files, files.last.id);
    await reveal(tester);
    expect(word(tester), 'FASTER');
    expect(find.byKey(const ValueKey('verdict-arrow-up')), findsOneWidget);
  });

  testWidgets('flagged (missed press): NO VERDICT, reason, FIX LAPS button', (
    tester,
  ) async {
    final r1 = fourByFourFile(n: 1, start: d1, missedPress: true);
    await openVerdict(tester, [r1], r1.id);
    await reveal(tester);
    expect(word(tester), 'NO VERDICT');
    expect(find.byKey(const ValueKey('fix-laps')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fix-laps')));
    await settleAnimations(tester);
    expect(find.text('FIX LAPS'), findsWidgets);
  });

  testWidgets('indoor: INDOOR RUN', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1, indoor: true);
    await openVerdict(tester, [r1], r1.id);
    await reveal(tester);
    expect(word(tester), 'INDOOR RUN');
  });

  testWidgets('reduced motion: end state within 160 ms', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    await openVerdict(
      tester,
      [r1],
      r1.id,
      settings: const AppSettings(onboardingDone: true, reducedMotion: true),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 170));
    final t = tester.widget<Text>(find.byKey(const ValueKey('verdict-word')));
    expect(t.data, 'BASELINE SET');
    final opacity = tester
        .widgetList<Opacity>(
          find.ancestor(
            of: find.byKey(const ValueKey('verdict-word')),
            matching: find.byType(Opacity),
          ),
        )
        .first;
    expect(opacity.opacity, 1);
  });

  testWidgets('just finished: DONE, observed max HR folded into settings', (
    tester,
  ) async {
    final r1 = fourByFourFile(n: 1, start: d1, hr: true);
    final services = fakeServices(files: [r1]);
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.verdictJustFinished,
      pushArguments: r1.id,
    );
    await pumpTimes(tester, 6);
    await reveal(tester);
    expect(find.text('DONE'), findsOneWidget);
    final observed = services.settings.settings.observedMaxHr;
    expect(observed, isNotNull);
    expect(observed, greaterThan(150));
    expect(find.byKey(const ValueKey('verdict-arrow-up')), findsNothing);
  });

  testWidgets('verdict is frozen into the sidecar once', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final services = fakeServices(files: [r1]);
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.verdict,
      pushArguments: r1.id,
    );
    await pumpTimes(tester, 6);
    final store = services.history;
    final d = await store.load(r1.id);
    expect(d!.sidecar.frozenVerdict, isNotNull);
    expect(d.analysis.verdictSource, engine.VerdictSource.frozen);
  });

  testWidgets('Laps run after Stop: summary with lap table, no verdict word', (
    tester,
  ) async {
    final r = lapsRunFile(n: 5, start: d1);
    await openVerdict(tester, [r], r.id, justFinished: true);
    expect(find.text('LAPS RUN'), findsOneWidget);
    expect(find.byKey(const ValueKey('verdict-word')), findsNothing);
    expect(find.byType(RunDetailBody), findsOneWidget);
    expect(find.textContaining('FASTEST LAP'), findsOneWidget);
    expect(find.text('DONE'), findsOneWidget);
  });

  testWidgets('Free run after Stop: summary, splits, no verdict word', (
    tester,
  ) async {
    final r = freeRunFile(n: 6, start: d1);
    await openVerdict(tester, [r], r.id, justFinished: true);
    expect(find.text('FREE RUN'), findsOneWidget);
    expect(find.byKey(const ValueKey('verdict-word')), findsNothing);
    expect(find.text('AVG PACE'), findsOneWidget);
    expect(find.text('KM'), findsOneWidget);
  });

  testWidgets('DETAILS opens run detail with the map', (tester) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    await openVerdict(tester, [r1], r1.id);
    await reveal(tester);
    await tester.tap(find.text('DETAILS'));
    await settleAnimations(tester);
    expect(find.byType(RunDetailScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
  });

  // A6: with weather, one line after the HR line; the verdict word is the
  // raw one (the engine test pins it word for word).
  testWidgets('warm run: heat-adjusted estimate line under the verdict', (
    tester,
  ) async {
    final r1 = fourByFourFile(n: 1, start: d1);
    final weather = engine.WeatherRecord(
      status: engine.WeatherStatus.ok,
      fetchedAt: d1,
      tempC: 28,
      rh: 62,
      dewPointC: 21,
      adj: engine.HeatModel.of(tempC: 28, dewPointC: 21).fraction,
    );
    await pumpApp(
      tester,
      fakeServices(
        files: [r1],
        sidecars: {
          r1.id: engine.RunSidecar(runId: r1.id, weather: weather.toJson()),
        },
      ),
      pushRoute: Routes.verdict,
      pushArguments: r1.id,
    );
    await pumpTimes(tester, 6);
    await reveal(tester);
    expect(word(tester), 'BASELINE SET');
    final line = find.textContaining('Heat-adjusted estimate: ');
    expect(line, findsOneWidget);
    expect(
      engine.carriesEstimateMarker(tester.widget<Text>(line).data!),
      isTrue,
    );
  });
}
