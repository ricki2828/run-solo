import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/companion_screen.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/feel_row.dart';

import '../helpers.dart';
import '../state/companion_test.dart' show FakeCompanionHttp, enrolNow;

/// Companion surfaces at 360x640: the consent screen, "what the companion
/// knows" and the feel row.
void main() {
  late FakeCompanionHttp http;
  late CompanionController ctl;

  setUp(() {
    http = FakeCompanionHttp()
      ..handler = (r) => switch (r.uri.path) {
        '/v1/me' => const CompanionReply(
          200,
          '{"profile":{"quiet_start_min":1260,"quiet_end_min":420,'
          '"checkin_consent":3,"coach_available":true},'
          '"runs_received":[{"feel":"easy"},{"feel":"right"},{"feel":"right"},'
          '{"feel":"hard"},{}],"messages_sent_30d":6,"chat_name":"Ricki",'
          '"memory":{"goal_type":"first_5k","race_month":"2026-11",'
          '"usual_days":"both","niggle_area":"calf"},'
          '"checkins":[{"kind":"ready","local_date":"2026-10-12","value":"flat",'
          '"created_at":"2026-10-12T20:10:00Z"},{"kind":"today",'
          '"local_date":"2026-10-13","value":"skip",'
          '"created_at":"2026-10-13T06:40:00Z"},{"kind":"why",'
          '"local_date":"2026-10-13","value":"tired",'
          '"created_at":"2026-10-13T06:41:00Z"},{"kind":"shape",'
          '"local_date":"2026-10-11","value":"4",'
          '"created_at":"2026-10-11T19:06:00Z"}]}',
        ),
        _ => FakeCompanionHttp().defaultReply(r),
      };
    ctl = CompanionController(
      store: MemorySecretStore(),
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
    );
  });

  Future<void> check(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    expect(
      File('test/golden/goldens/$name.png').existsSync() ||
          autoUpdateGoldenFiles,
      isTrue,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  testWidgets('companion consent 360x640', (tester) async {
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 6);
    await check(tester, 'companion_consent_360x640');
  });

  testWidgets('companion consent more 360x640', (tester) async {
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 6);
    await scrollTo(
      tester,
      find.byKey(const ValueKey('companion-consent-more')),
    );
    await tester.tap(find.byKey(const ValueKey('companion-consent-more')));
    await pumpTimes(tester, 4);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await pumpTimes(tester, 2);
    await check(tester, 'companion_consent_more_360x640');
  });

  testWidgets('companion knows 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await check(tester, 'companion_knows_360x640');
  });

  testWidgets('companion knows check-ins 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await scrollTo(tester, find.text('CHECK-INS'));
    await tester.drag(find.byType(ListView).first, const Offset(0, -60));
    await tester.pump();
    await check(tester, 'companion_knows_checkins_360x640');
  });

  testWidgets('companion new check-ins ask again 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    // A runner who turned on under version 1.
    final store = MemorySecretStore()
      ..values[CompanionController.tokenName] = 'tok-123'
      ..values[CompanionController.consentName] = '1';
    final old = CompanionController(
      store: store,
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
    );
    await tester.runAsync(old.load);
    await pumpApp(
      tester,
      fakeServices(companion: old),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    expect(find.byKey(const ValueKey('companion-reconsent')), findsOneWidget);
    await check(tester, 'companion_reconsent_360x640');
    await tester.ensureVisible(find.byKey(const ValueKey('companion-agree')));
    await pumpTimes(tester, 2);
    await tester.tap(find.byKey(const ValueKey('companion-agree')));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('companion-reconsent')), findsNothing);
  });

  testWidgets('companion coach sheet 360x640', (tester) async {
    final plain = FakeCompanionHttp();
    http.handler = (r) => r.method == 'GET' && r.uri.path == '/v1/me'
        ? const CompanionReply(
            200,
            '{"profile":{"checkin_consent":2,"coach_available":true},"chat_name":"Ricki"}',
          )
        : plain.defaultReply(r);
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    expect(find.byKey(const ValueKey('companion-coach-offer')), findsOneWidget);
    await check(tester, 'companion_coach_sheet_360x640');
  });

  testWidgets('companion coach sheet buttons 360x640', (tester) async {
    final plain = FakeCompanionHttp();
    http.handler = (r) => r.method == 'GET' && r.uri.path == '/v1/me'
        ? const CompanionReply(
            200,
            '{"profile":{"checkin_consent":2,"coach_available":true},"chat_name":"Ricki"}',
          )
        : plain.defaultReply(r);
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await pumpTimes(tester, 4);
    expect(find.byKey(const ValueKey('companion-coach-agree')), findsOneWidget);
    await check(tester, 'companion_coach_sheet_buttons_360x640');
  });

  testWidgets('companion memory sheet 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    expect(
      find.byKey(const ValueKey('companion-memory-offer')),
      findsOneWidget,
    );
    await check(tester, 'companion_memory_sheet_360x640');
  });

  testWidgets('companion memory sheet buttons 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await pumpTimes(tester, 4);
    expect(
      find.byKey(const ValueKey('companion-memory-agree')),
      findsOneWidget,
    );
    await check(tester, 'companion_memory_sheet_buttons_360x640');
  });

  testWidgets('companion weather sheet 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await scrollTo(
      tester,
      find.byKey(const ValueKey('companion-weather-switch')),
    );
    await tester.tap(find.byKey(const ValueKey('companion-weather-switch')));
    await tester.pumpAndSettle();
    await check(tester, 'companion_weather_sheet_360x640');
  });

  testWidgets('companion weather sheet more 360x640', (tester) async {
    await tester.runAsync(() => enrolNow(ctl));
    await pumpApp(
      tester,
      fakeServices(companion: ctl),
      home: const CompanionScreen(),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 8);
    await scrollTo(
      tester,
      find.byKey(const ValueKey('companion-weather-switch')),
    );
    await tester.tap(find.byKey(const ValueKey('companion-weather-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('companion-weather-more')));
    await tester.pumpAndSettle();
    await check(tester, 'companion_weather_sheet_more_360x640');
  });

  testWidgets('companion feel row 360x640', (tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: const Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(Space.screenGutter),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FeelRow(runId: 'r', initial: engine.RunFeel.right),
            ),
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(1080, 640 * 3);
    await pumpTimes(tester, 4);
    await check(tester, 'companion_feel_360x640');
  });
}
