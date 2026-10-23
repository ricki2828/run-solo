import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/inrun_moments.dart';
import 'package:run_solo/widgets/inrun_prompt.dart';

import 'inrun_moment_test.dart' show moment, openRun, step;

/// The mid-run two-button coach prompt on the record screen (decisions
/// 22-Oct): the voice asks, the screen shows two big buttons, one tap answers,
/// native owns the 8 s clock. The overlay never decides and never stacks on a
/// moment.
PromptEvent prompt({
  int id = 1,
  String kind = 'last2k',
  String text = '2 k to go, 8 seconds up on your best 5K. Push or hold?',
  List<String> options = const ['Push', 'Hold'],
  int km = 3,
}) => PromptEvent(
  id: id,
  kind: kind,
  text: text,
  options: options,
  timeoutMs: 8000,
  km: km,
);

Finder button(int i) => find.byKey(ValueKey('inrun-prompt-$i'));

Future<void> open(
  WidgetTester tester,
  FakeRecorderGateway fake,
  PromptEvent e,
) async {
  fake.emitPrompt(e);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('a prompt shows its question and two answers', (tester) async {
    final fake = await openRun(tester);
    await step(tester, fake, 30);
    expect(button(0), findsNothing);
    await open(tester, fake, prompt());
    expect(button(0), findsOneWidget);
    expect(button(1), findsOneWidget);
    expect(find.text('PUSH'), findsOneWidget);
    expect(find.text('HOLD'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('inrun-prompt-text'))).data,
      '2 k to go, 8 seconds up on your best 5K. Push or hold?',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('inrun-prompt-eyebrow')))
          .data,
      'LAST STRETCH',
    );
  });

  testWidgets('one tap answers with its button and the buttons go at once', (
    tester,
  ) async {
    final fake = await openRun(tester);
    await open(tester, fake, prompt(id: 7));
    await tester.tap(button(1));
    await tester.pump();
    expect(fake.promptAnswers, [(7, 1)]);
    expect(button(0), findsNothing);
    // A second tap on nothing sends nothing.
    await tester.pump(const Duration(seconds: 1));
    expect(fake.promptAnswers, hasLength(1));
  });

  testWidgets('the first button is index 0 and a push is not a hold', (
    tester,
  ) async {
    final fake = await openRun(tester);
    await open(tester, fake, prompt(id: 2));
    await tester.tap(button(0));
    await tester.pump();
    expect(fake.promptAnswers, [(2, 0)]);
  });

  testWidgets('native timing out clears the buttons (the resolved event)', (
    tester,
  ) async {
    final fake = await openRun(tester);
    await open(tester, fake, prompt(id: 3));
    expect(button(0), findsOneWidget);
    fake.emitPromptResolved(
      PromptResolvedEvent(id: 3, choice: 'hold', source: 'timeout'),
    );
    await tester.pump();
    expect(button(0), findsNothing);
    expect(fake.promptAnswers, isEmpty, reason: 'the app answered nothing');
  });

  testWidgets('a resolved event for another prompt leaves this one open', (
    tester,
  ) async {
    final fake = await openRun(tester);
    await open(tester, fake, prompt(id: 5));
    fake.emitPromptResolved(
      PromptResolvedEvent(id: 4, choice: 'push', source: 'headset'),
    );
    await tester.pump();
    expect(button(0), findsOneWidget);
    fake.emitPromptResolved(
      PromptResolvedEvent(id: 5, choice: 'push', source: 'headset'),
    );
    await tester.pump();
    expect(button(0), findsNothing);
  });

  testWidgets(
    'a lost resolved event cannot strand the buttons (safety timer)',
    (tester) async {
      final fake = await openRun(tester);
      await open(tester, fake, prompt(id: 6));
      await step(tester, fake, 9);
      expect(button(0), findsOneWidget, reason: 'inside the window and grace');
      await step(tester, fake, 3);
      expect(button(0), findsNothing);
    },
  );

  testWidgets('never stacked: a prompt clears a moment and drops the next', (
    tester,
  ) async {
    final fake = await openRun(tester);
    await step(tester, fake, 340); // km 1 moment
    expect(moment(InrunMomentKind.distanceMark), findsOneWidget);
    await open(tester, fake, prompt());
    expect(moment(InrunMomentKind.distanceMark), findsNothing);
    expect(button(0), findsOneWidget);
    // km 2 (at 600 s) arrives only after the window: the prompt is gone after
    // its grace and no moment was ever drawn over it.
    await step(tester, fake, 255);
    expect(button(0), findsNothing);
  });

  testWidgets(
    'the buttons are big: half the width each and at least 160 tall',
    (tester) async {
      final fake = await openRun(tester);
      tester.view.physicalSize = const Size(1080, 1920); // 360 x 640
      await open(tester, fake, prompt());
      final a = tester.getSize(button(0));
      final b = tester.getSize(button(1));
      expect(
        a.height,
        greaterThanOrEqualTo(InrunPromptOverlay.buttonMinHeight),
      );
      expect(a.height, b.height);
      expect(a.width, closeTo(b.width, 0.01));
      expect(a.width, greaterThan(150));
      // The question is at the number floor, the answers bigger.
      final text = tester.widget<Text>(
        find.byKey(const ValueKey('inrun-prompt-text')),
      );
      expect(text.style!.fontSize, greaterThanOrEqualTo(36));
      final label = tester.widget<Text>(find.text('PUSH'));
      expect(label.style!.fontSize, greaterThanOrEqualTo(56));
    },
  );

  testWidgets('the countdown bar runs down the prompt window', (tester) async {
    final fake = await openRun(tester);
    await open(tester, fake, prompt());
    double bar() => tester
        .widget<LinearProgressIndicator>(
          find.byKey(const ValueKey('inrun-prompt-bar')),
        )
        .value!;
    final early = bar();
    await tester.pump(const Duration(seconds: 4));
    final mid = bar();
    expect(early, greaterThan(0.9));
    expect(mid, inInclusiveRange(0.3, 0.55));
  });

  testWidgets('the ease off variant: push or ease off', (tester) async {
    final fake = await openRun(tester);
    await open(
      tester,
      fake,
      prompt(
        kind: 'behindTarget',
        text: '20 seconds behind the target. Push or ease off?',
        options: const ['Push', 'Ease off'],
      ),
    );
    expect(find.text('EASE OFF'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('inrun-prompt-eyebrow')))
          .data,
      'BEHIND',
    );
    await tester.tap(button(1));
    await tester.pump();
    expect(fake.promptAnswers.single, (1, 1));
  });

  test('every trigger has its own eyebrow', () {
    expect(InrunPromptOverlay.eyebrow('last2k'), 'LAST STRETCH');
    expect(InrunPromptOverlay.eyebrow('behindTarget'), 'BEHIND');
    expect(InrunPromptOverlay.eyebrow('aheadOfPb'), 'AHEAD');
    expect(InrunPromptOverlay.eyebrow('betweenReps'), 'NEXT REP');
    expect(InrunPromptOverlay.eyebrow('future'), 'COACH');
  });
}
