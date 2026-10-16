import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/intervals_icu.dart';

import 'companion_test.dart' show FakeCompanionHttp, enrolNow;

/// The shape in companion-server/README.md ("GET /v1/me/next-session"),
/// served by a fake: the endpoint is not deployed when this is written.
const movedReply =
    '{"v":1,"generated_at":"2026-09-24T09:00:00Z","next_session":'
    '{"date":"2026-09-28","type":"quality","minutes":null,"distance_m":6000,'
    '"week":3,"weeks":4,"moved":true,"original_date":"2026-09-25",'
    '"label":"Quality session, 6 km"},"coach_line":{"kind":"run",'
    '"headline":"Solid easy run","body":"Heart rate sat low all the way.",'
    '"sent_at":"2026-09-24T05:46:00Z"}}';

void main() {
  late FakeCompanionHttp http;
  late MemorySecretStore secrets;
  late CompanionController ctl;
  var clock = DateTime.utc(2026, 9, 24, 10);

  CompanionController controller() => CompanionController(
    store: secrets,
    transfer: FakeTransferGateway(),
    client: CompanionClient(baseUrl: 'https://c.test', http: http),
    pollEvery: Duration.zero,
    now: () => clock,
  );

  setUp(() {
    clock = DateTime.utc(2026, 9, 24, 10);
    http = FakeCompanionHttp();
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(200, movedReply)
        : http.defaultReply(r);
    secrets = MemorySecretStore();
    ctl = controller();
  });

  test('the consent version is 2, so version-1 runners agree again', () {
    expect(kCompanionConsentVersion, 2);
  });

  test('companion off or not linked: no request at all', () async {
    await ctl.load();
    await ctl.refreshNext();
    expect(http.requests, isEmpty);
    expect(ctl.coachNext, isNull);
  });

  test('on and linked: a Bearer GET, parsed, moved is carried', () async {
    await enrolNow(ctl);
    await ctl.refreshNext();
    final req = http.to('GET', '/v1/me/next-session').single;
    expect(req.headers['Authorization'], 'Bearer tok-123');
    expect(req.uri.toString(), isNot(contains('tok-123')));
    final s = ctl.coachNext!.session!;
    expect(s.moved, isTrue);
    expect(s.date, DateTime(2026, 9, 28));
    expect(s.originalDate, DateTime(2026, 9, 25));
    expect(s.title, 'Quality session, 6 km');
    expect(ctl.coachNext!.line!.headline, 'Solid easy run');
  });

  test('a session name from the server wins over the generic label', () {
    final s = CoachSession.fromJson({
      'date': '2026-09-28',
      'type': 'quality',
      'label': 'Quality session, 6 km',
      'name': 'Tempo',
    })!;
    expect(s.title, 'Tempo');
  });

  test('at most one call a minute', () async {
    await enrolNow(ctl);
    await ctl.refreshNext();
    await ctl.refreshNext();
    expect(http.to('GET', '/v1/me/next-session'), hasLength(1));
    clock = clock.add(const Duration(minutes: 2));
    await ctl.refreshNext();
    expect(http.to('GET', '/v1/me/next-session'), hasLength(2));
  });

  test('the last good reply is kept across a restart and offline', () async {
    await enrolNow(ctl);
    await ctl.refreshNext();
    final again = controller();
    await again.load();
    expect(again.coachNext!.session!.moved, isTrue);
    http.offline = true;
    clock = clock.add(const Duration(minutes: 5));
    await again.refreshNext();
    expect(again.coachNext, isNotNull);
    expect(again.problem, isNull);
  });

  test('a server error keeps it; a 404 (no check-ins) clears it', () async {
    await enrolNow(ctl);
    await ctl.refreshNext();
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(500)
        : http.defaultReply(r);
    clock = clock.add(const Duration(minutes: 5));
    await ctl.refreshNext();
    expect(ctl.coachNext, isNotNull);
    expect(ctl.problem, isNull);
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(404)
        : http.defaultReply(r);
    clock = clock.add(const Duration(minutes: 5));
    await ctl.refreshNext();
    expect(ctl.coachNext, isNull);
    expect(secrets.values[CompanionController.nextName], isNull);
  });

  test('a bad reply shape shows nothing', () async {
    await enrolNow(ctl);
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(200, '{"v":2,"next_session":{"date":"x"}}')
        : http.defaultReply(r);
    await ctl.refreshNext();
    expect(ctl.coachNext, isNull);
  });

  test('nulls are fine: no session, no line', () async {
    await enrolNow(ctl);
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(
            200,
            '{"v":1,"generated_at":"2026-09-24T09:00:00Z",'
            '"next_session":null,"coach_line":null}',
          )
        : http.defaultReply(r);
    await ctl.refreshNext();
    expect(ctl.coachNext, isNull);
  });

  test('a runner on the old consent is asked again and not fetched', () async {
    secrets.values[CompanionController.tokenName] = 'tok-old';
    secrets.values[CompanionController.consentName] = '1';
    await ctl.load();
    expect(ctl.enrolled, isTrue);
    expect(ctl.needsReconsent, isTrue);
    await ctl.refreshNext();
    expect(
      http.to('GET', '/v1/me/next-session'),
      isEmpty,
    ); // only the consent report goes out
    expect(ctl.coachNext, isNull);
    await ctl.acceptConsent();
    expect(ctl.needsReconsent, isFalse);
    expect(secrets.values[CompanionController.consentName], '2');
    await ctl.refreshNext();
    expect(ctl.coachNext, isNotNull);
  });

  test('a rejected token clears the cache and turns it off', () async {
    await enrolNow(ctl);
    await ctl.refreshNext();
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? const CompanionReply(401)
        : http.defaultReply(r);
    clock = clock.add(const Duration(minutes: 5));
    await ctl.refreshNext();
    expect(ctl.enrolled, isFalse);
    expect(ctl.coachNext, isNull);
    expect(secrets.values[CompanionController.nextName], isNull);
  });

  group('check-ins in what the companion knows', () {
    CompanionMe me(String checkins) => CompanionMe.fromJson({
      'checkins': [
        for (final c in [checkins]) c,
      ],
    });

    test('plain words, newest first, no raw names', () {
      final m = CompanionMe.fromJson({
        'checkins': [
          {
            'kind': 'ready',
            'local_date': '2026-09-22',
            'value': 'not_tomorrow',
            'created_at': '2026-09-22T20:10:00Z',
          },
          {
            'kind': 'why',
            'local_date': '2026-09-24',
            'value': 'ill',
            'created_at': '2026-09-24T06:00:00Z',
          },
          {
            'kind': 'shape',
            'local_date': '2026-09-20',
            'value': 'away',
            'created_at': '2026-09-20T19:05:00Z',
          },
        ],
      });
      expect(m.checkinLines, [
        ('Thu 24 Sep, why you skipped', 'Feeling ill'),
        ('Tue 22 Sep, evening before', 'Not running tomorrow'),
        ('Sun 20 Sep, Sunday', 'Away next week'),
      ]);
      for (final (what, answer) in m.checkinLines) {
        expect('$what $answer', isNot(contains('_')));
        expect('$what $answer', isNot(contains('2026')));
      }
    });

    test('unknown values and empty (Change) answers are dropped', () {
      final m = CompanionMe.fromJson({
        'checkins': [
          {'kind': 'ready', 'local_date': '2026-09-22', 'value': ''},
          {'kind': 'ready', 'local_date': '2026-09-22', 'value': 'weird'},
          {'kind': 'nope', 'local_date': '2026-09-22', 'value': 'fresh'},
          'junk',
        ],
      });
      expect(m.checkinLines, isEmpty);
    });

    test('an older server with no checkins field reads as none', () {
      expect(CompanionMe.fromJson({}).checkinLines, isEmpty);
      expect(me('x').checkinLines, isEmpty);
    });
  });

  group('quest and care_weeks keys', () {
    test('parsed when present, ignored when absent or malformed', () {
      final n = CoachNext.parse({
        'v': 1,
        'care_weeks': ['2026-10-12', 'nope'],
        'quest': {
          'id': 'q_2026-10_trail_visits_abc',
          'state': 'accepted',
          'accepted_at': '2026-10-02T01:00:00Z',
        },
      })!;
      expect(n.careWeeks, hasLength(1));
      expect(n.quest!.id, 'q_2026-10_trail_visits_abc');
      final bare = CoachNext.parse({'v': 1})!;
      expect(bare.careWeeks, isEmpty);
      expect(bare.quest, isNull);
      expect(
        CoachNext.parse({
          'v': 1,
          'quest': {'id': 'q_x', 'state': 'skipped'},
        })!.quest,
        isNull,
      );
      expect(CoachNext.parse({'v': 2}), isNull);
    });
  });
}
