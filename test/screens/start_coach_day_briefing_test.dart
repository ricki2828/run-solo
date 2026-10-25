import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../state/companion_test.dart' show FakeCompanionHttp, enrolNow;

/// C2b: with no plan in the app, today's coach-week session gets the coach's
/// start briefing when the run started is that session (a Free run on an
/// easy day), matched from memory by the keys next-session gave.
void main() {
  const tpl = 'Easy run today, {distance}. Keep it chatty.';

  String day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<CompanionController> coach(
    WidgetTester tester, {
    required String type,
    String briefRef = 'cw1e',
  }) async {
    final http = FakeCompanionHttp();
    http.handler = (r) => switch (r.uri.path) {
      '/v1/me/next-session' => CompanionReply(
        200,
        jsonEncode({
          'v': 1,
          'next_session': {
            'date': day(now()),
            'type': type,
            'kind': type,
            'session_id': type,
            'distance_m': 6000,
            'derived': true,
            'session_ref': 'cw1e',
            'fingerprint': 'f00d',
          },
        }),
      ),
      '/v1/me/briefing' => CompanionReply(
        200,
        jsonEncode({
          'session_ref': briefRef,
          'fingerprint': 'f00d',
          'template': tpl,
          'generated_at': now().toUtc().toIso8601String(),
          'prompt_hash': 'abc',
        }),
      ),
      _ => http.defaultReply(r),
    };
    final ctl = CompanionController(
      store: MemorySecretStore(),
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
      now: now,
    );
    await tester.runAsync(() async {
      await enrolNow(ctl);
      await ctl.refreshNext();
      await ctl.refreshBriefing(force: true);
    });
    return ctl;
  }

  Future<VoiceCoachConfig> startFree(
    WidgetTester tester,
    CompanionController ctl,
  ) async {
    final fake = FakeRecorderGateway(now: now);
    final services = fakeServices(
      recorder: fake,
      companion: ctl,
      settings: const AppSettings(
        onboardingDone: true,
        lastMode: RecordMode.free,
      ),
    );
    await pumpApp(tester, services, pushRoute: Routes.start);
    await pumpTimes(tester, 4);
    await readyAndGo(tester);
    await pumpTimes(tester, 6);
    return fake.voiceCoach!;
  }

  testWidgets('a Free run on an easy coach day carries the coach briefing', (
    tester,
  ) async {
    final ctl = await coach(tester, type: 'easy');
    expect(ctl.coachDayToday, isNotNull);
    final c = await startFree(tester, ctl);
    expect(c.briefingTemplate, tpl);
    expect(c.briefingFallback, isNull);
    expect(c.plannedDistanceM, 6000);
  });

  testWidgets('a Free run on a quality day does not', (tester) async {
    final ctl = await coach(tester, type: 'quality');
    final c = await startFree(tester, ctl);
    expect(c.briefingTemplate, isNull);
    expect(c.plannedDistanceM, isNull);
  });

  testWidgets('a briefing for another session is not spoken', (tester) async {
    final ctl = await coach(tester, type: 'easy', briefRef: 'cw0e');
    final c = await startFree(tester, ctl);
    expect(c.briefingTemplate, isNull);
  });
}
