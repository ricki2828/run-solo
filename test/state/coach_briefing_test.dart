import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/coach_briefing.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/start_briefing.dart';
import 'package:run_solo/state/voice_coach_plan.dart';

import 'companion_test.dart' show FakeCompanionHttp, enrolNow;

// A planned Norwegian 4x4, the session the coach briefs in these tests.
const _session = engine.BlockSession(
  id: 'w2s1',
  week: 2,
  dayOffset: 0,
  role: engine.BlockRole.key,
  kind: engine.BlockKind.interval,
  reason: 'test',
  presetId: engine.SessionSpec.norwegian4x4Id,
  minutes: 30,
);

const _tpl = 'Today is {reps}. Hold {pace} on each one and jog the recoveries.';

void main() {
  final fp = StartBriefing.fingerprintOf(_session);
  final ref = companionSessionRef(_session)!;
  final t0 = DateTime.utc(2026, 10, 20, 8);

  CachedBriefing cached({
    String? sessionRef,
    String? fingerprint,
    DateTime? generatedAt,
  }) => CachedBriefing.template(
    sessionRef: sessionRef ?? ref,
    fingerprint: fingerprint ?? fp,
    template: _tpl,
    generatedAt: generatedAt ?? t0,
    savedAt: t0,
  );

  BriefingChoice choose(
    CachedBriefing? c, {
    String? sessionRef,
    String? fingerprint,
    DateTime? now,
  }) => BriefingCache.choose(
    c,
    sessionRef: sessionRef ?? ref,
    fingerprint: fingerprint ?? fp,
    now: now ?? t0.add(const Duration(hours: 1)),
  );

  group('the Start decision', () {
    test('a fresh template for this session and fingerprint is used', () {
      expect(choose(cached()).template, _tpl);
      expect(choose(cached()).suppress, isFalse);
    });

    test('a different fingerprint is not used', () {
      expect(choose(cached(fingerprint: '0123456789abcdef')).template, isNull);
      // The session changed under the cache (pace moved): same ref, other fingerprint.
      final moved = StartBriefing.fingerprintOf(
        _session,
        paces: engine.TargetPaces.fromVdot(40),
      );
      expect(moved, isNot(fp));
      expect(choose(cached(), fingerprint: moved).template, isNull);
    });

    test('a different session ref is not used, even with the same content', () {
      expect(choose(cached(sessionRef: 'w3s1')).template, isNull);
    });

    test('36 hours old is stale, 35 is not', () {
      expect(
        choose(cached(), now: t0.add(const Duration(hours: 35))).template,
        _tpl,
      );
      expect(
        choose(cached(), now: t0.add(const Duration(hours: 36))).template,
        isNull,
      );
      expect(
        choose(cached(), now: t0.add(const Duration(days: 3))).template,
        isNull,
      );
    });

    test(
      'age is counted from the server generated_at, not from when saved',
      () {
        final old = CachedBriefing.template(
          sessionRef: ref,
          fingerprint: fp,
          template: _tpl,
          generatedAt: t0.subtract(const Duration(hours: 40)),
          savedAt: t0,
        );
        expect(choose(old).template, isNull);
        final unknown = CachedBriefing.template(
          sessionRef: ref,
          fingerprint: fp,
          template: _tpl,
          generatedAt: null,
          savedAt: t0,
        );
        expect(choose(unknown).template, isNull);
      },
    );

    test('nothing cached, or not today\'s plan session: nothing', () {
      expect(choose(null).template, isNull);
      expect(
        BriefingCache.choose(
          cached(),
          sessionRef: null,
          fingerprint: null,
          now: t0,
        ).template,
        isNull,
      );
    });

    test('a fresh suppress marker suppresses; a stale one does not', () {
      final m = CachedBriefing.suppress(savedAt: t0);
      expect(choose(m).suppress, isTrue);
      expect(choose(m).template, isNull);
      expect(
        choose(m, now: t0.add(const Duration(hours: 36))).suppress,
        isFalse,
      );
      // Not today's plan session: no briefing would be spoken, so nothing to suppress.
      expect(
        BriefingCache.choose(
          m,
          sessionRef: null,
          fingerprint: null,
          now: t0,
        ).suppress,
        isFalse,
      );
    });

    test('the cache round-trips and a bad one reads as none', () {
      final back = CachedBriefing.decode(cached().encode())!;
      expect(back.sessionRef, ref);
      expect(back.fingerprint, fp);
      expect(back.template, _tpl);
      expect(back.generatedAt, t0);
      expect(
        CachedBriefing.decode(CachedBriefing.suppress(savedAt: t0).encode())!
            .suppress,
        isTrue,
      );
      expect(CachedBriefing.decode('not json'), isNull);
      expect(CachedBriefing.decode('{"suppress":false}'), isNull);
      expect(CachedBriefing.decode(null), isNull);
    });
  });

  group('VoiceCoachPlan at Start', () {
    final zones = engine.HrZones.percentMax(190);

    VoiceCoachConfig build({String? template, bool suppress = false}) =>
        VoiceCoachPlan.build(
          settings: const AppSettings(),
          zones: zones,
          planned: _session,
          vdot: 45,
          briefingTemplate: template,
          suppressBriefing: suppress,
        );

    test('a matched template rides along with the app\'s own as fallback', () {
      final c = build(template: _tpl);
      expect(c.briefingTemplate, _tpl);
      expect(c.briefingFallback, isNotNull);
    });

    test('no template: the Dart fallback as today', () {
      final c = build();
      expect(c.briefingTemplate, isNull);
      expect(c.briefingFallback, isNotNull);
    });

    test('suppress: no coach template and no Dart fallback (plain start)', () {
      final c = build(template: _tpl, suppress: true);
      expect(c.briefingTemplate, isNull);
      expect(c.briefingFallback, isNull);
      expect(c.sessionName, isNull);
      expect(c.reps, isNull);
      expect(c.plannedDistanceM, isNull);
      // The rest of the coaching is untouched.
      expect(c.enabled, isTrue);
      expect(c.targetPaceSecPerKm, isNotNull);
    });
  });

  group('GET /v1/me/briefing', () {
    late FakeCompanionHttp http;
    late MemorySecretStore secrets;
    late CompanionController ctl;
    var clock = t0;

    CompanionController controller() => CompanionController(
      store: secrets,
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
      now: () => clock,
    );

    String templateReply({
      String? sessionRef,
      String? fingerprint,
      DateTime? generatedAt,
    }) => jsonEncode({
      'session_ref': sessionRef ?? ref,
      'fingerprint': fingerprint ?? fp,
      'template': _tpl,
      'generated_at': (generatedAt ?? clock).toUtc().toIso8601String(),
      'prompt_hash': 'abc',
    });

    BriefingChoice start({String? sessionRef, String? fingerprint}) =>
        ctl.briefingChoice(
          sessionRef: sessionRef ?? ref,
          fingerprint: fingerprint ?? fp,
        );

    void serve(CompanionReply Function() reply) {
      http.handler = (r) =>
          r.uri.path == '/v1/me/briefing' ? reply() : http.defaultReply(r);
    }

    setUp(() async {
      clock = t0;
      http = FakeCompanionHttp();
      secrets = MemorySecretStore();
      ctl = controller();
      await enrolNow(ctl);
    });

    test('off or not linked: no request at all', () async {
      final off = CompanionController(
        store: MemorySecretStore(),
        transfer: FakeTransferGateway(),
        client: CompanionClient(baseUrl: 'https://c.test', http: http),
        now: () => clock,
      );
      await off.load();
      await off.refreshBriefing();
      expect(http.to('GET', '/v1/me/briefing'), isEmpty);
      expect(
        off.briefingChoice(sessionRef: ref, fingerprint: fp).template,
        isNull,
      );
    });

    test(
      '200 template: a Bearer GET, cached, used for the matching session',
      () async {
        serve(() => CompanionReply(200, templateReply()));
        await ctl.refreshBriefing();
        final req = http.to('GET', '/v1/me/briefing').single;
        expect(req.headers['Authorization'], 'Bearer tok-123');
        expect(req.uri.toString(), isNot(contains('tok-123')));
        expect(start().template, _tpl);
        expect(secrets.values[CompanionController.briefingName], isNotNull);
      },
    );

    test(
      'Start itself never fetches: the lookup is synchronous and quiet',
      () async {
        serve(() => CompanionReply(200, templateReply()));
        await ctl.refreshBriefing();
        http.requests.clear();
        final c = start(); // not a Future
        expect(c.template, _tpl);
        expect(http.requests, isEmpty);
      },
    );

    test('the cache survives a restart (read back on load)', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      final again = controller();
      await again.load();
      expect(
        again.briefingChoice(sessionRef: ref, fingerprint: fp).template,
        _tpl,
      );
    });

    test(
      '200 template for another fingerprint or session is cached but not used',
      () async {
        serve(
          () => CompanionReply(
            200,
            templateReply(fingerprint: 'ffffffffffffffff'),
          ),
        );
        await ctl.refreshBriefing();
        expect(start().template, isNull);
        clock = clock.add(const Duration(minutes: 2));
        serve(() => CompanionReply(200, templateReply(sessionRef: 'w9s9')));
        await ctl.refreshBriefing();
        expect(start().template, isNull);
      },
    );

    test('202 pending keeps the cache', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      clock = clock.add(const Duration(minutes: 2));
      serve(() => const CompanionReply(202, '{"status":"pending"}'));
      await ctl.refreshBriefing();
      expect(http.to('GET', '/v1/me/briefing'), hasLength(2));
      expect(start().template, _tpl);
    });

    test('204 clears the cache, memory and storage', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      clock = clock.add(const Duration(minutes: 2));
      serve(() => const CompanionReply(204));
      await ctl.refreshBriefing();
      expect(start().template, isNull);
      expect(start().suppress, isFalse);
      expect(
        secrets.values.containsKey(CompanionController.briefingName),
        isFalse,
      );
    });

    test(
      'suppress stores a marker: no briefing at all at Start, template cleared',
      () async {
        serve(() => CompanionReply(200, templateReply()));
        await ctl.refreshBriefing();
        clock = clock.add(const Duration(minutes: 2));
        serve(() => const CompanionReply(200, '{"status":"suppress"}'));
        await ctl.refreshBriefing();
        expect(start().suppress, isTrue);
        expect(start().template, isNull);
        // Still on 35 hours later, even without another fetch; off after 36.
        clock = clock.add(const Duration(hours: 34));
        expect(start().suppress, isTrue);
        clock = clock.add(const Duration(hours: 3));
        expect(start().suppress, isFalse);
      },
    );

    test('the suppress marker survives a restart', () async {
      serve(() => const CompanionReply(200, '{"status":"suppress"}'));
      await ctl.refreshBriefing();
      final again = controller();
      await again.load();
      expect(
        again.briefingChoice(sessionRef: ref, fingerprint: fp).suppress,
        isTrue,
      );
    });

    test('a later template (or 204) lifts the suppress marker', () async {
      serve(() => const CompanionReply(200, '{"status":"suppress"}'));
      await ctl.refreshBriefing();
      clock = clock.add(const Duration(minutes: 2));
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      expect(start().suppress, isFalse);
      expect(start().template, _tpl);
    });

    test('offline keeps the cache', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      clock = clock.add(const Duration(minutes: 2));
      http.offline = true;
      await ctl.refreshBriefing();
      expect(start().template, _tpl);
      expect(ctl.problem, isNull);
    });

    test('an error status or a garbled 200 keeps the cache', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      for (final r in [
        const CompanionReply(404),
        const CompanionReply(429),
        const CompanionReply(500),
        const CompanionReply(200, 'not json'),
        const CompanionReply(200, '{"session_ref":"w2s1"}'),
      ]) {
        clock = clock.add(const Duration(minutes: 2));
        serve(() => r);
        await ctl.refreshBriefing();
        expect(start().template, _tpl, reason: '${r.status} ${r.body}');
      }
    });

    test(
      'a stale template (over 36 h) is not spoken even if never replaced',
      () async {
        serve(() => CompanionReply(200, templateReply()));
        await ctl.refreshBriefing();
        clock = clock.add(const Duration(hours: 37));
        expect(start().template, isNull);
      },
    );

    test(
      'at most one fetch a minute, unless forced (after an upload)',
      () async {
        serve(() => const CompanionReply(202, '{"status":"pending"}'));
        await ctl.refreshBriefing();
        await ctl.refreshBriefing();
        expect(http.to('GET', '/v1/me/briefing'), hasLength(1));
        await ctl.refreshBriefing(force: true);
        expect(http.to('GET', '/v1/me/briefing'), hasLength(2));
      },
    );

    test('a 401 wipes the link and the cached briefing', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      clock = clock.add(const Duration(minutes: 2));
      serve(() => const CompanionReply(401));
      await ctl.refreshBriefing();
      expect(ctl.enrolled, isFalse);
      expect(start().template, isNull);
      expect(
        secrets.values.containsKey(CompanionController.briefingName),
        isFalse,
      );
    });

    test('no consent, no briefing', () async {
      serve(() => CompanionReply(200, templateReply()));
      await ctl.refreshBriefing();
      secrets.values[CompanionController.consentName] = '1';
      final old = controller();
      await old.load();
      expect(
        old.briefingChoice(sessionRef: ref, fingerprint: fp).template,
        isNull,
      );
    });
  });
}
