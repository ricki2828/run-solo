import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/weekly_load_page.dart';
import 'package:run_solo/screens/weekly_story_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';

import '../helpers.dart';

/// The weekly story: page 1 (km) and page 2 (YOUR LOAD) in every state, at
/// 360 x 640 and 360 x 800. PNGs come from CI like every golden.
/// Frames for a route push plus the story's own load: the future lands one
/// frame after the first build.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  Future<void> shot(
    WidgetTester tester,
    Widget home,
    String name,
    int h,
  ) async {
    await pumpApp(tester, fakeServices(), home: home);
    tester.view.physicalSize = Size(1080, h * 3.0);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // The entrance is 1.2 s; settle past it.
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    final file = File('test/golden/goldens/$name.png');
    expect(
      file.existsSync() || autoUpdateGoldenFiles,
      isTrue,
      reason: 'golden $name.png missing: commit it from the CI goldens',
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  for (final h in [640, 800]) {
    testWidgets('weekly story page 1 (km) 360x$h', (tester) async {
      await shot(
        tester,
        WeeklyStoryScreen(
          story: ProgressSnapshot.sample('month3').story,
          loadWeeks: engine.WeekLoad.sample(engine.LoadSample.usual),
        ),
        'weekly_story_km_360x$h',
        h,
      );
    });

    for (final stage in engine.LoadSample.values) {
      testWidgets('weekly story load ${stage.name} 360x$h', (tester) async {
        await shot(
          tester,
          WeeklyLoadPage(weeks: engine.WeekLoad.sample(stage)),
          'weekly_story_load_${stage.name}_360x$h',
          h,
        );
      });
    }
  }

  testWidgets('Next opens the load page, Done closes both', (tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: Builder(
        builder: (context) => TextButton(
          key: const ValueKey('open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => WeeklyStoryScreen(
                story: ProgressSnapshot.sample('month3').story,
                loadWeeks: engine.WeekLoad.sample(engine.LoadSample.bigjump),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('story-next')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('weekly-load')), findsOneWidget);
    expect(find.byKey(const ValueKey('load-number')), findsOneWidget);
    expect(find.text('520'), findsOneWidget);
    expect(
      find.textContaining('49% more than your usual week'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('story-done')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('weekly-load')), findsNothing);
    expect(find.byKey(const ValueKey('weekly-story')), findsNothing);
    expect(find.byKey(const ValueKey('open')), findsOneWidget);
  });

  testWidgets('a week with no load to tell keeps Next as it was', (
    tester,
  ) async {
    // fakeServices() has no runs, so the story's week has no load page.
    await pumpApp(
      tester,
      fakeServices(),
      home: WeeklyStoryScreen(story: ProgressSnapshot.sample('month3').story),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('story-next')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('story-next')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('weekly-load')), findsNothing);
  });

  testWidgets('load page words follow the state', (tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: WeeklyLoadPage(
        weeks: engine.WeekLoad.sample(engine.LoadSample.nohr),
      ),
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey('load-nohr-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('load-headline')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('load-why')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('load-why')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('It is an estimate'), findsOneWidget);
  });
}
