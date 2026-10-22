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
    expect(find.text(kCompanionSent, skipOffstage: false), findsOneWidget);
    await scrollTo(tester, find.text('Read the privacy page'));
    expect(find.text(kCompanionCheckins, skipOffstage: false), findsOneWidget);
    expect(find.text(kCompanionWhere, skipOffstage: false), findsOneWidget);
    expect(find.textContaining('30 days', skipOffstage: false), findsOneWidget);
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
    expect(find.byKey(const ValueKey('companion-connected')), findsOneWidget);
    await scrollTo(tester, find.text('first 5k')); // below the memory offer
    expect(find.text('first 5k'), findsOneWidget);
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

  group('show route shape on cards', () {
    Future<void> openKnows(WidgetTester tester) async {
      await tester.runAsync(() => enrolNow(ctl));
      await pumpApp(
        tester,
        fakeServices(companion: ctl, transfer: transfer),
        home: const CompanionScreen(),
      );
      await pumpTimes(tester, 6);
      await scrollTo(
        tester,
        find.byKey(const ValueKey('companion-route-switch')),
      );
    }

    Switch sw(WidgetTester tester) => tester.widget<Switch>(
      find.byKey(const ValueKey('companion-route-switch')),
    );

    testWidgets('starts on, with one line saying what is sent', (tester) async {
      await openKnows(tester);
      expect(sw(tester).value, isTrue);
      expect(find.text('Show route shape on cards'), findsOneWidget);
      expect(find.text(kCompanionRouteBlurb), findsOneWidget);
      expect(kCompanionRouteBlurb, isNot(contains('—')));
      expect(http.to('PUT', '/v1/me/settings'), isEmpty);
    });

    testWidgets('turning it off tells the server and stops the shape', (
      tester,
    ) async {
      await openKnows(tester);
      await tester.tap(find.byKey(const ValueKey('companion-route-switch')));
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && ctl.routeShapeOn; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await pumpTimes(tester, 4);
      expect(sw(tester).value, isFalse);
      expect(ctl.routeShapeOn, isFalse);
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
        'route_shape': false,
      });
    });

    testWidgets('the consent copy names the shape and the splits', (
      tester,
    ) async {
      expect(kCompanionSent, contains('could still be recognised'));
      expect(kCompanionSent, contains('pace for each km'));
      expect(kCompanionSent, isNot(contains('—')));
      expect(kCompanionCheckins, isNot(contains('—')));
      expect(kCompanionCheckins, contains('14 days'));
    });
  });

  group('heart rate on cards', () {
    Future<void> openIt(WidgetTester tester) async {
      await tester.runAsync(() => enrolNow(ctl));
      await pumpApp(
        tester,
        fakeServices(companion: ctl, transfer: transfer),
        home: const CompanionScreen(),
      );
      await pumpTimes(tester, 6);
      await scrollTo(
        tester,
        find.byKey(const ValueKey('companion-heart-rate-switch')),
      );
    }

    Switch sw(WidgetTester tester) => tester.widget<Switch>(
      find.byKey(const ValueKey('companion-heart-rate-switch')),
    );

    testWidgets('starts off, with one line saying what is sent', (
      tester,
    ) async {
      await openIt(tester);
      expect(sw(tester).value, isFalse);
      expect(find.text('Heart rate on cards'), findsOneWidget);
      expect(find.text(kCompanionHeartRateBlurb), findsOneWidget);
      expect(kCompanionHeartRateBlurb, isNot(contains('—')));
      expect(http.to('PUT', '/v1/me/settings'), isEmpty);
    });

    testWidgets('turning it on tells the server', (tester) async {
      await openIt(tester);
      await tester.tap(
        find.byKey(const ValueKey('companion-heart-rate-switch')),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !ctl.heartRateOn; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await pumpTimes(tester, 4);
      expect(sw(tester).value, isTrue);
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
        'heart_rate': true,
      });
    });
  });

  group('weather in suggestions', () {
    Future<void> openKnows(WidgetTester tester) async {
      await tester.runAsync(() => enrolNow(ctl));
      await pumpApp(
        tester,
        fakeServices(companion: ctl, transfer: transfer),
        home: const CompanionScreen(),
      );
      await pumpTimes(tester, 6);
      await scrollTo(
        tester,
        find.byKey(const ValueKey('companion-weather-switch')),
      );
    }

    Switch sw(WidgetTester tester) => tester.widget<Switch>(
      find.byKey(const ValueKey('companion-weather-switch')),
    );

    /// The sheet scrolls on a small screen: bring the button into view first.
    Future<void> tapSheet(WidgetTester tester, String key) async {
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester, bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await pumpTimes(tester, 4);
    }

    testWidgets('starts off and sends nothing until it is turned on', (
      tester,
    ) async {
      await openKnows(tester);
      expect(sw(tester).value, isFalse);
      expect(find.text('Weather in suggestions'), findsOneWidget);
      expect(find.text(kCompanionWeatherBlurb), findsOneWidget);
      expect(http.to('PUT', '/v1/me/settings'), isEmpty);
      expect(ctl.weatherOn, isFalse);
    });

    testWidgets(
      'turning it on shows the disclosure first; Not now keeps it off',
      (tester) async {
        await openKnows(tester);
        await tester.tap(
          find.byKey(const ValueKey('companion-weather-switch')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('companion-weather-sheet')),
          findsOneWidget,
        );
        expect(find.text(kCompanionWeatherSheetTitle), findsOneWidget);
        for (final p in kCompanionWeatherSheet) {
          expect(find.text(p), findsOneWidget);
        }
        // The four things the sheet has to say.
        final all = kCompanionWeatherSheet.join(' ');
        expect(all, contains('11 km'));
        expect(all, contains('Open-Meteo'));
        expect(all, contains('Why:'));
        expect(all, contains('any time'));
        final on = find.byKey(const ValueKey('companion-weather-on'));
        final off = find.byKey(const ValueKey('companion-weather-not-now'));
        await tester.ensureVisible(on);
        expect(tester.getSize(on), tester.getSize(off));
        await tester.tap(off);
        await pumpTimes(tester, 6);
        expect(sw(tester).value, isFalse);
        expect(http.to('PUT', '/v1/me/settings'), isEmpty);
        expect(ctl.weatherOn, isFalse);
      },
    );

    testWidgets('Turn on weather tells the server, then the switch reads on', (
      tester,
    ) async {
      await openKnows(tester);
      await tester.tap(find.byKey(const ValueKey('companion-weather-switch')));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1)); // the sheet slides in
      await tapSheet(tester, 'companion-weather-on');
      await settle(tester, () => ctl.weatherOn);
      expect(ctl.weatherOn, isTrue);
      expect(sw(tester).value, isTrue);
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').single), {
        'weather': true,
      });
    });

    testWidgets(
      'turning it off needs no sheet and tells the server to forget',
      (tester) async {
        await tester.runAsync(() async {
          await enrolNow(ctl);
          await ctl.setWeather(true);
        });
        await pumpApp(
          tester,
          fakeServices(companion: ctl, transfer: transfer),
          home: const CompanionScreen(),
        );
        await pumpTimes(tester, 6);
        await scrollTo(
          tester,
          find.byKey(const ValueKey('companion-weather-switch')),
        );
        expect(sw(tester).value, isTrue);
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('companion-weather-switch')),
          );
        });
        await settle(tester, () => !ctl.weatherOn);
        expect(
          find.byKey(const ValueKey('companion-weather-sheet')),
          findsNothing,
        );
        expect(sw(tester).value, isFalse);
        expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
          'weather': false,
        });
      },
    );

    testWidgets('a failed turn-on leaves it off and says why', (tester) async {
      await openKnows(tester);
      http.handler = (r) =>
          r.method == 'PUT' ? const CompanionReply(503) : http.defaultReply(r);
      await tester.tap(find.byKey(const ValueKey('companion-weather-switch')));
      await pumpTimes(tester, 6);
      await tester.pump(const Duration(seconds: 1)); // the sheet slides in
      await tapSheet(tester, 'companion-weather-on');
      await settle(tester, () => ctl.problem != null);
      expect(sw(tester).value, isFalse);
      expect(ctl.weatherOn, isFalse);
      expect(ctl.problem, contains('Weather is still off'));
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await pumpTimes(tester, 4);
      await scrollTo(tester, find.byKey(const ValueKey('companion-problem')));
      expect(find.byKey(const ValueKey('companion-problem')), findsOneWidget);
    });
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

  group('coach memory sheet (consent v4)', () {
    Map<String, Object?> lastConsent() =>
        http.bodyOf(http.to('PUT', '/v1/me/consent').last);

    Future<void> open(WidgetTester tester) async {
      await tester.runAsync(() => enrolNow(ctl));
      await pumpApp(
        tester,
        fakeServices(companion: ctl, transfer: transfer),
        home: const CompanionScreen(),
      );
      await pumpTimes(tester, 6);
    }

    test('the sheet is at most 90 words with no em dashes', () {
      final words = '$kCompanionMemoryTitle $kCompanionMemoryBody'
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
      expect(words, lessThanOrEqualTo(90));
      for (final s in [
        kCompanionMemoryTitle,
        kCompanionMemoryBody,
        kCompanionMemoryHealthTick,
        kCompanionMemorySyncTitle,
        kCompanionMemorySyncBlurb,
      ]) {
        expect(s, isNot(contains('\u2014')));
      }
    });

    testWidgets(
      'a v2 runner is offered it: tick off, switch on, no silent upgrade',
      (tester) async {
        await open(tester);
        expect(ctl.memoryOffered, isTrue);
        expect(ctl.memoryOn, isFalse);
        expect(
          find.byKey(const ValueKey('companion-memory-offer')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(const ValueKey('companion-memory-health-box')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('companion-memory-sync-switch')),
              )
              .value,
          isTrue,
        );
        // Only the version-2 report has gone out so far.
        expect(lastConsent(), {'consent_version': kCompanionBaseConsent});
      },
    );

    testWidgets('Agree sends version 4 with the defaults', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('companion-memory-agree')));
      await pumpTimes(tester, 4);
      expect(lastConsent(), {
        'consent_version': kCompanionConsentVersion,
        'health_notes': false,
        'training_sync': true,
      });
      expect(kCompanionConsentVersion, 4);
      expect(ctl.memoryOn, isTrue);
      expect(ctl.healthNotesOn, isFalse);
      expect(ctl.trainingSyncOn, isTrue);
      expect(
        find.byKey(const ValueKey('companion-memory-offer')),
        findsNothing,
      );
      expect(secrets.values[CompanionController.consentName], '4');
    });

    testWidgets('ticking health notes and switching sync off are sent', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(
        find.byKey(const ValueKey('companion-memory-health-box')),
      );
      await tester.tap(
        find.byKey(const ValueKey('companion-memory-sync-switch')),
      );
      await pumpTimes(tester, 2);
      await tester.tap(find.byKey(const ValueKey('companion-memory-agree')));
      await pumpTimes(tester, 4);
      expect(lastConsent(), {
        'consent_version': 4,
        'health_notes': true,
        'training_sync': false,
      });
      // They survive an app restart.
      final again = CompanionController(
        store: secrets,
        transfer: transfer,
        client: CompanionClient(baseUrl: 'https://c.test', http: http),
      );
      await tester.runAsync(again.load);
      expect(again.memoryOn, isTrue);
      expect(again.healthNotesOn, isTrue);
      expect(again.trainingSyncOn, isFalse);
    });

    testWidgets('Not now sends nothing and keeps the rest working', (
      tester,
    ) async {
      await open(tester);
      final before = http.to('PUT', '/v1/me/consent').length;
      await tester.tap(find.byKey(const ValueKey('companion-memory-notnow')));
      await pumpTimes(tester, 4);
      expect(http.to('PUT', '/v1/me/consent').length, before);
      expect(ctl.memoryOn, isFalse);
      expect(ctl.memoryOffered, isFalse);
      expect(ctl.consentCurrent, isTrue); // check-ins and Home carry on
      expect(
        find.byKey(const ValueKey('companion-memory-offer')),
        findsNothing,
      );
    });
  });
}
