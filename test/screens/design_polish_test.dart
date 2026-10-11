import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/format.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/permissions_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/theme/lanes.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/chrome.dart';
import 'package:run_solo/widgets/splits_bars.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Design review 11-Oct, small items S4, S8 to S12.
void main() {
  group('S4 no-HR charts take the run-type colour', () {
    for (final b in [Brightness.dark, Brightness.light]) {
      testWidgets('splits without zones are not grey, $b', (tester) async {
        await loadRunSoloFonts();
        final theme = runSoloTheme(brightness: b);
        final tokens = theme.extension<RunSoloTokens>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SplitsBars(
                title: 'PACE PER KM',
                units: Units.km,
                noHrColor: (t) => t.typeFree,
                bars: const [
                  SplitBar(label: '1', paceSecPerKm: 360),
                  SplitBar(label: '2', paceSecPerKm: 365),
                ],
              ),
            ),
          ),
        );
        final box = tester.renderObject(
          find
              .descendant(
                of: find.byType(SplitsBars),
                matching: find.byType(CustomPaint),
              )
              .first,
        );
        expect(box, paints..rrect(color: tokens.typeFree));
        expect(tokens.typeFree, isNot(tokens.inkMuted));
      });
    }
  });

  group('S8 formats', () {
    test('one pace formatter: m:ss/km, no space', () {
      expect(Fmt.paceUnit(284, Units.km), '4:44/km');
      expect(Fmt.paceUnit(284, Units.km), isNot(contains(' ')));
    });
  });

  group('S9 onboarding', () {
    testWidgets('the privacy paragraph is a tap away, not clipped', (
      tester,
    ) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: const PermissionsScreen(onboarding: true),
      );
      await pumpTimes(tester, 4);
      expect(find.text(kPrivacyParagraph), findsNothing);
      expect(
        find.byKey(const ValueKey('onboarding-privacy-short')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-privacy-more')));
      await pumpTimes(tester, 4);
      expect(find.text(kPrivacyParagraph), findsOneWidget);
    });

    for (final b in [Brightness.dark, Brightness.light]) {
      testWidgets('DENIED pill text reads on its fill, $b', (tester) async {
        await loadRunSoloFonts();
        final theme = runSoloTheme(brightness: b);
        final tokens = theme.extension<RunSoloTokens>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: StatusPill(label: 'DENIED', tone: PillTone.danger),
            ),
          ),
        );
        final fg = tester.widget<Text>(find.text('DENIED')).style!.color!;
        expect(contrastRatio(fg, tokens.semDanger), greaterThanOrEqualTo(4.5));
      });
    }
  });

  group('S11 history', () {
    testWidgets('tabs at 13 sp or more, every filter chip on screen', (
      tester,
    ) async {
      final r = freeRunFile(n: 3, start: DateTime(2026, 9, 22, 7));
      await pumpApp(
        tester,
        fakeServices(files: [r]),
        home: const HistoryScreen(),
      );
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester, 4);
      for (final chip in [
        'All',
        'Intervals',
        'Laps',
        'Free',
        'Trail',
        'Tests',
      ]) {
        final rect = tester.getRect(find.text(chip));
        expect(rect.right, lessThanOrEqualTo(360), reason: chip);
      }
      for (final label in ['LEADERBOARD', 'CHRONOLOGICAL', 'TRENDS']) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.style!.fontSize, greaterThanOrEqualTo(13), reason: label);
        expect(
          tester.getRect(find.text(label)).right,
          lessThanOrEqualTo(360),
          reason: label,
        );
      }
    });
  });

  group('S12 run detail', () {
    testWidgets('the app bar does not repeat the heading', (tester) async {
      final r = freeRunFile(n: 3, start: DateTime(2026, 9, 22, 7));
      await pumpApp(
        tester,
        fakeServices(files: [r]),
        home: RunDetailScreen(runId: r.id),
      );
      await pumpTimes(tester, 6);
      final bar = find.byType(RunAppBar);
      expect(
        find.descendant(of: bar, matching: find.text('RUN')),
        findsOneWidget,
      );
    });
  });
}
