import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/coaching.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/coaching.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// CR2 (A10.4, A10.6, A10.7): FROM THIS RUN on the result, TRY NEXT on
/// Home, and Settings → Profile.
void main() {
  final d1 = DateTime.utc(2026, 8, 1, 6);
  DateTime day(int n) => d1.add(Duration(days: n));

  engine.RunFile tenK(int n, int first, int second) => generator
      .generate(
        synth.SyntheticSpec(
          name: 'cr2ui_$n',
          id: runId(n),
          mode: engine.RunMode.free,
          lapStyle: synth.LapStyle.none,
          start: day(3 * n),
          segments: [
            synth.Segment.free(first * 51 ~/ 10, speedFor(first)),
            synth.Segment.free(second * 51 ~/ 10, speedFor(second)),
          ],
        ),
      )
      .run;

  List<engine.RunFile> fading() => [
    tenK(1, 300, 330),
    tenK(2, 300, 330),
    tenK(3, 300, 332),
  ];

  testWidgets('the result shows FROM THIS RUN: the research-based line, then '
      'the suggestion, saved to Home', (tester) async {
    final files = fading();
    await pumpApp(
      tester,
      fakeServices(files: files),
      pushRoute: Routes.verdict,
      pushArguments: files.last.id,
    );
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(seconds: 2));
    final section = find.byKey(const ValueKey('coaching'));
    await tester.scrollUntilVisible(
      section,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('FROM THIS RUN'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('coaching-observation')))
          .data,
      contains('research-based'),
    );
    expect(
      find.text(
        'Next time: try a longer easy run this week, Zone 2, 60 to 75 min. '
        'Saved to Home.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('no coaching: no heading at all', (tester) async {
    final one = tenK(1, 300, 300);
    await pumpApp(
      tester,
      fakeServices(files: [one]),
      pushRoute: Routes.verdict,
      pushArguments: one.id,
    );
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('FROM THIS RUN'), findsNothing);
  });

  testWidgets('Home: TRY NEXT with its reason, no "Set it up" for a Zone 2 '
      'run; dismissed, it stays gone', (tester) async {
    final services = fakeServices(files: fading());
    await pumpApp(tester, services, home: HomeScreen(now: now));
    await pumpTimes(tester, 8);
    expect(find.byKey(const ValueKey('try-next')), findsOneWidget);
    expect(find.text(engine.CoachSuggestion.zone2Text), findsOneWidget);
    expect(find.textContaining('no run of an hour or more'), findsOneWidget);
    expect(find.byKey(const ValueKey('try-next-set-up')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('try-next-dismiss')));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('try-next')), findsNothing);
    expect(services.settings.settings.tryNextDismissed, runId(3));
  });

  test('"Set it up": a 4x4 with one fewer rep, a 400s preset with one '
      'fewer, a Norwegian 4x4 for a flat test; nothing for a custom key', () {
    TryNext next(engine.SuggestionKind k, {String? key}) => TryNext(
      runId: 'r',
      suggestion: engine.CoachSuggestion(k, 'x', key: key),
      reason: '',
    );
    const s = AppSettings(reps: 5, lastMode: RecordMode.free);
    final fourKey = engine.SessionCatalogue.byId(
      engine.SessionSpec.norwegian4x4Id,
    )!.defaults.comparisonKey;
    final four = tryNextSetUp(
      next(engine.SuggestionKind.fewerReps, key: fourKey),
    )!(s);
    expect(four.reps, 4);
    expect(four.lastMode, RecordMode.intervals);
    expect(four.sessionId, engine.SessionSpec.norwegian4x4Id);

    final p400 = engine.SessionCatalogue.byId('400s')!;
    final fours = tryNextSetUp(
      next(engine.SuggestionKind.fewerReps, key: p400.defaults.comparisonKey),
    )!(s);
    expect(fours.sessionId, '400s');
    expect(fours.presetEdits['400s']!.reps, p400.defaultReps - 1);

    final nor = tryNextSetUp(next(engine.SuggestionKind.norwegian4x4))!(s);
    expect(nor.sessionId, engine.SessionSpec.norwegian4x4Id);
    expect(
      tryNextSetUp(next(engine.SuggestionKind.fewerReps, key: 'd999x*')),
      isNull,
    );
    expect(tryNextSetUp(next(engine.SuggestionKind.zone2LongRun)), isNull);
  });

  testWidgets('Settings → Profile: sex for fitness norms, Not set by '
      'default, saved on pick', (tester) async {
    final services = fakeServices();
    await pumpApp(tester, services, home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    final row = find.byKey(const ValueKey('profile-sex'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: row, matching: find.text('Not set')),
      findsOneWidget,
    );
    await tester.tap(row);
    await pumpTimes(tester, 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('It stays on this phone.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sex-female')));
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(milliseconds: 600));
    expect(services.settings.settings.profileSex, ProfileSex.female);
    expect(services.settings.settings.profileSex.norms, engine.NormsSex.female);
    expect(
      AppSettings.fromJson(services.settings.settings.toJson()).profileSex,
      ProfileSex.female,
    );
  });
}
