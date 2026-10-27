import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/recording_controller.dart';
import 'package:run_solo/state/voice_coach_plan.dart';
import 'package:run_solo/state/inrun_moments.dart';
import 'package:run_solo/widgets/inrun_prompt.dart';

import '../helpers.dart';
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

  testWidgets('a goal prompt shows its own button labels', (tester) async {
    final fake = await openRun(tester);
    await open(
      tester,
      fake,
      prompt(
        kind: 'behindTarget',
        text: '20 seconds behind 24:30, slipping. Keep chasing or new target?',
        options: const ['Keep chasing', 'New target'],
      ),
    );
    expect(find.text('KEEP CHASING'), findsOneWidget);
    expect(find.text('NEW TARGET'), findsOneWidget);
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

  group('the screen follows the voice', () {
    Future<(FakeRecorderGateway, RecordingController)> startRun(
      WidgetTester tester, {
      CoachTarget? target,
      RecordMode mode = RecordMode.free,
      SessionSpec? spec,
    }) async {
      final fake = FakeRecorderGateway(now: now)
        ..scriptedHr = 150
        ..liveSecPerKm = 300;
      final services = fakeServices(recorder: fake);
      services.recording.coachTarget = target;
      await services.recording.start(mode, spec, Units.km);
      await pumpApp(tester, services, pushRoute: Routes.recording);
      await pumpTimes(tester, 6);
      return (fake, services.recording);
    }

    const base = CoachTarget(paceSecPerKm: 300);

    testWidgets('a push moves the screen band with the voice target', (
      tester,
    ) async {
      final (fake, ctl) = await startRun(tester, target: base);
      await open(tester, fake, prompt(id: 1));
      fake.emitPromptResolved(
        PromptResolvedEvent(
          id: 1,
          choice: 'push',
          source: 'tap',
          paceFactor: 0.97,
        ),
      );
      await tester.pump();
      expect(ctl.coachTarget!.paceSecPerKm, closeTo(291, 1e-9));
      expect(ctl.coachTarget!.bandSecPerKm, base.bandSecPerKm);
    });

    testWidgets('a hold, a timeout and a push that was not applied leave the '
        'band alone', (tester) async {
      final (fake, ctl) = await startRun(tester, target: base);
      await open(tester, fake, prompt(id: 1));
      fake.emitPromptResolved(
        PromptResolvedEvent(id: 1, choice: 'hold', source: 'timeout'),
      );
      await tester.pump();
      expect(ctl.coachTarget!.paceSecPerKm, 300);
      // A push the coach dropped (the runner was too far off) arrives with factor 1.
      await open(tester, fake, prompt(id: 2));
      fake.emitPromptResolved(
        PromptResolvedEvent(id: 2, choice: 'push', source: 'tap'),
      );
      await tester.pump();
      expect(ctl.coachTarget!.paceSecPerKm, 300);
    });

    testWidgets('an ease off loosens it and a later answer starts from the '
        'plan target again', (tester) async {
      final (fake, ctl) = await startRun(tester, target: base);
      await open(tester, fake, prompt(id: 1));
      fake.emitPromptResolved(
        PromptResolvedEvent(
          id: 1,
          choice: 'ease',
          source: 'headset',
          paceFactor: 1.04,
        ),
      );
      await tester.pump();
      expect(ctl.coachTarget!.paceSecPerKm, closeTo(312, 1e-9));
      await open(tester, fake, prompt(id: 2));
      fake.emitPromptResolved(
        PromptResolvedEvent(
          id: 2,
          choice: 'push',
          source: 'tap',
          paceFactor: 0.97,
        ),
      );
      await tester.pump();
      expect(
        ctl.coachTarget!.paceSecPerKm,
        closeTo(291, 1e-9),
        reason: '0.97 of the plan, not of 312',
      );
    });

    testWidgets('a run with no target has no band to move', (tester) async {
      final (fake, ctl) = await startRun(tester);
      await open(tester, fake, prompt(id: 1));
      fake.emitPromptResolved(
        PromptResolvedEvent(
          id: 1,
          choice: 'push',
          source: 'tap',
          paceFactor: 0.97,
        ),
      );
      await tester.pump();
      expect(ctl.coachTarget, isNull);
    });

    testWidgets('a screen that missed the event gets the buttons back from the '
        'status snapshot', (tester) async {
      final (fake, ctl) = await startRun(tester);
      expect(button(0), findsNothing);
      fake.openPrompt = prompt(id: 9);
      await ctl.refreshStatus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(button(0), findsOneWidget);
      expect(ctl.prompt.value!.id, 9);
      await tester.tap(button(0));
      await tester.pump();
      expect(fake.promptAnswers, [(9, 0)]);
    });

    testWidgets('a stale snapshot after a tap never brings the buttons back', (
      tester,
    ) async {
      final (fake, ctl) = await startRun(tester);
      await open(tester, fake, prompt(id: 3));
      // Native has not resolved yet: its snapshot still carries the prompt.
      fake.openPrompt = prompt(id: 3);
      await tester.tap(button(0));
      await tester.pump();
      expect(ctl.prompt.value, isNull);
      await ctl.refreshStatus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.prompt.value, isNull);
      expect(button(0), findsNothing);
      expect(fake.promptAnswers, [(3, 0)]);
    });

    testWidgets('a snapshot landing after the resolved event stays closed, '
        'and the next prompt still opens', (tester) async {
      final (fake, ctl) = await startRun(tester);
      await open(tester, fake, prompt(id: 6));
      fake.emitPromptResolved(
        PromptResolvedEvent(
          id: 6,
          choice: 'hold',
          source: 'timeout',
          paceFactor: 1.0,
          oneRep: false,
        ),
      );
      await tester.pump();
      expect(ctl.prompt.value, isNull);
      fake.openPrompt = prompt(id: 6);
      await ctl.refreshStatus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.prompt.value, isNull);
      fake.openPrompt = prompt(id: 7);
      await ctl.refreshStatus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.prompt.value?.id, 7);
      expect(button(0), findsOneWidget);
    });

    testWidgets('the buttons stay up while the run is paused', (tester) async {
      final (fake, ctl) = await startRun(tester);
      await open(tester, fake, prompt(id: 4));
      await fake.pause();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(ctl.prompt.value, isNotNull);
      expect(button(0), findsOneWidget);
      await tester.tap(button(1));
      await tester.pump();
      expect(fake.promptAnswers, [(4, 1)]);
    });

    testWidgets('the bar waits out the question before it runs down', (
      tester,
    ) async {
      final (fake, _) = await startRun(tester);
      fake.emitPrompt(
        PromptEvent(
          id: 5,
          kind: 'last2k',
          text: 'a long question',
          options: const ['Push', 'Hold'],
          timeoutMs: 8000,
          km: 3,
          leadMs: 4000,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      double bar() => tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('inrun-prompt-bar')),
          )
          .value!;
      await tester.pump(const Duration(seconds: 3));
      expect(bar(), 1.0, reason: 'still being said');
      await tester.pump(const Duration(seconds: 5));
      expect(bar(), inInclusiveRange(0.4, 0.75));
    });
  });

  // 26-Oct goal-run voice: the goal prompts are the longest questions; at a large
  // text scale on a short phone the ellipsis must not cut what Push means.
  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'the longest goal prompt shows whole at text scale $scale on 360 x 640',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 640 * 3.0);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final fake = await openRun(tester);
        await step(tester, fake, 900);
        // The run screen under the scrim overflows at 1.5x on this phone (not the card, not ours): clear it, then look at the card.
        tester.takeException();
        await open(tester, fake, prompt(text: goalPromptLongest));
        final text = find.byKey(const ValueKey('inrun-prompt-text'));
        final para = tester.renderObject<RenderParagraph>(text);
        expect(
          para.didExceedMaxLines,
          isFalse,
          reason: 'ellipsis cut the question',
        );
        // And it fits the room the card gives it: nothing paints over the bar.
        final room = tester.getRect(
          find.ancestor(of: text, matching: find.byType(Expanded)).first,
        );
        expect(
          tester.getRect(text).bottom,
          lessThanOrEqualTo(room.bottom + 0.5),
        );
        expect(button(0), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// The longest goal-time last-2-km prompt (CoachPrompter, 16 words).
const goalPromptLongest =
    '2.5 k to go, 1 minute 59 seconds under 1:27:59, shrinking. Faster finish, or same pace?';
