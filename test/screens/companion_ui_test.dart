import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/companion_screen.dart';
import 'package:run_solo/screens/settings_screen.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/widgets/feel_row.dart';

import '../helpers.dart';
import '../run_fixtures.dart';
import '../state/companion_test.dart' show FakeCompanionHttp, enrolNow;

void main() {
  late FakeCompanionHttp http;
  late MemorySecretStore secrets;
  late FakeTransferGateway transfer;
  late CompanionController ctl;

  setUp(() {
    http = FakeCompanionHttp();
    secrets = MemorySecretStore();
    transfer = FakeTransferGateway();
    ctl = CompanionController(
      store: secrets,
      transfer: transfer,
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
    );
  });

  testWidgets('consent: Turn on and Not now, same size, nothing pre-selected', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(companion: ctl, transfer: transfer),
      home: const CompanionScreen(),
    );
    await pumpTimes(tester, 4);
    expect(find.text('RUN COMPANION'), findsOneWidget);
    expect(find.text(kCompanionSent), findsOneWidget);
    expect(find.text(kCompanionWhere), findsOneWidget);
    expect(find.textContaining('30 days'), findsOneWidget);
    await scrollTo(tester, find.text('Read the privacy page'));
    expect(find.text('Read the privacy page'), findsOneWidget);
    // No switch, tick box or radio that could start ticked.
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Radio<Object?>), findsNothing);
    final on = find.byKey(const ValueKey('companion-turn-on'));
    final off = find.byKey(const ValueKey('companion-not-now'));
    expect(tester.getSize(on), tester.getSize(off));
    final onBox = tester
        .widget<Container>(
          find.descendant(of: on, matching: find.byType(Container)).first,
        )
        .decoration;
    final offBox = tester
        .widget<Container>(
          find.descendant(of: off, matching: find.byType(Container)).first,
        )
        .decoration;
    expect(onBox, offBox);
    // Opening the screen enrols nothing and asks nothing.
    expect(http.requests, isEmpty);
    expect(ctl.asked, isFalse);
  });

  testWidgets('the privacy link opens the privacy page', (tester) async {
    await pumpApp(
      tester,
      fakeServices(companion: ctl, transfer: transfer),
      home: const CompanionScreen(),
    );
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.byKey(const ValueKey('companion-privacy')));
    await tester.tap(find.byKey(const ValueKey('companion-privacy')));
    await pumpTimes(tester, 2);
    expect(transfer.opened.single.toString(), kCompanionPrivacyUrl);
  });

  testWidgets('Turn on enrols and lands on what the companion knows', (
    tester,
  ) async {
    final plain = FakeCompanionHttp();
    http.handler = (r) => r.uri.path == '/v1/me'
        ? const CompanionReply(
            200,
            '{"runs_received":[{},{}],"memory":{"goal_type":"first_5k"}}',
          )
        : plain.defaultReply(r);
    await pumpApp(
      tester,
      fakeServices(companion: ctl, transfer: transfer),
      home: const CompanionScreen(),
    );
    await pumpTimes(tester, 4);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('companion-turn-on')));
      for (var i = 0; i < 50 && ctl.phase != CompanionPhase.awaitingCode; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('companion-code')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('companion-code')),
      '123456',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('companion-confirm')));
      for (var i = 0; i < 50 && !ctl.enrolled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await pumpTimes(tester, 6);
    expect(ctl.enrolled, isTrue);
    expect(find.text('WHAT THE COMPANION KNOWS'), findsOneWidget);
    expect(find.text('first 5k'), findsOneWidget);
    expect(find.byKey(const ValueKey('companion-connected')), findsOneWidget);
    await scrollTo(tester, find.byKey(const ValueKey('companion-turn-off')));
    expect(find.byKey(const ValueKey('companion-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('companion-turn-off')), findsOneWidget);
  });

  testWidgets('Delete everything calls DELETE /v1/me and wipes the token', (
    tester,
  ) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl, transfer: transfer),
      home: const CompanionScreen(),
    );
    await pumpTimes(tester, 6);
    await scrollTo(tester, find.byKey(const ValueKey('companion-delete')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('companion-delete')));
      for (var i = 0; i < 50 && ctl.enrolled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await pumpTimes(tester, 4);
    expect(http.to('DELETE', '/v1/me'), hasLength(1));
    expect(await secrets.read(CompanionController.tokenName), isNull);
    expect(find.text('RUN COMPANION'), findsOneWidget);
  });

  testWidgets('Settings shows the Companion row only when the build has it', (
    tester,
  ) async {
    await pumpApp(tester, fakeServices(), home: SettingsScreen(now: now));
    await pumpTimes(tester, 4);
    expect(find.text('Run companion'), findsNothing);
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: SettingsScreen(now: now),
    );
    await pumpTimes(tester, 4);
    await scrollTo(tester, find.text('Run companion'));
    expect(find.text('Off'), findsWidgets);
  });

  group('feel row on the result screen', () {
    final run = fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 24, 6));

    for (final withCompanion in [false, true]) {
      testWidgets(
        'shown and saved with the run, companion ${withCompanion ? 'on' : 'off'}',
        (tester) async {
          if (withCompanion) await tester.runAsync(() => enrolNow(ctl));
          final services = fakeServices(
            files: [run],
            companion: withCompanion ? ctl : null,
          );
          await pumpApp(
            tester,
            services,
            pushRoute: Routes.verdict,
            pushArguments: run.id,
          );
          await pumpTimes(tester, 8);
          await tester.pump(const Duration(seconds: 2));
          await tester.scrollUntilVisible(
            find.byType(FeelRow),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('Easy'), findsOneWidget);
          expect(find.text('Right'), findsOneWidget);
          expect(find.text('Hard'), findsOneWidget);
          for (final k in ['easy', 'right', 'hard']) {
            expect(
              tester.getSize(find.byKey(ValueKey('feel-$k'))).height,
              greaterThanOrEqualTo(48),
            );
          }
          await tester.runAsync(() async {
            await tester.tap(find.byKey(const ValueKey('feel-hard')));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          final saved = await services.history.load(run.id);
          expect(saved!.sidecar.feel, engine.RunFeel.hard);
          // Run not sent yet: the summary will carry it, no PATCH.
          expect(http.to('PATCH', '/v1/runs/${run.id}/feel'), isEmpty);
        },
      );
    }
  });
}
