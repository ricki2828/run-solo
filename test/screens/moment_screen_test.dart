import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/screens/moment_screen.dart';
import 'package:run_solo/state/progress_snapshot.dart';

import '../helpers.dart';

const _moment = Moment(
  id: 'first-5k',
  kind: MomentKind.first,
  eyebrow: 'Your first',
  big: '5K',
  detail: '28:12 on Sunday.',
);

void main() {
  testWidgets('moment shows its figure; Nice closes, Share is offered', (
    tester,
  ) async {
    var shared = 0;
    await pumpApp(
      tester,
      fakeServices(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    MomentScreen(moment: _moment, onShare: () => shared++),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settleAnimations(tester);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byKey(const ValueKey('moment-big')), findsOneWidget);
    expect(find.text('5K'), findsOneWidget);
    expect(find.text('Nice'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('moment-share')));
    expect(shared, 1);
    await tester.tap(find.byKey(const ValueKey('moment-nice')));
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('moment-big')), findsNothing);
  });

  testWidgets('weekly story route shows km, headline and seven bars', (
    tester,
  ) async {
    final story = ProgressSnapshot.sample('month3').story!;
    await pumpApp(
      tester,
      fakeServices(),
      pushRoute: Routes.weeklyStory,
      pushArguments: story,
    );
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('42.6'), findsOneWidget);
    expect(find.byKey(const ValueKey('story-headline')), findsOneWidget);
    for (var i = 0; i < 7; i++) {
      expect(find.byKey(ValueKey('story-bar-$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('story-next')));
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('weekly-story')), findsNothing);
  });
}
