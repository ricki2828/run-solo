import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/send_runs.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Scripted server: records every request, answers from [handler].
class FakeCompanionHttp implements CompanionHttp {
  FakeCompanionHttp([this.handler]);
  CompanionReply Function(CompanionRequest)? handler;
  final List<CompanionRequest> requests = [];
  bool offline = false;

  List<CompanionRequest> to(String method, String path) => [
    for (final r in requests)
      if (r.method == method && r.uri.path == path) r,
  ];

  Map<String, Object?> bodyOf(CompanionRequest r) =>
      jsonDecode(utf8.decode(r.body!)) as Map<String, Object?>;

  @override
  Future<CompanionReply> send(CompanionRequest req) async {
    requests.add(req);
    if (offline) throw const CompanionNetworkError();
    if (handler != null) return handler!(req);
    return defaultReply(req);
  }

  CompanionReply defaultReply(CompanionRequest req) {
    return switch ((req.method, req.uri.path)) {
      ('POST', '/v1/enrol/start') => CompanionReply(
        200,
        jsonEncode({
          'nonce': 'n0nce',
          'poll_secret': 'sec-1',
          'expires_in': 900,
          'links': {'telegram': 'https://t.me/bot?start=n0nce'},
        }),
      ),
      ('POST', '/v1/enrol/status') => CompanionReply(
        200,
        '{"state":"awaiting_code"}',
      ),
      ('POST', '/v1/enrol/confirm') => CompanionReply(
        200,
        jsonEncode({
          'state': 'claimed',
          'token': 'tok-123',
          'chat_name': 'Ricki',
        }),
      ),
      ('POST', '/v1/runs') => CompanionReply(202, '{"status":"accepted"}'),
      ('PATCH', _) => CompanionReply(200, '{}'),
      ('PUT', '/v1/me/settings') => CompanionReply(200, '{"status":"ok"}'),
      ('DELETE', '/v1/me') => CompanionReply(200, '{}'),
      ('GET', '/v1/me') => CompanionReply(200, '{}'),
      _ => const CompanionReply(404),
    };
  }
}

/// What FastAPI answers when the body has a field the server does not know.
const extraForbidden =
    '{"detail":[{"type":"extra_forbidden","loc":["body","plan_next"],'
    '"msg":"Extra inputs are not permitted"}]}';

/// A 422 that is the run's own fault (a start time in the future).
const futureStart = '{"detail":"start_utc is in the future"}';

/// A store that refuses to keep the privacy zones.
class _ZoneWriteFails extends MemorySecretStore {
  @override
  Future<void> write(String name, String value) async {
    if (name == CompanionController.zonesName) throw StateError('disk full');
    return super.write(name, value);
  }
}

/// Turn on, then type the code the bot sent.
Future<void> enrolNow(CompanionController c, [String code = '123456']) async {
  await c.turnOn();
  await c.submitCode(code);
}

void main() {
  final start = DateTime.utc(2026, 9, 24, 6);
  late FakeCompanionHttp http;
  late MemorySecretStore secrets;
  late FakeTransferGateway transfer;
  late CompanionController ctl;
  late MemoryRunStore store;
  late engine.RunFile run;

  CompanionController controller({Future<void> Function(DateTime)? enrolled}) =>
      CompanionController(
        store: secrets,
        transfer: transfer,
        client: CompanionClient(baseUrl: 'https://c.test', http: http),
        pollEvery: Duration.zero,
        waitFor: const Duration(seconds: 5),
        onEnrolled: enrolled,
      );

  setUp(() {
    http = FakeCompanionHttp();
    secrets = MemorySecretStore();
    transfer = FakeTransferGateway();
    ctl = controller();
    run = fourByFourFile(n: 1, start: start);
    store = MemoryRunStore(files: [run], now: now);
  });

  group('enrolment and token', () {
    test('starts off and not asked: nothing is pre-selected', () async {
      await ctl.load();
      expect(ctl.phase, CompanionPhase.off);
      expect(ctl.enrolled, isFalse);
      expect(ctl.asked, isFalse);
      expect(await ctl.token(), isNull);
      expect(http.requests, isEmpty);
    });

    test(
      'Turn on opens the link, the code finishes it, the token is kept',
      () async {
        var wired = false;
        ctl = controller(enrolled: (_) async => wired = true);
        await ctl.turnOn();
        expect(ctl.phase, CompanionPhase.awaitingCode);
        expect(await ctl.token(), isNull);
        expect(wired, isFalse);
        await ctl.submitCode('123456');
        expect(ctl.phase, CompanionPhase.on);
        expect(
          transfer.opened.single.toString(),
          'https://t.me/bot?start=n0nce',
        );
        expect(await secrets.read(CompanionController.tokenName), 'tok-123');
        expect(wired, isTrue);
        expect(http.to('POST', '/v1/enrol/start').single.body, isNull);
        // The poll secret goes in the POST body, never a URL.
        final status = http.to('POST', '/v1/enrol/status').single;
        expect(http.bodyOf(status), {'nonce': 'n0nce', 'poll_secret': 'sec-1'});
        expect(status.uri.query, isEmpty);
        final confirm = http.to('POST', '/v1/enrol/confirm').single;
        expect(http.bodyOf(confirm)['code'], '123456');
      },
    );

    test('polls until the bot has sent the code', () async {
      var polls = 0;
      final plain = FakeCompanionHttp();
      http.handler = (r) {
        if (r.uri.path != '/v1/enrol/status') return plain.defaultReply(r);
        polls += 1;
        return polls < 3
            ? const CompanionReply(200, '{"state":"pending"}')
            : const CompanionReply(200, '{"state":"awaiting_code"}');
      };
      await ctl.turnOn();
      expect(polls, 3);
      expect(ctl.phase, CompanionPhase.awaitingCode);
    });

    test('a wrong code stays on the code step; 5 wrong locks it', () async {
      await ctl.turnOn();
      final plain = FakeCompanionHttp();
      http.handler = (r) => r.uri.path == '/v1/enrol/confirm'
          ? const CompanionReply(403)
          : plain.defaultReply(r);
      await ctl.submitCode('000000');
      expect(ctl.phase, CompanionPhase.awaitingCode);
      expect(ctl.problem, contains('not right'));
      http.handler = (r) => r.uri.path == '/v1/enrol/confirm'
          ? const CompanionReply(410)
          : plain.defaultReply(r);
      await ctl.submitCode('000001');
      expect(ctl.phase, CompanionPhase.failed);
      expect(await ctl.token(), isNull);
    });

    test('a malformed code never leaves the phone', () async {
      await ctl.turnOn();
      await ctl.submitCode('12');
      expect(http.to('POST', '/v1/enrol/confirm'), isEmpty);
      expect(ctl.problem, contains('6 digits'));
    });

    test('denied says the companion is not open yet', () async {
      final plain = FakeCompanionHttp();
      http.handler = (r) => r.uri.path == '/v1/enrol/status'
          ? const CompanionReply(200, '{"state":"denied"}')
          : plain.defaultReply(r);
      await ctl.turnOn();
      expect(ctl.phase, CompanionPhase.failed);
      expect(ctl.problem, contains('not open'));
    });

    test('times out into the retry state, then retries', () async {
      final plain = FakeCompanionHttp();
      http.handler = (r) => r.uri.path == '/v1/enrol/status'
          ? const CompanionReply(200, '{"state":"pending"}')
          : plain.defaultReply(r);
      var clock = DateTime.utc(2026, 10, 9);
      ctl = CompanionController(
        store: secrets,
        transfer: transfer,
        client: CompanionClient(baseUrl: 'https://c.test', http: http),
        pollEvery: Duration.zero,
        waitFor: const Duration(seconds: 3),
        now: () => clock = clock.add(const Duration(seconds: 1)),
      );
      await ctl.turnOn();
      expect(ctl.phase, CompanionPhase.failed);
      expect(ctl.problem, isNotNull);
      expect(await ctl.token(), isNull);
      http.handler = null;
      await enrolNow(ctl);
      expect(ctl.enrolled, isTrue);
    });

    test('an offline start fails with a retry, no token', () async {
      http.offline = true;
      await enrolNow(ctl);
      expect(ctl.phase, CompanionPhase.failed);
      expect(await ctl.token(), isNull);
    });

    test('Not now is remembered and enrols nothing', () async {
      await ctl.notNow();
      expect(ctl.asked, isTrue);
      expect(ctl.enrolled, isFalse);
      expect(http.requests, isEmpty);
      final again = controller();
      await again.load();
      expect(again.asked, isTrue);
    });

    test(
      'the token survives a restart and goes out as a Bearer header',
      () async {
        await enrolNow(ctl);
        final next = controller();
        await next.load();
        expect(next.enrolled, isTrue);
        await next.fetchMe();
        final me = http.to('GET', '/v1/me').single;
        expect(me.headers['Authorization'], 'Bearer tok-123');
        expect(me.uri.toString(), isNot(contains('tok-123')));
      },
    );

    test(
      'Delete everything wipes the token only once the server agrees',
      () async {
        await enrolNow(ctl);
        http.offline = true;
        expect(await ctl.deleteEverything(), isFalse);
        expect(ctl.enrolled, isTrue);
        expect(await ctl.token(), 'tok-123');
        http.offline = false;
        expect(await ctl.deleteEverything(), isTrue);
        expect(ctl.phase, CompanionPhase.off);
        expect(await ctl.token(), isNull);
        expect(
          http.to('DELETE', '/v1/me').last.headers['Authorization'],
          'Bearer tok-123',
        );
      },
    );

    test('a 401 on /v1/me means the key is dead: wipe it', () async {
      await enrolNow(ctl);
      http.handler = (_) => const CompanionReply(401);
      expect(await ctl.fetchMe(), isNull);
      expect(ctl.phase, CompanionPhase.off);
      expect(await ctl.token(), isNull);
    });
  });

  group('what it knows', () {
    test('reads /v1/me into plain words', () {
      final me = CompanionMe.fromJson({
        'profile': {
          'channel': 'telegram',
          'quiet_start_min': 1260,
          'quiet_end_min': 420,
        },
        'runs_received': [
          {'feel': 'easy'},
          {'feel': 'right'},
          {'feel': 'right'},
          {'feel': 'hard'},
          {},
        ],
        'messages_sent_30d': 6,
        'chat_name': 'Ricki T',
        'memory': {
          'goal_type': 'first_5k',
          'race_month': '2026-11',
          'usual_days': 'both',
          'niggle_area': 'calf',
        },
      });
      final text = {for (final (a, b) in me.lines) a: b};
      expect(text['Connected to'], 'Ricki T');
      expect(text['Runs it has'], '5');
      expect(text['Your goal'], 'first 5k');
      expect(text['Your race'], 'Nov 2026');
      expect(text['Days you usually run'], 'Weekdays and weekends');
      expect(text['Niggles'], 'calf');
      expect(text['How runs felt'], '1 easy, 2 right, 1 hard');
      expect(text['Quiet hours'], '21:00 to 07:00');
      expect(text['Notes sent, last 30 days'], '6');
    });

    test('an empty memory says "Not told yet", not blanks', () {
      final text = {for (final (a, b) in CompanionMe.fromJson({}).lines) a: b};
      expect(text['Your goal'], 'Not told yet');
      expect(text['How runs felt'], 'No taps yet');
      expect(text['Quiet hours'], 'None set');
    });

    test('race_month none reads as no race', () {
      final me = CompanionMe.fromJson({
        'memory': {'race_month': 'none'},
      });
      final text = {for (final (a, b) in me.lines) a: b};
      expect(text['Your race'], 'No race planned');
    });
  });

  group('summary', () {
    Future<Map<String, Object?>> summaryOf() async {
      await store.setUtcOffset(run.id, 480);
      final d = (await store.load(run.id))!;
      return companionSummary(d, zones: engine.HrZones.percentMax(190))!;
    }

    test('compact fields, no route points, no street', () async {
      await store.setPlace(run.id, 'Albert Park');
      await store.setStreet(run.id, 'Beaconsfield Parade');
      final j = await summaryOf();
      expect(j['run_id'], run.id);
      expect(j['type'], 'intervals');
      expect(j['start_utc'], run.start.toUtc().toIso8601String());
      expect(j['utc_offset_min'], 480);
      expect(j['zone_id'], isNotEmpty);
      expect(j['duration_s'], isA<int>());
      expect(j['distance_m'], isA<double>());
      expect(j['locality'], 'Albert Park');
      expect(j['verdict'], isA<String>());
      expect(
        engine.VerdictHeadline.values.map((h) => h.name),
        contains(j['verdict']),
      );
      final zm = j['zone_min']! as Map;
      expect(zm.keys, ['z1', 'z2', 'z3', 'z4', 'z5']);
      expect(jsonEncode(j), isNot(contains('Beaconsfield')));
      // Only fields the server accepts (it rejects unknown ones).
      const allowed = {
        'run_id',
        'type',
        'start_utc',
        'utc_offset_min',
        'zone_id',
        'duration_s',
        'distance_m',
        'pace_s_per_km',
        'true_pace_s_per_km',
        'verdict',
        'zone_min',
        'climb_m',
        'locality',
        'feel',
        'splits',
        'reps',
      };
      expect(j.keys.toSet().difference(allowed), isEmpty);
    });

    test('carries the feel when the runner tapped before the send', () async {
      await store.setFeel(run.id, engine.RunFeel.hard);
      expect((await summaryOf())['feel'], 'hard');
    });

    test('zone ids: own zone wins, whole-hour offsets map to Etc/GMT', () {
      expect(companionZoneId('Asia/Singapore', 480), 'Asia/Singapore');
      expect(companionZoneId(null, 480), 'Etc/GMT-8');
      expect(companionZoneId(null, -300), 'Etc/GMT+5');
      expect(companionZoneId(null, 0), 'Etc/UTC');
      expect(companionZoneId(null, 345), isNull);
      expect(companionZoneId(null, null), isNull);
    });
  });

  group('plan facts', () {
    // Monday 5 Oct 2026, 3 a week: w1s1 intervals (Mon), w1s2 easy 30 min
    // (Wed), w1s3 long 45 min (Fri), and so on to week 4.
    engine.BlockPlan plan() => engine.BlockPlanner.build(
      lane: engine.IdentityLane.speed,
      perWeek: 3,
      start: DateTime(2026, 10, 5),
    );

    engine.BlockView view(
      engine.BlockPlan p, {
      List<engine.PlanRun> runs = const [],
    }) => engine.BlockResolver.resolve(p, runs, now: DateTime(2026, 10, 7, 12));

    engine.PlanRun planRun(String id, {double km = 7}) => engine.PlanRun(
      id: id,
      start: DateTime(2026, 10, 6, 7),
      movingMs: 40 * 60000,
      distanceM: km * 1000,
      kind: engine.PlanRunKind.other,
    );

    const wire = {
      'plan_kind',
      'plan_target_m',
      'plan_week',
      'plan_weeks',
      'plan_next',
    };

    // Tuesday 6 Oct 07:00, the wall clock where the run was done.
    final at = DateTime(2026, 10, 6, 7);

    test('no plan sends nothing', () {
      expect(companionPlanFacts(null, 'x', runStart: at), isEmpty);
    });

    test('the run done as a planned session, and what is next', () {
      final f = companionPlanFacts(
        view(plan(), runs: [planRun('x')]),
        'x',
        runStart: at,
      );
      expect(f['plan_kind'], 'long'); // w1s3 took the run
      expect(f['plan_week'], 1);
      expect(f['plan_weeks'], 4);
      expect(f.containsKey('plan_target_m'), isFalse); // no distance planned
      expect(f.containsKey('plan_weeks_to_race'), isFalse); // no race date
      // Monday's overdue intervals are skipped; Wednesday's easy run is next.
      expect(f['plan_next'], {
        'type': 'easy',
        'day': '2026-10-07',
        'week': 1,
        'minutes': 30,
      });
      expect(f.keys.toSet().difference(wire), isEmpty);
    });

    test('a run in the plan period outside any session carries the week', () {
      final f = companionPlanFacts(
        view(plan()),
        'not-in-the-plan',
        runStart: at,
      );
      expect(f.containsKey('plan_kind'), isFalse);
      expect(f['plan_week'], 1);
      expect(f['plan_weeks'], 4);
    });

    test('an old run from before the plan gets no week and no next', () {
      final f = companionPlanFacts(
        view(plan()),
        'old',
        runStart: DateTime(2026, 6, 1, 7),
      );
      expect(f, isEmpty);
    });

    test('a size only where the plan holds one', () {
      final p = plan();
      final test15 = p.sessions[2].copyWith(minDistanceM: 15000);
      final f = companionPlanFacts(
        view(p.withSession(test15), runs: [planRun('x', km: 16)]),
        'x',
        runStart: at,
      );
      expect(f['plan_target_m'], 15000);
      final next =
          companionPlanFacts(view(plan()), 'y', runStart: at)['plan_next']!
              as Map;
      expect(
        next.keys.toSet().difference({
          'type',
          'day',
          'week',
          'minutes',
          'distance_m',
        }),
        isEmpty,
      );
    });

    test('a corrupt stored number is left out, not sent to fail the run', () {
      final p = plan();
      final bad = p.withSession(p.sessions[1].copyWith(minutes: 0));
      final next =
          companionPlanFacts(view(bad), 'y', runStart: at)['plan_next']! as Map;
      expect(next.containsKey('minutes'), isFalse);
      expect(next['type'], 'easy');
      final far = p.withSession(p.sessions[2].copyWith(minDistanceM: 900000));
      final f = companionPlanFacts(
        view(far, runs: [planRun('x', km: 950)]),
        'x',
        runStart: at,
      );
      expect(f.containsKey('plan_target_m'), isFalse);
    });

    test('a finished plan sends no next session', () {
      final after = engine.BlockResolver.resolve(
        plan(),
        const [],
        now: DateTime(2026, 12, 20),
      );
      final f = companionPlanFacts(
        after,
        'x',
        runStart: DateTime(2026, 12, 19),
      );
      expect(f.containsKey('plan_next'), isFalse);
    });

    test('the summary carries the plan facts and no other new field', () async {
      await store.setUtcOffset(run.id, 480);
      final d = (await store.load(run.id))!;
      final f = companionPlanFacts(
        view(plan(), runs: [planRun('x')]),
        'x',
        runStart: at,
      );
      final j = companionSummary(d, plan: f)!;
      expect(j['plan_week'], 1);
      expect(j['plan_next'], isA<Map>());
      expect(companionSummary(d)!.keys.toSet().intersection(wire), isEmpty);
      expect(jsonEncode(j), isNot(contains('reason'))); // no free text
    });
  });

  group('weather switch', () {
    late SendCoordinator coordinator;
    var clock = DateTime.utc(2026, 9, 24, 6, 40);

    Future<void> enrolAndWire() async {
      await enrolNow(ctl);
      // History rows (start point) come from the index, so a real file store.
      final dir = Directory.systemTemp.createTempSync('runsolo-cweather-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final files = FileRunStore(Directory('${dir.path}/runs'))
        ..deriveBatch = FileRunStore.deriveInIsolate;
      await files.importBundles([engine.RunBundle(run: run)]);
      await files.list();
      await files.derivedIdle;
      final s = AppSettings(
        autoSend: const {CompanionTarget.targetId},
        autoSendSince: {CompanionTarget.targetId: DateTime.utc(2026, 1, 1)},
      );
      coordinator = SendCoordinator(
        history: files,
        settings: SettingsController(MemorySettingsStore(s), s),
        targets: [CompanionTarget(controller: ctl, now: () => clock)],
        now: () => clock,
      );
    }

    Future<Map<String, Object?>> sentSummary() async {
      await coordinator.sendAuto(run.id);
      return http.bodyOf(http.to('POST', '/v1/runs').last);
    }

    setUp(() => clock = run.end.add(const Duration(minutes: 5)));

    test('is off after enrolling, and the summary carries no area', () async {
      await enrolAndWire();
      expect(ctl.weatherOn, isFalse);
      final j = await sentSummary();
      expect(j.containsKey('area_lat'), isFalse);
      expect(j.containsKey('area_lon'), isFalse);
      expect(http.to('PUT', '/v1/me/settings'), isEmpty);
    });

    test('on: the server is told first, then the area goes, rounded', () async {
      await enrolAndWire();
      expect(await ctl.setWeather(true), isTrue);
      expect(ctl.weatherOn, isTrue);
      final put = http.to('PUT', '/v1/me/settings').single;
      expect(http.bodyOf(put), {'weather': true});
      expect(put.headers['Authorization'], 'Bearer tok-123');
      final j = await sentSummary();
      // The fixture starts at -33.9, 151.2: rounded on the phone to 0.1.
      expect(j['area_lat'], -33.9);
      expect(j['area_lon'], 151.2);
    });

    test('a failed PUT leaves it off and sends no area', () async {
      await enrolAndWire();
      http.handler = (r) =>
          r.method == 'PUT' ? const CompanionReply(503) : http.defaultReply(r);
      expect(await ctl.setWeather(true), isFalse);
      expect(ctl.weatherOn, isFalse);
      expect(ctl.problem, isNotNull);
      expect((await sentSummary()).containsKey('area_lat'), isFalse);
    });

    test('offline: turning on is refused, still off', () async {
      await enrolAndWire();
      http.offline = true;
      expect(await ctl.setWeather(true), isFalse);
      expect(ctl.weatherOn, isFalse);
      expect(await secrets.read(CompanionController.weatherName), isNull);
    });

    test('off: stops at once and tells the server to forget', () async {
      await enrolAndWire();
      await ctl.setWeather(true);
      expect(await ctl.setWeather(false), isTrue);
      expect(ctl.weatherOn, isFalse);
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
        'weather': false,
      });
      expect(await secrets.read(CompanionController.weatherForgetName), isNull);
    });

    test('off while offline: phone stops, the forget is retried', () async {
      await enrolAndWire();
      await ctl.setWeather(true);
      http.offline = true;
      expect(await ctl.setWeather(false), isTrue);
      expect(ctl.weatherOn, isFalse);
      expect(await secrets.read(CompanionController.weatherForgetName), '1');
      expect(ctl.problem, contains('told when you are back online'));
      // Back online: the next open lands it.
      http.offline = false;
      final next = controller();
      await next.load();
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
        'weather': false,
      });
      expect(await secrets.read(CompanionController.weatherForgetName), isNull);
    });

    test('the choice survives a restart', () async {
      await enrolAndWire();
      await ctl.setWeather(true);
      final next = controller();
      await next.load();
      expect(next.weatherOn, isTrue);
    });

    test('Delete everything also clears the switch', () async {
      await enrolAndWire();
      await ctl.setWeather(true);
      expect(await ctl.deleteEverything(), isTrue);
      expect(ctl.weatherOn, isFalse);
      expect(await secrets.read(CompanionController.weatherName), isNull);
      expect(await secrets.read(CompanionController.weatherForgetName), isNull);
    });

    test('a 401 on the PUT means the key is dead: wipe it', () async {
      await enrolAndWire();
      http.handler = (_) => const CompanionReply(401);
      expect(await ctl.setWeather(true), isFalse);
      expect(ctl.phase, CompanionPhase.off);
    });

    test('areaCell rounds to 0.1 and never returns negative zero', () {
      expect(areaCell(37.97123), 38.0);
      expect(areaCell(-36.8485), -36.8);
      expect(areaCell(-0.04), 0.0);
      expect(areaCell(-0.04).isNegative, isFalse);
    });
  });

  group('route shape, splits and reps in the summary', () {
    Future<Map<String, Object?>> summary({bool withRoute = false}) async {
      await store.setUtcOffset(run.id, 480);
      final d = (await store.load(run.id))!;
      return companionSummary(
        d,
        zones: engine.HrZones.percentMax(190),
        withRoute: withRoute,
      )!;
    }

    test('no route unless asked for; splits and reps always come', () async {
      final j = await summary();
      expect(j.containsKey('route'), isFalse);
      final splits = (j['splits']! as List).cast<Map<String, Object?>>();
      expect(splits, isNotEmpty);
      for (final x in splits) {
        expect(x.keys.toSet().difference({'km', 'pace_s', 'zone'}), isEmpty);
        expect(x['km'] as double, inInclusiveRange(0.001, 1.0));
        expect(x['pace_s'] as double, inInclusiveRange(60, 3600));
        expect(x['zone'], anyOf(isNull, inInclusiveRange(1, 5)));
      }
      // A 4x4 has four work reps, each with its time and zone.
      final reps = (j['reps']! as List).cast<Map<String, Object?>>();
      expect(reps, hasLength(4));
      expect(reps.first.keys.toSet().difference({'time_s', 'zone'}), isEmpty);
    });

    test(
      'the route is a shape: whole numbers in a unit box, nothing absolute',
      () async {
        final j = await summary(withRoute: true);
        final route = (j['route']! as List).cast<List<Object?>>();
        expect(route.length, inInclusiveRange(2, engine.kRouteMaxPoints));
        for (final p in route) {
          expect(p, hasLength(2));
          for (final c in p) {
            expect(c, isA<int>());
            expect(c as int, inInclusiveRange(0, engine.kRouteGrid));
          }
        }
        expect(
          route.map((p) => p[0]! as int).reduce((a, b) => a < b ? a : b),
          0,
        );
        expect(
          route.map((p) => p[1]! as int).reduce((a, b) => a < b ? a : b),
          0,
        );
        // The run starts at -33.9, 151.2: none of that is on the wire.
        final wire = jsonEncode(j['route']);
        expect(wire, isNot(contains('.')));
        expect(wire, isNot(contains('151')));
        expect(wire, isNot(contains('33')));
        expect(jsonEncode(j), isNot(contains('"lat"')));
      },
    );

    test(
      'the whole summary stays small enough for the server (8 KB)',
      () async {
        expect(
          utf8.encode(jsonEncode(await summary(withRoute: true))).length,
          lessThan(8 * 1024),
        );
      },
    );
  });

  group('route shape switch', () {
    late SendCoordinator coordinator;
    var clock = DateTime.utc(2026, 9, 24, 6, 40);

    Future<void> enrolAndWire() async {
      await enrolNow(ctl);
      final s = AppSettings(
        autoSend: const {CompanionTarget.targetId},
        autoSendSince: {CompanionTarget.targetId: DateTime.utc(2026, 1, 1)},
      );
      coordinator = SendCoordinator(
        history: store,
        settings: SettingsController(MemorySettingsStore(s), s),
        targets: [CompanionTarget(controller: ctl, now: () => clock)],
        now: () => clock,
      );
    }

    Future<Map<String, Object?>> sentSummary() async {
      await coordinator.sendAuto(run.id);
      return http.bodyOf(http.to('POST', '/v1/runs').last);
    }

    setUp(() {
      clock = run.end.add(const Duration(minutes: 5));
      return store.setUtcOffset(run.id, 480);
    });

    test(
      'is on by default after enrolling, and says nothing to the server',
      () async {
        await enrolAndWire();
        expect(ctl.routeShapeOn, isTrue);
        expect(http.to('PUT', '/v1/me/settings'), isEmpty);
        expect((await sentSummary()).containsKey('route'), isTrue);
      },
    );

    test('the first send makes a secret zone; it is in no request', () async {
      await enrolAndWire();
      await sentSummary();
      final zones =
          jsonDecode(secrets.values[CompanionController.zonesName]!) as List;
      expect(zones, hasLength(1));
      final z = zones.single as Map;
      for (final r in http.requests) {
        final text =
            '${r.uri} ${r.headers} ${r.body == null ? '' : utf8.decode(r.body!)}';
        for (final secret in ['${z['lat']}', '${z['lon']}', '${z['r']}']) {
          expect(text, isNot(contains(secret)), reason: secret);
        }
      }
    });

    test(
      'the same zone serves later runs and survives Delete everything',
      () async {
        await enrolAndWire();
        await sentSummary();
        final first = secrets.values[CompanionController.zonesName];
        final again = await ctl.privacyZonesFor(run);
        expect(again, hasLength(1));
        expect(secrets.values[CompanionController.zonesName], first);
        expect(await ctl.deleteEverything(), isTrue);
        expect(secrets.values[CompanionController.zonesName], first);
      },
    );

    test(
      'a zone that cannot be saved means no route this time, not a weaker one',
      () async {
        final failing = _ZoneWriteFails();
        ctl = CompanionController(
          store: failing,
          transfer: transfer,
          client: CompanionClient(baseUrl: 'https://c.test', http: http),
          pollEvery: Duration.zero,
          waitFor: const Duration(seconds: 5),
        );
        await enrolAndWire();
        final j = await sentSummary();
        expect(j.containsKey('route'), isFalse);
        expect(j.containsKey('splits'), isTrue);
      },
    );

    test('is off before enrolling (nothing is sent anyway)', () async {
      expect(ctl.routeShapeOn, isFalse);
    });

    test(
      'off: the next summary has no route, and the server is told to forget',
      () async {
        await enrolAndWire();
        expect(await ctl.setRouteShape(false), isTrue);
        expect(ctl.routeShapeOn, isFalse);
        expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
          'route_shape': false,
        });
        final j = await sentSummary();
        expect(j.containsKey('route'), isFalse);
        expect(j.containsKey('splits'), isTrue);
        expect(await secrets.read(CompanionController.routeForgetName), isNull);
      },
    );

    test(
      'off while offline: the phone stops now, the forget is retried',
      () async {
        await enrolAndWire();
        http.offline = true;
        expect(await ctl.setRouteShape(false), isTrue);
        expect(ctl.routeShapeOn, isFalse);
        expect(await secrets.read(CompanionController.routeForgetName), '1');
        expect(ctl.problem, contains('told when you are back online'));
        http.offline = false;
        final next = controller();
        await next.load();
        expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
          'route_shape': false,
        });
        expect(await secrets.read(CompanionController.routeForgetName), isNull);
        expect(next.routeShapeOn, isFalse);
      },
    );

    test('on again: the server is told first, then the route goes', () async {
      await enrolAndWire();
      await ctl.setRouteShape(false);
      expect(await ctl.setRouteShape(true), isTrue);
      expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
        'route_shape': true,
      });
      expect((await sentSummary()).containsKey('route'), isTrue);
    });

    test('a failed PUT on the way back on leaves it off', () async {
      await enrolAndWire();
      await ctl.setRouteShape(false);
      http.handler = (r) =>
          r.method == 'PUT' ? const CompanionReply(503) : http.defaultReply(r);
      expect(await ctl.setRouteShape(true), isFalse);
      expect(ctl.routeShapeOn, isFalse);
      expect(ctl.problem, isNotNull);
      expect((await sentSummary()).containsKey('route'), isFalse);
    });

    test('the choice survives a restart', () async {
      await enrolAndWire();
      await ctl.setRouteShape(false);
      final next = controller();
      await next.load();
      expect(next.routeShapeOn, isFalse);
    });

    test(
      'Delete everything keeps the runner\'s route choice (off stays off)',
      () async {
        await enrolAndWire();
        await ctl.setRouteShape(false);
        expect(await ctl.deleteEverything(), isTrue);
        expect(await secrets.read(CompanionController.routeOffName), '1');
        // The new server record is told on the next enrolment, and no route goes before that.
        final next = controller();
        await next.load();
        expect(next.routeShapeOn, isFalse);
        await enrolNow(next);
        expect(next.routeShapeOn, isFalse);
        await next.syncRouteShape();
        expect(http.bodyOf(http.to('PUT', '/v1/me/settings').last), {
          'route_shape': false,
        });
      },
    );

    test('a 401 then a re-enrol does not turn the route back on', () async {
      await enrolAndWire();
      await ctl.setRouteShape(false);
      http.handler = (_) => const CompanionReply(401);
      await ctl.fetchMe();
      expect(ctl.phase, CompanionPhase.off);
      http.handler = null;
      await enrolNow(ctl);
      expect(ctl.routeShapeOn, isFalse);
    });

    test('a 401 on the PUT means the key is dead: wipe it', () async {
      await enrolAndWire();
      await ctl.setRouteShape(false);
      await ctl.setRouteShape(true);
      http.handler = (_) => const CompanionReply(401);
      await ctl.setRouteShape(false);
      await ctl.syncRouteShape();
      expect(ctl.phase, CompanionPhase.off);
    });
  });

  group('export target', () {
    late SendCoordinator coordinator;
    late SettingsController settings;
    late CompanionTarget target;
    var clock = DateTime.utc(2026, 9, 24, 6, 40);

    Future<void> enrol() async {
      await enrolNow(ctl);
      final s = AppSettings(
        autoSend: const {CompanionTarget.targetId},
        autoSendSince: {CompanionTarget.targetId: DateTime.utc(2026, 1, 1)},
      );
      settings = SettingsController(MemorySettingsStore(s), s);
      target = CompanionTarget(controller: ctl, now: () => clock);
      coordinator = SendCoordinator(
        history: store,
        settings: settings,
        targets: [target],
        now: () => clock,
      );
    }

    setUp(() => clock = run.end.add(const Duration(minutes: 5)));

    test('is off until enrolled', () async {
      target = CompanionTarget(controller: ctl);
      expect(target.isEnabled(const AppSettings()), isFalse);
      expect(target.listed, isFalse);
    });

    test('sends the run once; reconcile on every open never resends', () async {
      await enrol();
      await coordinator.sendAuto(run.id);
      expect(http.to('POST', '/v1/runs'), hasLength(1));
      for (var i = 0; i < 3; i++) {
        await coordinator.reconcile();
      }
      expect(http.to('POST', '/v1/runs'), hasLength(1));
      final sent = http.bodyOf(http.to('POST', '/v1/runs').single);
      expect(sent['run_id'], run.id);
      expect(
        http.to('POST', '/v1/runs').single.headers['Authorization'],
        'Bearer tok-123',
      );
    });

    test('a duplicate answer counts as sent', () async {
      await enrol();
      http.handler = (_) => const CompanionReply(200, '{"status":"duplicate"}');
      await coordinator.sendAuto(run.id);
      final d = (await store.load(run.id))!;
      expect(d.sidecar.sends[CompanionTarget.targetId]!.ok, isTrue);
    });

    test('offline: retried on the next open, then not again', () async {
      await enrol();
      http.offline = true;
      await coordinator.sendAuto(run.id);
      expect(
        (await store.load(run.id))!.sidecar.sends[CompanionTarget.targetId]!.ok,
        isFalse,
      );
      http.offline = false;
      await coordinator.reconcile();
      expect(
        (await store.load(run.id))!.sidecar.sends[CompanionTarget.targetId]!.ok,
        isTrue,
      );
      final posts = http.to('POST', '/v1/runs').length;
      await coordinator.reconcile();
      expect(http.to('POST', '/v1/runs'), hasLength(posts));
    });

    test('a run finished before Turn on is never sent (no backfill)', () async {
      await enrol();
      final s = AppSettings(
        autoSend: const {CompanionTarget.targetId},
        autoSendSince: {
          CompanionTarget.targetId: run.end.add(const Duration(hours: 1)),
        },
      );
      settings = SettingsController(MemorySettingsStore(s), s);
      coordinator = SendCoordinator(
        history: store,
        settings: settings,
        targets: [target],
        now: () => clock,
      );
      await coordinator.reconcile();
      expect(http.to('POST', '/v1/runs'), isEmpty);
    });

    test(
      'a 401 is a failure the runner can see, not a silent success',
      () async {
        await enrol();
        http.handler = (_) => const CompanionReply(401);
        await coordinator.sendAuto(run.id);
        final rec = (await store.load(run.id))!
            .sidecar
            .sends[CompanionTarget.targetId]!;
        expect(rec.ok, isFalse);
        expect(rec.error, 'Companion key not accepted');
      },
    );

    test(
      'the plan facts ride on the run; a failing plan read never fails it',
      () async {
        await enrol();
        target.planFacts = (_) async => {'plan_week': 2, 'plan_weeks': 4};
        await coordinator.sendAuto(run.id);
        final sent = http.bodyOf(http.to('POST', '/v1/runs').single);
        expect(sent['plan_week'], 2);
        expect(sent['plan_weeks'], 4);
      },
    );

    test(
      'a plan read that throws still sends the run, without plan fields',
      () async {
        await enrol();
        target.planFacts = (_) async => throw StateError('boom');
        await coordinator.sendAuto(run.id);
        final sent = http.bodyOf(http.to('POST', '/v1/runs').single);
        expect(sent['run_id'], run.id);
        expect(sent.containsKey('plan_week'), isFalse);
      },
    );

    test(
      'a 422 means the server is older: no try spent, retried after 6 h',
      () async {
        await enrol();
        http.handler = (_) => const CompanionReply(422, extraForbidden);
        await coordinator.sendAuto(run.id);
        expect(http.to('POST', '/v1/runs'), hasLength(1));
        final d = (await store.load(run.id))!;
        expect(
          d.sidecar.sends[CompanionTarget.targetId],
          isNull,
        ); // nothing logged
        expect(d.sidecar.autoSendDue(CompanionTarget.targetId), isTrue);
        // Every later open inside the wait makes no request at all.
        for (var i = 0; i < 4; i++) {
          await coordinator.reconcile();
        }
        expect(http.to('POST', '/v1/runs'), hasLength(1));
        // After 6 hours, with the server upgraded, the run goes.
        http.handler = null;
        clock = clock.add(const Duration(hours: 6, minutes: 1));
        await coordinator.reconcile();
        expect(http.to('POST', '/v1/runs'), hasLength(2));
        expect(
          (await store.load(run.id))!
              .sidecar
              .sends[CompanionTarget.targetId]!
              .ok,
          isTrue,
        );
      },
    );

    test(
      'any other 422 is the run\'s own: logged once as failed, never retried',
      () async {
        await enrol();
        http.handler = (_) => const CompanionReply(422, futureStart);
        await coordinator.sendAuto(run.id);
        for (var i = 0; i < 4; i++) {
          await coordinator.reconcile();
        }
        expect(http.to('POST', '/v1/runs'), hasLength(1));
        final rec = (await store.load(run.id))!
            .sidecar
            .sends[CompanionTarget.targetId]!;
        expect(rec.ok, isFalse);
        expect(rec.error, contains('refused'));
        expect(
          (await store.load(run.id))!.sidecar
              .autoSendDue(CompanionTarget.targetId),
          isFalse,
        );
        // It does not hold other runs off: no "server out of date" wait.
        http.handler = null;
        final other = await store.load(run.id);
        final res = await target.send(
          SendRequest(
            run: other!.run,
            title: 't',
            format: ExportFormat.tcx,
            detail: other,
          ),
        );
        expect(res.ok, isTrue);
      },
    );

    test('a new app start retries at once (the wait is in memory)', () async {
      await enrol();
      http.handler = (_) => const CompanionReply(422, extraForbidden);
      await coordinator.sendAuto(run.id);
      http.handler = null;
      target = CompanionTarget(controller: ctl, now: () => clock);
      coordinator = SendCoordinator(
        history: store,
        settings: settings,
        targets: [target],
        now: () => clock,
      );
      await coordinator.reconcile();
      expect(
        (await store.load(run.id))!.sidecar.sends[CompanionTarget.targetId]!.ok,
        isTrue,
      );
    });
  });

  group('feel persistence', () {
    test('saved with the run on the phone, off or on', () async {
      await recordFeel(store, null, run.id, engine.RunFeel.easy);
      expect((await store.load(run.id))!.sidecar.feel, engine.RunFeel.easy);
      expect(http.requests, isEmpty);
    });

    test(
      'companion on, run not sent yet: no PATCH, the summary carries it',
      () async {
        await enrolNow(ctl);
        http.requests.clear();
        await recordFeel(store, ctl, run.id, engine.RunFeel.right);
        expect(http.to('PATCH', '/v1/runs/${run.id}/feel'), isEmpty);
        expect((await store.load(run.id))!.sidecar.feel, engine.RunFeel.right);
      },
    );

    test('run already sent: PATCH once, and only once', () async {
      await enrolNow(ctl);
      await store.recordSend(
        run.id,
        CompanionTarget.targetId,
        ok: true,
        at: now(),
      );
      await recordFeel(store, ctl, run.id, engine.RunFeel.hard);
      final patch = http.to('PATCH', '/v1/runs/${run.id}/feel');
      expect(patch, hasLength(1));
      expect(http.bodyOf(patch.single), {'feel': 'hard'});
      expect(await flushCompanionFeels(store, ctl), 0);
      expect(http.to('PATCH', '/v1/runs/${run.id}/feel'), hasLength(1));
    });

    test('a changed feel goes again', () async {
      await enrolNow(ctl);
      await store.recordSend(
        run.id,
        CompanionTarget.targetId,
        ok: true,
        at: now(),
      );
      await recordFeel(store, ctl, run.id, engine.RunFeel.hard);
      await recordFeel(store, ctl, run.id, engine.RunFeel.easy);
      final patches = http.to('PATCH', '/v1/runs/${run.id}/feel');
      expect(patches, hasLength(2));
      expect(http.bodyOf(patches.last), {'feel': 'easy'});
    });

    test('offline PATCH is retried by the next flush', () async {
      await enrolNow(ctl);
      await store.recordSend(
        run.id,
        CompanionTarget.targetId,
        ok: true,
        at: now(),
      );
      http.offline = true;
      await recordFeel(store, ctl, run.id, engine.RunFeel.hard);
      http.offline = false;
      expect(await flushCompanionFeels(store, ctl), 1);
    });
  });
}
