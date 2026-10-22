import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/counted_runs_screen.dart';

import '../helpers.dart';
import 'counted_runs_fixtures.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: CountedRunsScreen(candidates: countedFixtures(), units: Units.km),
    );
    await useTallPhoneView(tester);
    await pumpTimes(tester, 4);
    expect(tester.takeException(), isNull);
  }

  String text(WidgetTester tester, String key) =>
      (tester.widget(find.byKey(ValueKey(key))) as Text).data!;

  testWidgets('header counts the runs that count', (tester) async {
    await pump(tester);
    expect(text(tester, 'counted-header'), '3 of 6 runs count toward MID');
  });

  testWidgets('a counted run shows its 5K window', (tester) async {
    await pump(tester);
    expect(text(tester, 'counted-r-ok-5K'), '5K  24:48');
    expect(
      text(tester, 'counted-r-ok-status'),
      'Counts for MID and Estimated Times',
    );
  });

  testWidgets('a bridged GPS gap is noted', (tester) async {
    await pump(tester);
    expect(find.text('GPS gap bridged (45 s)'), findsOneWidget);
    expect(text(tester, 'counted-r-bridged-5K'), '5K  25:30');
  });

  testWidgets('an under 5 km run says so', (tester) async {
    await pump(tester);
    expect(text(tester, 'counted-r-short-status'), 'Under 5 km');
  });

  testWidgets('a long pause and a GPS dropout say why in plain words', (
    tester,
  ) async {
    await pump(tester);
    expect(text(tester, 'counted-r-paused-status'), 'Paused for over a minute');
    expect(
      text(tester, 'counted-r-dropped-status'),
      'GPS dropped 4 times, 3 min in all',
    );
  });

  testWidgets('a trail run is hills-adjusted and rows run newest first', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('hills-adjusted'), findsOneWidget);
    final ys = [
      for (final id in ['r-ok', 'r-bridged', 'r-short', 'r-paused'])
        tester.getTopLeft(find.byKey(ValueKey('counted-$id'))).dy,
    ];
    expect(ys, [...ys]..sort());
  });
}
