import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/health_gateway.dart';
import 'package:run_solo/platform/platform_api.g.dart';
import 'package:run_solo/screens/settings_screen.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Settings > Send runs to > Health Connect: "Send all past runs".
void main() {
  Finder switchFor(String label) => find.descendant(
    of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
    matching: find.byType(Switch),
  );

  Future<FakeHealthGateway> open(
    WidgetTester tester, {
    FakeHealthGateway? health,
    int runs = 3,
    bool on = true,
  }) async {
    final g = health ?? FakeHealthGateway();
    final files = [
      for (var i = 0; i < runs; i++)
        freeRunFile(
          n: 90 + i,
          start: DateTime.utc(2026, 9, 1 + i, 6),
          seconds: 600,
        ),
    ];
    await pumpApp(
      tester,
      fakeServices(health: g, files: files),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('SEND RUNS TO'));
    if (on) {
      await tester.tap(switchFor('Health Connect'));
      await pumpTimes(tester, 4);
    }
    return g;
  }

  testWidgets('no button while the switch is off', (tester) async {
    await open(tester, on: false);
    expect(find.text('Send all past runs'), findsNothing);
  });

  testWidgets('confirms with the count, then writes every run once', (
    tester,
  ) async {
    final g = await open(tester);
    await scrollTo(tester, find.text('Send all past runs'));
    await tester.tap(find.text('Send all past runs'));
    await pumpTimes(tester, 4);
    expect(find.text('Send 3 runs to Health Connect?'), findsOneWidget);
    expect(g.written, isEmpty);
    await tester.tap(find.byKey(const ValueKey('backfill-confirm')));
    await pumpTimes(tester, 10);
    expect(g.written.length, 3);
    expect({for (final w in g.written) w.clientRecordId}.length, 3);
    expect(find.text('Sent 3 runs to Health Connect.'), findsOneWidget);
    expect(find.byKey(const ValueKey('backfill-progress')), findsNothing);
  });

  testWidgets('cancel writes nothing', (tester) async {
    final g = await open(tester);
    await scrollTo(tester, find.text('Send all past runs'));
    await tester.tap(find.text('Send all past runs'));
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('backfill-cancel')));
    await pumpTimes(tester, 4);
    expect(g.written, isEmpty);
  });

  testWidgets('running it twice reuses the run ids (upsert)', (tester) async {
    final g = await open(tester, runs: 2);
    for (var pass = 0; pass < 2; pass++) {
      await scrollTo(tester, find.text('Send all past runs'));
      await tester.tap(find.text('Send all past runs'));
      await pumpTimes(tester, 4);
      await tester.tap(find.byKey(const ValueKey('backfill-confirm')));
      await pumpTimes(tester, 10);
    }
    expect(g.written.length, 4);
    expect({for (final w in g.written) w.clientRecordId}.length, 2);
  });

  testWidgets('permission lost: asks, and stops with a reason when refused', (
    tester,
  ) async {
    final g = await open(tester);
    g.coreGranted = false;
    g.grantCoreOnRequest = false;
    await scrollTo(tester, find.text('Send all past runs'));
    await tester.tap(find.text('Send all past runs'));
    await pumpTimes(tester, 4);
    expect(find.textContaining('Send 3 runs'), findsNothing);
    expect(
      find.textContaining('Allow Run Supreme to write', skipOffstage: false),
      findsOneWidget,
    );
    expect(g.written, isEmpty);
  });

  testWidgets('failed writes are counted and said', (tester) async {
    final g = await open(tester);
    g.outcome = HealthWriteOutcome.failed;
    await scrollTo(tester, find.text('Send all past runs'));
    await tester.tap(find.text('Send all past runs'));
    await pumpTimes(tester, 4);
    await tester.tap(find.byKey(const ValueKey('backfill-confirm')));
    await pumpTimes(tester, 10);
    expect(find.textContaining('Sent 0 of 3.'), findsOneWidget);
  });
}
