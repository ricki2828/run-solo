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

  List<engine.TrailRunFacts> allFacts(
    List<engine.RunFile> runs, {
    String? street,
  }) => [for (final r in runs) factsOf(r, street: street)];

  test('the fixture is a block the server accepts', () {
    final j = jsonDecode(
      File('test/fixtures/trail_block_sample.json').readAsStringSync(),
    );
    expectValidBlock((j as Map).cast<String, Object?>());
  });

  test('a trail with fewer than 3 runs sends no block', () {
    final runs = loops([400, 390]);
    expect(
      trailBlock(runId: runs.last.id, runs: allFacts(runs), run: runs.last),
      isNull,
    );
  });

  test('a run on no known trail sends no block', () {
    final runs = loops([400, 390, 380]);
    expect(
      trailBlock(runId: 'nope', runs: allFacts(runs), run: runs.last),
      isNull,
    );
  });

  test('the 3rd run starts the board', () {
    final runs = loops([400, 390, 380]);
    final b = trailBlock(
      runId: runs.last.id,
      runs: allFacts(runs),
      run: runs.last,
    )!;
    expectValidBlock(b);
    expect(b['n'], 3);
    final board = (b['board']! as List).cast<Map<String, Object?>>();
    expect(board, hasLength(3));
    expect(board.first['today'], true);
    expect(board.first['rank'], 1);
  });

  test('n > 10 sends 10 rows, each with its true rank', () {
    // 12 distinct paces, 60 s apart on a 6 km loop; run i has pace secs[i].
    final secs = [for (var i = 0; i < 12; i++) 300 + ((i * 7) % 12) * 10];
    final runs = loops(secs);
    final today = runs[8];
    final b = trailBlock(runId: today.id, runs: allFacts(runs), run: today)!;
    expectValidBlock(b);
    expect(b['n'], 12);
    final board = (b['board']! as List).cast<Map<String, Object?>>();
    expect(board, hasLength(10));
    int rankOf(int i) => 1 + secs.where((s) => s < secs[i]).length;
    for (final r in board) {
      expect(r['rank'], rankOf((r['attempt']! as int) - 1));
    }
    // The all-time best and today are both in, today once.
    expect(board.any((r) => r['rank'] == 1), isTrue);
    expect(board.where((r) => r['today'] == true).single['attempt'], 9);
    // Sorted best first.
    final ranks = [for (final r in board) r['rank']! as int];
    expect(ranks, [...ranks]..sort());
  });

  test('place names are sent only when asked, and cut to 30 chars', () {
    final runs = loops([400, 390, 380]);
    Map<String, Object?> build(bool names, String? street) => trailBlock(
      runId: runs.last.id,
      runs: allFacts(runs, street: street),
      run: runs.last,
      names: names,
    )!;
    expect(build(false, 'Kastro').containsKey('name'), isFalse);
    expect(build(true, 'Kastro')['name'], 'Kastro loop');
    final long = build(true, 'A very long street name indeed here');
    expect((long['name']! as String).length, lessThanOrEqualTo(30));
    // No street or place: a dated name, still short.
    expect(build(true, null)['name'], startsWith('Trail of'));
    expectValidBlock(long);
  });

  test('profile and ghost_gap are capped at 64 points', () {
    final runs = loops([400, 380, 390, 385]);
    final today = runs.last;
    final prior = runs[1]; // the best before today
    final facts = allFacts(runs);
    final g = trailGroupOf(today.id, facts)!;
    expect(priorBestOf(g, today.id)!.id, prior.id);
    final b = trailBlock(
      runId: today.id,
      runs: facts,
      run: today,
      priorBest: prior,
    )!;
    expectValidBlock(b);
    expect((b['profile']! as List).length, 64);
    expect(b['elev_src'], 'baro');
    expect(b['shape'], anyOf('loop', 'out_and_back'));
    final gap = (b['ghost_gap']! as List).cast<int>();
    expect(gap.length, 64);
    // 385 s/km against 380: behind the old best over the run.
    expect(gap.last, lessThan(0));
  });

  test('without the old best file there is no ghost_gap', () {
    final runs = loops([400, 380, 390]);
    final b = trailBlock(
      runId: runs.last.id,
      runs: allFacts(runs),
      run: runs.last,
    )!;
    expect(b.containsKey('ghost_gap'), isFalse);
    expectValidBlock(b);
  });
}
