import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/boards.dart';
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// LB3 (A10.3): the shared board fold and its chips, over real runs.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);
  DateTime day(int n) => d1.add(Duration(days: n));

  /// A steady free run of [seconds] at [secPerKm].
  engine.RunFile steady(int n, DateTime start, int secPerKm, int seconds) =>
      generator
          .generate(
            synth.SyntheticSpec(
              name: 'boards_$n',
              id: runId(n),
              mode: engine.RunMode.free,
              lapStyle: synth.LapStyle.none,
              start: start,
              segments: [synth.Segment.free(seconds, speedFor(secPerKm))],
            ),
          )
          .run;

  Future<Boards> fold(List<engine.RunFile> files) =>
      MemoryRunStore(files: files, now: () => day(30)).boards();

  List<BoardChip> chips(Boards b, engine.RunFile r) =>
      b.chipsFor(r.id, units: Units.km, names: engine.EventNames.generic);

  test(
    'distance boards: first entry, then PBs longest first, at most two',
    () async {
      final a = steady(1, day(0), 330, 2400); // 7.27 km: 1 km, mile, 5K
      final b = steady(2, day(2), 300, 2400); // faster on every board
      final boards = await fold([a, b]);
      expect(chips(boards, a).single.label, 'First 5K on your board');
      expect(chips(boards, a).single.pb, isFalse);
      final pbs = chips(boards, b);
      expect(pbs, hasLength(2), reason: 'at most two');
      expect(pbs.every((c) => c.pb), isTrue);
      expect(pbs.first.label, startsWith('New best 5K · '));
      expect(
        pbs.last.label,
        startsWith('New best mile · '),
        reason: 'then mile',
      );
    },
  );

  test('no PB: one rank chip for the longest board, with the gap', () async {
    final a = steady(1, day(0), 300, 2400);
    final b = steady(2, day(2), 330, 2400);
    final c = chips(await fold([a, b]), b).single;
    expect(c.pb, isFalse);
    expect(c.boardKey, engine.BestEffortDistance.k5.key);
    expect(
      c.label,
      matches(RegExp(r'^#2 of 2 5Ks · (\d+\u00A0s|\d+:\d\d) off your best$')),
    );
  });

  test(
    'ranked as the board stood that day: an old best stays a best',
    () async {
      final a = steady(1, day(0), 330, 2400);
      final b = steady(2, day(2), 310, 2400);
      final c = steady(3, day(4), 290, 2400);
      final boards = await fold([a, b, c]);
      expect(chips(boards, b).first.pb, isTrue, reason: 'best on day 2');
      expect(chips(boards, c).first.pb, isTrue);
      expect(boards.byKey[engine.BestEffortDistance.k5.key]!.pb!.runId, c.id);
    },
  );

  test(
    'intervals: the session board comes first, named by the session',
    () async {
      final a = fourByFourFile(n: 1, start: day(0), workSecPerKm: 290);
      final b = fourByFourFile(n: 2, start: day(2), workSecPerKm: 280);
      final c = fourByFourFile(n: 3, start: day(4), workSecPerKm: 300);
      final boards = await fold([a, b, c]);
      final key = engine.ComparisonKey.norwegian4x4;
      expect(chips(boards, a).first.boardKey, key);
      expect(chips(boards, a).first.label, 'First Norwegian 4x4 on your board');
      expect(
        chips(boards, b).first.label,
        startsWith('New best Norwegian 4x4 · '),
      );
      expect(chips(boards, b).first.label, endsWith('/km'));
      expect(
        chips(boards, c).single.label,
        matches(
          RegExp(
            r'^#3 of 3 Norwegian 4x4s · \d+\u00A0s/\u2060km off your best$',
          ),
        ),
      );
    },
  );

  test('a run on no board has no chips; an unknown id has none', () async {
    final short = steady(1, day(0), 360, 120); // 333 m: no board
    final boards = await fold([short]);
    expect(chips(boards, short), isEmpty);
    expect(
      boards.chipsFor(
        'nope',
        units: Units.km,
        names: engine.EventNames.generic,
      ),
      isEmpty,
    );
  });

  test('every VO2 label says estimate', () async {
    final a = cooperTestFile(n: 1, start: day(0), mps: 3.8);
    final b = cooperTestFile(n: 2, start: day(2), mps: 4.0);
    final c = cooperTestFile(n: 3, start: day(4), mps: 3.9);
    final boards = await fold([a, b, c]);
    for (final r in [b, c]) {
      final l = chips(boards, r).first.label;
      expect(engine.carriesEstimateMarker(l), isTrue, reason: l);
    }
  });
}
