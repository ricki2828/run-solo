import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/home_screen.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../state/companion_test.dart' show FakeCompanionHttp, enrolNow;

/// Home with the coach's next session (fed by a fake of
/// `GET /v1/me/next-session`), one of them moved by the coach.
void main() {
  String reply({required bool moved}) =>
      '{"v":1,"generated_at":"2026-09-24T09:00:00Z","next_session":'
      '{"date":"${moved ? '2026-09-28' : '2026-09-26'}","type":"quality",'
      '"minutes":null,"distance_m":6000,"week":3,"weeks":4,'
      '${moved ? '"name":"Norwegian 4x4",' : ''}'
      '"moved":$moved,"original_date":${moved ? '"2026-09-25"' : 'null'},'
      '"label":"Quality session, 6 km"},"coach_line":{"kind":"run",'
      '"headline":"Easy run done right","body":"Your heart rate stayed low '
      'the whole way. Keep it like this.","sent_at":"2026-09-24T05:46:00Z"}}';

  Future<void> pumpHome(
    WidgetTester tester,
    String? body, {
    bool offline = false,
  }) async {
    final http = FakeCompanionHttp()
      ..handler = (r) => r.uri.path == '/v1/me/next-session'
          ? (body == null
                ? const CompanionReply(404)
                : CompanionReply(200, body))
          : FakeCompanionHttp().defaultReply(r);
    final ctl = CompanionController(
      store: MemorySecretStore(),
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
    );
    await tester.runAsync(() => enrolNow(ctl));
    http.offline = offline;
    await pumpApp(
      tester,
      fakeServices(
        companion: ctl,
        settings: const AppSettings(
          onboardingDone: true,
          profileSex: ProfileSex.male,
          birthYear: 1982,
        ),
      ),
      home: HomeScreen(now: now, snapshot: ProgressSnapshot.sample('week2')),
    );
    tester.view.physicalSize = const Size(1080, 800 * 3);
    await pumpTimes(tester, 8);
    expect(tester.takeException(), isNull);
    // The coach card sits under the plan card: scroll it to the top.
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -520),
    );
    await pumpTimes(tester, 4);
  }

  Future<void> check(WidgetTester tester, String name) async {
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

  testWidgets('Home with the coach next session', (tester) async {
    await pumpHome(tester, reply(moved: false));
    expect(find.byKey(const ValueKey('home-coach-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-coach-moved')), findsNothing);
    expect(find.textContaining('Sat 26 Sep'), findsOneWidget);
    await check(tester, 'home_coach_next_360x800');
  });

  testWidgets('Home with a session moved by your coach', (tester) async {
    await pumpHome(tester, reply(moved: true));
    expect(find.text('MOVED BY YOUR COACH'), findsOneWidget);
    expect(find.textContaining('Norwegian 4x4'), findsOneWidget);
    expect(find.text('Was Fri 25 Sep'), findsOneWidget);
    await check(tester, 'home_coach_moved_360x800');
  });

  testWidgets('Home shows nothing when the companion has no check-ins', (
    tester,
  ) async {
    await pumpHome(tester, null);
    expect(find.byKey(const ValueKey('home-coach-card')), findsNothing);
    expect(find.textContaining('rror'), findsNothing);
  });

  testWidgets('Home shows nothing when the companion cannot be reached', (
    tester,
  ) async {
    await pumpHome(tester, reply(moved: true), offline: true);
    expect(find.byKey(const ValueKey('home-coach-card')), findsNothing);
    expect(find.textContaining('rror'), findsNothing);
  });
}
