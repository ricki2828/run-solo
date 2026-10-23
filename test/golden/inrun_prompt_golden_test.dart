import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';

import '../helpers.dart' show fourByFourSpec;
import '../screens/inrun_moment_test.dart' show openRun, step;
import '../screens/inrun_prompt_test.dart' show open, prompt;

/// The mid-run two-button coach prompt (decisions 22-Oct), portrait: the
/// question on the receded run screen and two half-screen buttons. PNGs come
/// from the CI goldens release (see the brief).
Future<void> shot(
  WidgetTester tester,
  String name, {
  double height = 800,
}) async {
  tester.view.physicalSize = Size(1080, height * 3.0);
  await tester.pump(const Duration(milliseconds: 100));
  final file = File('test/golden/goldens/$name.png');
  expect(
    file.existsSync() || autoUpdateGoldenFiles,
    isTrue,
    reason: 'golden $name.png missing: commit it from the CI goldens release',
  );
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  testWidgets('prompt: last 2 km, push or hold', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 900);
    await open(tester, fake, prompt());
    await shot(tester, 'inrun_prompt_last2k_360x800');
  });

  testWidgets('prompt: last 2 km on a short phone', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 900);
    await open(tester, fake, prompt());
    await shot(tester, 'inrun_prompt_last2k_360x640', height: 640);
  });

  testWidgets('prompt: falling behind, push or ease off', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 900);
    await open(
      tester,
      fake,
      prompt(
        kind: 'behindTarget',
        text: '20 seconds behind the target. Push or ease off?',
        options: const ['Push', 'Ease off'],
      ),
    );
    await shot(tester, 'inrun_prompt_behind_360x800');
  });

  testWidgets('prompt: between reps', (tester) async {
    final fake = await openRun(
      tester,
      mode: RecordMode.intervals,
      spec: fourByFourSpec(),
    );
    await fake.lap(LapSource.button);
    await tester.pump();
    await step(tester, fake, 240);
    await open(
      tester,
      fake,
      prompt(
        kind: 'betweenReps',
        text: 'Rep 2 done. Push the next one or hold?',
        km: 2,
      ),
    );
    await shot(tester, 'inrun_prompt_reps_360x800');
  });
}
