import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/send_runs.dart';

import '../helpers.dart';
import '../run_fixtures.dart';
import 'coach_next_test.dart' show movedReply;
import 'companion_test.dart' show FakeCompanionHttp, enrolNow;

/// The `quest` block only goes to a server that has said it knows quests: an
/// older one refuses the whole run for a key it does not know.
void main() {
  late FakeCompanionHttp http;
  late CompanionController ctl;
  late CompanionTarget target;
  late MemoryRunStore store;
  late SendRequest req;
  var asked = 0;

  /// The same reply a server with quests sends: both keys, even when empty.
  final withQuests =
      '${movedReply.substring(0, movedReply.length - 1)},'
      '"quest":null,"care_weeks":[]}';

  setUp(() async {
    asked = 0;
    http = FakeCompanionHttp();
    ctl = CompanionController(
      store: MemorySecretStore(),
      transfer: FakeTransferGateway(),
      client: CompanionClient(baseUrl: 'https://c.test', http: http),
      pollEvery: Duration.zero,
    );
    final run = fourByFourFile(n: 1, start: DateTime.utc(2026, 9, 24, 6));
    store = MemoryRunStore(files: [run], now: now);
    await store.setUtcOffset(run.id, 480);
    final d = (await store.load(run.id))!;
    req = SendRequest(run: run, title: 'Run', detail: d);
    target = CompanionTarget(controller: ctl)
      ..questFacts = (d, {required names}) async {
        asked++;
        return {
          'offers': [
            {
              'id': 'q_2026-11_distance_month_aaaa',
              'kind': 'distance_month',
              'target': 20,
              'baseline': 15,
              'unit': 'km',
            },
          ],
        };
      };
    await enrolNow(ctl);
  });

  void serve(String body) {
    http.handler = (r) => r.uri.path == '/v1/me/next-session'
        ? CompanionReply(200, body)
        : http.defaultReply(r);
  }

  test(
    'an older server (no quest keys in next-session) never sees it',
    () async {
      serve(movedReply);
      await ctl.refreshNext();
      expect(ctl.questsSupported, isFalse);
      expect((await target.send(req)).ok, isTrue);
      expect(asked, 0);
      expect(
        http.bodyOf(http.to('POST', '/v1/runs').single).containsKey('quest'),
        isFalse,
      );
    },
  );

  test('before any next-session reply nothing is sent', () async {
    expect(ctl.questsSupported, isFalse);
    await target.send(req);
    expect(asked, 0);
    expect(
      http.bodyOf(http.to('POST', '/v1/runs').single).containsKey('quest'),
      isFalse,
    );
  });

  test('a server that sends the quest keys gets the block', () async {
    serve(withQuests);
    await ctl.refreshNext();
    expect(ctl.questsSupported, isTrue);
    await target.send(req);
    expect(asked, 1);
    final body = http.bodyOf(http.to('POST', '/v1/runs').single);
    final q = body['quest']! as Map;
    expect((q['offers']! as List).single['unit'], 'km');
  });

  test(
    'the capability is kept across a restart with the cached reply',
    () async {
      serve(withQuests);
      await ctl.refreshNext();
      final again = CompanionController(
        store: ctl.store,
        transfer: FakeTransferGateway(),
        client: CompanionClient(baseUrl: 'https://c.test', http: http),
        pollEvery: Duration.zero,
      );
      await again.load();
      expect(again.questsSupported, isTrue);
    },
  );

  test('a block that cannot be built sends the run without it', () async {
    serve(withQuests);
    await ctl.refreshNext();
    target.questFacts = (d, {required names}) async => throw StateError('x');
    expect((await target.send(req)).ok, isTrue);
    expect(
      http.bodyOf(http.to('POST', '/v1/runs').single).containsKey('quest'),
      isFalse,
    );
  });

  test('next-session parse: the keys mean support, a null quest is fine', () {
    expect(CoachNext.parse({'v': 1, 'quest': null})!.supportsQuests, isTrue);
    expect(CoachNext.parse({'v': 1, 'care_weeks': []})!.supportsQuests, isTrue);
    expect(CoachNext.parse({'v': 1})!.supportsQuests, isFalse);
  });

  test('what the companion knows names the quests as numbers only', () {
    final me = CompanionMe.fromJson({
      'quests': [
        {'state': 'accepted'},
        {'state': 'offered'},
        {'state': 'offered'},
        {'state': 'done'},
        {'state': 'skipped'},
      ],
    });
    final line = me.lines.firstWhere((l) => l.$1 == 'Quests');
    expect(
      line.$2,
      '1 running, 2 offered, 2 ended. Kept 90 days after they end',
    );
    expect(
      CompanionMe.fromJson({'quests': []}).lines
          .firstWhere((l) => l.$1 == 'Quests')
          .$2,
      'None',
    );
    // An older server sends no list: no line.
    expect(
      CompanionMe.fromJson({}).lines.any((l) => l.$1 == 'Quests'),
      isFalse,
    );
  });
}
