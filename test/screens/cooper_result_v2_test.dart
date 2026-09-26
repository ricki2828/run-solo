import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/cooper_result_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/widgets/vo2_trend.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// CO2: the 12-minute test result v2 (plan §3.3, design A10.5), fed by a
/// FileRunStore (W5b: the past tests come from index rows, never an
/// analysis): the VO2-by-test trend and "People your age" (behind its
/// flag).
void main() {
  final d1 = DateTime.utc(2026, 6, 10, 6);
  final d2 = DateTime.utc(2026, 7, 15, 6);
  final d3 = DateTime.utc(2026, 9, 20, 6);
  final a = cooperTestFile(n: 1, start: d1, mps: 3.8);
  final b = cooperTestFile(n: 2, start: d2, mps: 3.9);
  final c = cooperTestFile(n: 3, start: d3, mps: 4.1);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('runsolo-co2-'));
  tearDown(() {
    debugPeopleYourAge = ({required vo2, required age, sex}) =>
        engine.ResearchNorms.peopleYourAge(vo2: vo2, age: age, sex: sex);
    dir.deleteSync(recursive: true);
  });

  Future<void> open(
    WidgetTester tester,
    List<engine.RunFile> files,
    String id, {
    int? birthYear = 1981,
  }) async {
    final store = FileRunStore(Directory('${dir.path}/runs'));
    await tester.runAsync(() async {
      await store.importBundles([
        for (final f in files) engine.RunBundle(run: f),
      ]);
      await store.list();
      await store.derivedIdle;
    });
    await pumpApp(
      tester,
      fakeServices(
        history: store,
        settings: AppSettings(onboardingDone: true, birthYear: birthYear),
      ),
      pushRoute: Routes.verdict,
      pushArguments: id,
    );
    // Real file reads: let them land, then build (the trend's list() too).
    Future<void> settle(Finder f) async {
      for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    await settle(find.byType(CooperResultScreen));
    await settle(find.byKey(const ValueKey('cooper-vo2')));
    // The past tests (history.list() off the index) land after the load.
    if (files.length > 1) {
      await settle(find.byKey(const ValueKey('cooper-change')));
    }
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.byType(CooperResultScreen), findsOneWidget);
  }

  final trend = find.byKey(const ValueKey('cooper-result-trend'));

  testWidgets('first test: no trend yet', (tester) async {
    await open(tester, [a], a.id);
    expect(find.byKey(const ValueKey('cooper-vo2')), findsOneWidget);
    expect(trend, findsNothing);
  });

  testWidgets(
    'third test: bars for all three from the index, this one the best',
    (tester) async {
      await open(tester, [a, b, c], c.id);
      await tester.scrollUntilVisible(trend, 200);
      expect(trend, findsOneWidget);
      expect(find.text('VO2 BY TEST'), findsOneWidget);
      final chart = tester.widget<Vo2Bars>(trend);
      expect(chart.values.length, 3);
      // Taller is better: this test is the best, so its bar is the Arc one.
      expect(chart.bestIndex, 2);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('vo2-bars-axis'))).data,
        'Axis starts at VO2 ${Vo2Bars.baselineOf(chart.values)}',
      );
    },
  );

  testWidgets('a slower test: the older best bar is Arc, this one Bone', (
    tester,
  ) async {
    final fast = cooperTestFile(n: 4, start: d1, mps: 4.2);
    final slow = cooperTestFile(n: 5, start: d2, mps: 3.8);
    await open(tester, [fast, slow], slow.id);
    await tester.scrollUntilVisible(trend, 200);
    final chart = tester.widget<Vo2Bars>(trend);
    expect(chart.values.length, 2);
    expect(chart.bestIndex, 0);
    expect(chart.values.last, lessThan(chart.values.first));
  });

  testWidgets('an older test trends only up to itself', (tester) async {
    await open(tester, [a, b, c], b.id);
    await tester.scrollUntilVisible(trend, 200);
    final chart = tester.widget<Vo2Bars>(trend);
    expect(chart.values.length, 2);
  });

  testWidgets('"People your age" stays hidden while the norms are off', (
    tester,
  ) async {
    expect(engine.ResearchNorms.peopleYourAgeEnabled, isFalse);
    await open(tester, [a, b, c], c.id);
    expect(find.byKey(const ValueKey('people-your-age')), findsNothing);
  });

  testWidgets('"People your age" when on: both ranges with sex unset, '
      'labelled research-based, the age from Settings', (tester) async {
    int? seenAge;
    engine.NormsSex? seenSex;
    debugPeopleYourAge = ({required vo2, required age, sex}) {
      seenAge = age;
      seenSex = sex;
      return const engine.PeopleYourAge(
        marks: [(engine.NormsSex.male, 60), (engine.NormsSex.female, 75)],
        line: 'About 60th (men) · 75th (women), 40 to 49',
      );
    };
    await open(tester, [a, b, c], c.id);
    final section = find.byKey(const ValueKey('people-your-age'));
    await tester.scrollUntilVisible(section, 200);
    expect(find.text('PEOPLE YOUR AGE'), findsOneWidget);
    expect(
      find.text('About 60th (men) · 75th (women), 40 to 49'),
      findsOneWidget,
    );
    expect(find.text(engine.ResearchNorms.peopleYourAgeSource), findsOneWidget);
    expect(
      engine.carriesEstimateMarker(engine.ResearchNorms.peopleYourAgeSource),
      isTrue,
    );
    expect(seenAge, 45); // born 1981, tested Sep 2026
    expect(seenSex, isNull);
  });

  testWidgets('no birth year: no "People your age"', (tester) async {
    var asked = false;
    debugPeopleYourAge = ({required vo2, required age, sex}) {
      asked = true;
      return null;
    };
    await open(tester, [a, b, c], c.id, birthYear: null);
    expect(asked, isFalse);
  });
}
