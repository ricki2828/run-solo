import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

void main() {
  testWidgets('first frame (loading) and a null-run snapshot do not throw', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: HomeScreen(now: now, snapshot: ProgressSnapshot.empty),
    );
    expect(tester.takeException(), isNull);
    await pumpTimes(tester, 6);
    expect(find.byKey(const ValueKey('pack-hero')), findsOneWidget);
    expect(find.text('FIND\nYOUR PACK'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-story')), findsNothing);
    expect(find.byKey(const ValueKey('home-ghost')), findsNothing);
    expect(find.text('WEEK 1'), findsOneWidget);
  });

  testWidgets('story button opens the story, ghost shows both labels', (
    tester,
  ) async {
    WeeklyStory? opened;
    await pumpApp(
      tester,
      fakeServices(),
      home: HomeScreen(
        now: now,
        snapshot: ProgressSnapshot.sample('month3'),
        onOpenStory: (s) => opened = s,
      ),
    );
    await pumpTimes(tester, 6);
    await tester.ensureVisible(find.byKey(const ValueKey('home-story')));
    await tester.tap(find.byKey(const ValueKey('home-story')));
    expect(opened, isNotNull);
    expect(find.textContaining(kGhostThenLabel), findsWidgets);
    expect(find.textContaining('WK STREAK'), findsOneWidget);
  });

  testWidgets('story button shows miles when units are miles', (tester) async {
    await pumpApp(
      tester,
      fakeServices(settings: const AppSettings(units: Units.mi)),
      home: HomeScreen(now: now, snapshot: ProgressSnapshot.sample('month3')),
    );
    await pumpTimes(tester, 6);
    expect(find.textContaining(' MI, '), findsOneWidget);
    expect(find.textContaining(' KM, '), findsNothing);
  });
}
