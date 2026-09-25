import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/fix_laps_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Fix laps (plan §5/§6): the missed-press fixture is rescued by the
/// generator's declared edit; drop / reset write the sidecar and re-run the
/// engine; merge is unavailable on the last lap.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);

  String headline(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('fix-laps-headline')))
      .data!;

  Future<void> openFixLaps(WidgetTester tester, services, String id) async {
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.fixLaps,
      pushArguments: id,
    );
    await pumpTimes(tester, 6);
    expect(find.byType(FixLapsScreen), findsOneWidget);
  }

  testWidgets('missed press → NO VERDICT; the rescue edit restores it', (
    tester,
  ) async {
    final synthetic = fourByFourSynthetic(n: 1, start: d1, missedPress: true);
    final r = synthetic.run;
    final services = fakeServices(files: [r]);
    await openFixLaps(tester, services, r.id);
    expect(headline(tester), 'NO VERDICT');
    expect(synthetic.expected.rescueEdits, isNotEmpty);
    for (final e in synthetic.expected.rescueEdits) {
      await services.history.applyLapEdit(r.id, e);
    }
    // Re-open: the screen loads once on entry.
    Navigator.of(tester.element(find.byType(FixLapsScreen))).pop();
    await settleAnimations(tester);
    Navigator.of(tester.element(find.byType(Scaffold).first))
        .pushNamed(Routes.fixLaps, arguments: r.id);
    await settleAnimations(tester);
    await pumpTimes(tester, 6);
    expect(headline(tester), 'BASELINE SET');
    expect(find.text('RESET'), findsOneWidget);
  });

  testWidgets('sheet: drop a rep through the UI, then RESET clears edits', (
    tester,
  ) async {
    final r = fourByFourFile(n: 2, start: d1);
    final services = fakeServices(files: [r]);
    await openFixLaps(tester, services, r.id);
    expect(headline(tester), 'BASELINE SET');
    await tester.tap(find.text('REP 1'));
    await settleAnimations(tester);
    expect(find.text('Drop it'), findsOneWidget);
    expect(find.text('SPLIT HERE'), findsOneWidget);
    await tester.tap(find.text('Drop it'));
    await settleAnimations(tester);
    await pumpTimes(tester, 6);
    final d = await services.history.load(r.id);
    expect(d!.sidecar.lapEdits.length, 1);
    expect(d.sidecar.lapEdits.single.isDrop, isTrue);
    expect(d.analysis.fourByFour!.droppedRepCount, 1);
    expect(find.text('REP 1 · DROPPED'), findsOneWidget);
    await tester.tap(find.text('RESET'));
    await pumpTimes(tester, 6);
    final d2 = await services.history.load(r.id);
    expect(d2!.sidecar.lapEdits, isEmpty);
    expect(d2.sidecar.verdictHistory, isNotEmpty, reason: 'old verdict kept');
    expect(find.text('RESET'), findsNothing);
  });

  testWidgets('merge is unavailable on the last lap', (tester) async {
    final r = fourByFourFile(n: 3, start: d1);
    await openFixLaps(tester, fakeServices(files: [r]), r.id);
    await scrollTo(tester, find.text('COOL-DOWN'));
    await tester.tap(find.text('COOL-DOWN').last);
    await settleAnimations(tester);
    final merge = find.ancestor(
      of: find.text('Merge with next'),
      matching: find.byType(InkWell),
    );
    expect(tester.widget<InkWell>(merge.first).onTap, isNull);
  });

  testWidgets('an edit that cannot apply is refused, nothing written', (
    tester,
  ) async {
    final r = fourByFourFile(n: 4, start: d1);
    final services = fakeServices(files: [r]);
    await openFixLaps(tester, services, r.id);
    await expectLater(
      () => services.history.applyLapEdit(r.id, const engine.LapEdit.merge(99)),
      throwsA(isA<engine.LapEditException>()),
    );
    final d = await services.history.load(r.id);
    expect(d!.sidecar.lapEdits, isEmpty, reason: 'nothing written');
  });
}
