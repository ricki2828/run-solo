import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/load_trends.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/screens/weekly_load_page.dart';
import 'package:run_solo/screens/trend_screen.dart';
import 'package:run_solo/theme/lanes.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/hold_button.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Outdoor rules (design brief §4): 56 dp targets, labelled targets, and
/// contrast. `textContrastGuideline` is WCAG AA (4.5:1); the 7:1 record
/// screen rule is covered by the token audit in the golden tests.
void main() {
  Future<void> expectGuidelines(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  testWidgets('record screen meets tap-target, label and contrast rules', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(recorder: fake);
    await services.recording.start(
      RecordMode.intervals,
      standardPreset(),
      Units.km,
    );
    await pumpApp(tester, services, pushRoute: Routes.recording);
    await pumpTimes(tester, 4);
    await fake.lap(LapSource.button);
    fake.advance(const Duration(seconds: 30));
    await pumpTimes(tester, 5);
    // The flood crossfades from the run type's colour to the first zone's in
    // 400 ms (the foreground flips at once); measure the settled screen.
    await tester.pump(const Duration(milliseconds: 500));
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('start screen meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, fakeServices(), pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('checklist meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(
      tester,
      fakeServices(permissions: FakePermissionsGateway()),
      home: const PermissionsScreen(),
    );
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('home meets the rules', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, fakeServices(), home: HomeScreen(now: now));
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('free run and laps run record layouts meet the rules', (
    tester,
  ) async {
    for (final mode in [RecordMode.free, RecordMode.laps]) {
      final handle = tester.ensureSemantics();
      final fake = FakeRecorderGateway(now: now)..scriptedHr = 140;
      final services = fakeServices(recorder: fake);
      await services.recording.start(mode, null, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 4);
      fake.advance(const Duration(seconds: 30));
      await pumpTimes(tester, 5);
      await tester.pump(const Duration(milliseconds: 700));
      await expectGuidelines(tester);
      handle.dispose();
    }
  });

  testWidgets('verdict, detail, trend and settings meet the rules', (
    tester,
  ) async {
    final d1 = DateTime.utc(2026, 9, 10, 6);
    final r1 = fourByFourFile(n: 1, start: d1, workSecPerKm: 284);
    final r2 = fourByFourFile(
      n: 2,
      start: d1.add(const Duration(days: 4)),
      workSecPerKm: 262,
    );
    final services = fakeServices(files: [r1, r2]);

    var handle = tester.ensureSemantics();
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.verdict,
      pushArguments: r2.id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 1800));
    await expectGuidelines(tester);
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(tester, services, home: RunDetailScreen(runId: r2.id));
    await pumpTimes(tester, 6);
    await expectGuidelines(tester);
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(
      tester,
      services,
      home: const TrendScreen(initial: RecordMode.intervals),
    );
    await pumpTimes(tester, 6);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    // The text-contrast guideline finds a chip's text colour from the
    // second most common pixel colour in its rect. In this five-chip row the
    // chips land on fractional x, so for "Laps" and "Free" that colour is an
    // anti-aliased blend (B1B4B7), not the ink: moving the row by 0.6 dp makes
    // the same row pass, and 0.3 dp flags "Load" instead. So this step runs
    // the tap-target and label guidelines and checks the chip colours by
    // their tokens (8:1 and better); the pixel guideline still covers every
    // other screen in this test.
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    for (final tokens in [RunSoloTokens.dark, RunSoloTokens.light]) {
      // Unselected chip label on its fill; selected label on the ink fill.
      expect(
        contrastRatio(tokens.inkSecondary, tokens.bgRaised),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrastRatio(tokens.bgRaised, tokens.inkPrimary),
        greaterThanOrEqualTo(4.5),
      );
    }
    handle.dispose();

    handle = tester.ensureSemantics();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets(
    'Load trends (the default view) and the load page meet the rules',
    (tester) async {
      // Load is the default Trends view. Its Week, Month and Year views and the
      // weekly story's load page get the tap-target and label guidelines; the
      // pixel contrast guideline is not run on the chip row (see above), so the
      // text colours these screens use are checked by token.
      final weeks = engine.WeekLoad.sample(engine.LoadSample.usual);
      final data = LoadTrendsData(
        weeks: [
          ...weeks,
          engine.WeekLoad(
            monday: DateTime(2026, 10, 26),
            load: 150,
            km: 12,
            minutes: 70,
            runs: 2,
            zoneShare: const [.1, .45, .3, .12, .03],
            current: true,
          ),
        ],
        months: [
          for (var i = 0; i < 6; i++)
            engine.PeriodLoad(
              start: DateTime(2026, 5 + i),
              load: 1000.0 + 50 * i,
              km: 90,
              minutes: 500,
              runs: 14,
              current: i == 5,
            ),
        ],
        year: engine.YearLoad(
          months: [
            for (var m = 0; m < 12; m++)
              engine.PeriodLoad(
                start: DateTime(2026, m + 1),
                load: m < 10 ? 900 : 0,
                km: m < 10 ? 80 : 0,
                minutes: m < 10 ? 400 : 0,
                runs: m < 10 ? 12 : 0,
                current: m == 9,
                future: m > 9,
              ),
          ],
          km: 800,
          runs: 120,
          minutes: 4000,
          lastYearKm: 600,
          lastYearRuns: 70,
        ),
        hasRuns: true,
      );
      for (final view in ['week', 'month', 'year']) {
        final handle = tester.ensureSemantics();
        await pumpApp(
          tester,
          fakeServices(),
          home: TrendScreen(loadData: data),
        );
        await pumpTimes(tester, 4);
        await tester.tap(find.byKey(ValueKey('load-view-$view')));
        await pumpTimes(tester, 4);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      }

      final handle = tester.ensureSemantics();
      await pumpApp(
        tester,
        fakeServices(),
        home: WeeklyLoadPage(
          weeks: engine.WeekLoad.sample(engine.LoadSample.bigjump),
        ),
      );
      await pumpTimes(tester, 4);
      await tester.pump(const Duration(milliseconds: 1600));
      await expectGuidelines(tester);
      handle.dispose();

      for (final tokens in [RunSoloTokens.dark, RunSoloTokens.light]) {
        // Usual, SO FAR, dates, "Taller is more load" (inkSecondary on the card).
        expect(
          contrastRatio(tokens.inkSecondary, tokens.bgRaised),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(tokens.inkPrimary, tokens.bgRaised),
          greaterThanOrEqualTo(4.5),
        );
      }
      // The load page's explainer and footnote: ink at 0.85 on the aurora fill.
      const fill = AuroraStory.fill;
      final ink = readableOn(fill);
      expect(
        contrastRatio(
          Color.alphaBlend(ink.withValues(alpha: 0.85), fill),
          fill,
        ),
        greaterThanOrEqualTo(4.5),
      );
    },
  );

  testWidgets('HOLD TO STOP exposes a long-press action for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var held = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(
          body: Center(
            child: HoldButton(label: 'HOLD TO STOP', onHeld: () => held++),
          ),
        ),
      ),
    );
    final stop = find.semantics.byAction(SemanticsAction.longPress);
    expect(stop, findsOneWidget);
    tester.semantics.performAction(stop, SemanticsAction.longPress);
    await tester.pump();
    expect(held, 1);
    handle.dispose();
  });
}
