import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/trail_facts.dart';

import '../run_fixtures.dart';

/// The server's rules for a `trail` block (`companion/trail.py`, README
/// "Trail block"), so a block the app builds is one the server keeps.
void expectValidBlock(Map<String, Object?> b) {
  final n = b['n']! as int;
  expect(n, inInclusiveRange(1, 999));
  final board = (b['board']! as List).cast<Map<String, Object?>>();
  expect(board.length, inInclusiveRange(2, 10));
  expect(n, greaterThanOrEqualTo(board.length));
  expect(board.where((r) => r['today'] == true), hasLength(1));
  expect(board.map((r) => r['attempt']).toSet(), hasLength(board.length));
  for (final r in board) {
    expect(r['attempt'], inInclusiveRange(1, 999));
    expect(r['time_s'], inInclusiveRange(1, 86400));
    expect(r['rank'], inInclusiveRange(1, 999));
  }
  final profile = b['profile'] as List?;
  if (profile != null) {
    expect(profile.length, inInclusiveRange(2, 64));
    for (final v in profile) {
      expect(v, isA<int>());
      expect(v as int, inInclusiveRange(-2000, 9000));
    }
  }
  final gap = b['ghost_gap'] as List?;
  if (gap != null) {
    expect(gap.length, inInclusiveRange(2, 64));
    for (final v in gap) {
      expect(v, isA<int>());
      expect(v as int, inInclusiveRange(-3600, 3600));
    }
  }
  if (b['turn'] != null) {
    expect(profile, isNotNull);
    expect(b['turn'] as int, inInclusiveRange(0, profile!.length - 1));
  }
  if (b['elev_src'] != null) expect(['baro', 'gps'], contains(b['elev_src']));
  if (b['shape'] != null) {
    expect(['out_and_back', 'loop', 'one_way'], contains(b['shape']));
  }
  if (b['name'] != null) {
    expect((b['name']! as String).length, lessThanOrEqualTo(30));
  }
  const known = {
    'n',
    'board',
    'profile',
    'elev_src',
    'ghost_gap',
    'turn',
    'shape',
    'name',
  };
  expect(b.keys.toSet().difference(known), isEmpty);
}

engine.TrailRunFacts factsOf(engine.RunFile r, {String? street}) =>
    engine.TrailRunFacts(
      id: r.id,
      start: r.start,
      movingMs: engine.RunTimes.movingMs(r),
      distanceM: r.distanceM,
      gradeFactor: 1,
      route: engine.RouteSignature.of(r),
      street: street,
    );

Map<String, Object?>? build(
  List<engine.RunFile> runs,
  engine.RunFile today, {
  engine.RunFile? priorBest,
  bool names = false,
  String? street,
}) {
  final g = trailGroupOf(today.id, allFacts(runs, street: street));
  if (g == null) return null;
  return trailBlock(
    runId: today.id,
    group: g,
    run: today,
    priorBest: priorBest,
    names: names,
  );
}

List<engine.TrailRunFacts> allFacts(
  List<engine.RunFile> runs, {
  String? street,
}) => [for (final r in runs) factsOf(r, street: street)];

void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);

  /// [secs] seconds per km for each run, oldest first.
  List<engine.RunFile> loops(List<int> secs) => [
    for (var i = 0; i < secs.length; i++)
      trailLoopRun(
        n: i + 1,
        start: d1.add(Duration(days: 2 * i)),
        secPerKm: secs[i],
      ),
  ];

  test('the fixture is what trailBlock writes, and the server accepts it', () {
    final runs = loops([400, 380, 390, 385]);
    final b = build(
      runs,
      runs.last,
      priorBest: runs[1],
      names: true,
      street: 'Kastro',
    )!;
    final file = File('test/fixtures/trail_block_sample.json');
    if (Platform.environment['UPDATE_FIXTURE'] == '1') {
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(b)}\n',
      );
    }
    final j = (jsonDecode(file.readAsStringSync()) as Map)
        .cast<String, Object?>();
    expectValidBlock(j);
    expect(j, jsonDecode(jsonEncode(b)));
  });

  test('a first run on a trail sends no block', () {
    final runs = loops([400]);
    expect(build(runs, runs.last), isNull);
  });

  test('the 2nd run sends a 2-row block (the server draws a record only)', () {
    final runs = loops([400, 390]);
    final b = build(runs, runs.last)!;
    expectValidBlock(b);
    expect(b['n'], 2);
    final board = (b['board']! as List).cast<Map<String, Object?>>();
    expect(board, hasLength(2));
    expect(board.first['today'], true);
    expect(board.first['rank'], 1);
  });

  test('a run on no known trail sends no block', () {
    final runs = loops([400, 390, 380]);
    final g = trailGroupOf(runs.last.id, allFacts(runs))!;
    expect(trailAsOf(g, 'nope'), isNull);
    expect(build(loops([400]), runs.last), isNull);
  });

  test('the 3rd run starts the board', () {
    final runs = loops([400, 390, 380]);
    final b = build(runs, runs.last)!;
    expectValidBlock(b);
    expect(b['n'], 3);
    final board = (b['board']! as List).cast<Map<String, Object?>>();
    expect(board, hasLength(3));
    expect(board.first['today'], true);
    expect(board.first['rank'], 1);
  });

  test('a late upload counts only the runs up to its own', () {
    final runs = loops([400, 390, 380, 370]);
    final b = build(runs, runs[1])!;
    expect(b['n'], 2);
    expect((b['board']! as List), hasLength(2));
  });

  test('n > 10 sends 10 rows, each with its true rank', () {
    // 12 distinct paces, 10 s/km apart on a 6 km loop; run i has secs[i].
    final secs = [for (var i = 0; i < 12; i++) 300 + ((i * 7) % 12) * 10];
    final runs = loops(secs);
    final today = runs[8];
    final b = build(runs, runs.last)!; // today = the last run, n = 12
    expectValidBlock(b);
    expect(b['n'], 12);
    expect(build(runs, today)!['n'], 9); // asked as of run 9
    final board = (b['board']! as List).cast<Map<String, Object?>>();
    expect(board, hasLength(10));
    int rankOf(int i) => 1 + secs.where((s) => s < secs[i]).length;
    for (final r in board) {
      expect(r['rank'], rankOf((r['attempt']! as int) - 1));
    }
    expect(board.any((r) => r['rank'] == 1), isTrue);
    expect(board.where((r) => r['today'] == true).single['attempt'], 12);
    final ranks = [for (final r in board) r['rank']! as int];
    expect(ranks, [...ranks]..sort());
  });

  test('place names are sent only when asked, and cut to 30 chars', () {
    final runs = loops([400, 390, 380]);
    Map<String, Object?> go(bool names, String? street) =>
        build(runs, runs.last, names: names, street: street)!;
    expect(go(false, 'Kastro').containsKey('name'), isFalse);
    expect(go(true, 'Kastro')['name'], 'Kastro loop');
    final long = go(true, 'A very long street name indeed here');
    expect((long['name']! as String).length, lessThanOrEqualTo(30));
    expectValidBlock(long);
  });

  test('a trail with no street or place never gets a (dated) name', () {
    final runs = loops([400, 390, 380]);
    expect(
      build(runs, runs.last, names: true).toString(),
      isNot(contains('Trail of')),
    );
    expect(build(runs, runs.last, names: true)!.containsKey('name'), isFalse);
  });

  test('a name is never cut inside an emoji', () {
    final runs = loops([400, 390, 380]);
    final b = build(runs, runs.last, names: true, street: '\u{1F3C3}' * 40)!;
    final name = b['name']! as String;
    expect(name.runes.length, lessThanOrEqualTo(30));
    expect(name.contains('\uFFFD'), isFalse);
  });

  test('profile and ghost_gap are capped at 64 points', () {
    final runs = loops([400, 380, 390, 385]);
    final today = runs.last;
    final prior = runs[1];
    final g = trailGroupOf(today.id, allFacts(runs))!;
    expect(priorBestOf(g, today.id)!.id, prior.id);
    final b = build(runs, today, priorBest: prior)!;
    expectValidBlock(b);
    expect((b['profile']! as List).length, 64);
    expect(b['elev_src'], 'baro');
    expect(b['shape'], anyOf('loop', 'out_and_back'));
    final gap = (b['ghost_gap']! as List).cast<int>();
    expect(gap.length, 64);
    // 385 s/km against 380: behind the old best over the run.
    expect(gap.last, lessThan(0));
  });

  test('a prior best that started late still lines up with the profile', () {
    final runs = loops([400, 380, 390, 385]);
    final late = _dropStart(runs[1], 300);
    final b = build(runs, runs.last, priorBest: late)!;
    expectValidBlock(b);
    final gap = (b['ghost_gap']! as List).cast<int>();
    expect(gap.length, 64);
    // The 300 m it never reached carries the nearest value, so the gap is
    // flat there instead of the later gap being stretched to the start.
    expect(gap.take(4).toSet().length, lessThanOrEqualTo(2));
  });

  test('without the old best file there is no ghost_gap', () {
    final runs = loops([400, 380, 390]);
    final b = build(runs, runs.last)!;
    expect(b.containsKey('ghost_gap'), isFalse);
    expectValidBlock(b);
  });
}

/// [r] without its first [m] metres, as a late GPS lock leaves it.
engine.RunFile _dropStart(engine.RunFile r, double m) => r.copyWith(
  samples: [
    for (final s in r.samples)
      if (s.distM >= m) s,
  ],
);
