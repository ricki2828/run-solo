import 'dart:io';
import 'dart:math' as math;

import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The same-trail audit (14-Oct, item 8: "make sure similar runs map to the
/// same trail"). Each scenario is a run on synthetic ground compared with an
/// anchor run through the two things that decide "same trail": the boards'
/// `RouteMatch.same` (the whole run, after it) and the in-run ghost's
/// recogniser (a prefix, during it). The test pins today's behaviour; set
/// AUDIT_OUT=FILE to write the table the audit report quotes.
const _lat0 = -33.8688, _lon0 = 151.2093;
final _kLon = 111320.0 * math.cos(_lat0 * math.pi / 180);

typedef P = (double, double);

RunFile _run(
  String id,
  List<P> corners, {
  double mps = 4,
  double noiseM = 4,
  int seed = 1,
}) {
  final rnd = math.Random(seed);
  final pts = <P>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final (ax, ay) = corners[i - 1];
    final (bx, by) = corners[i];
    final len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    final n = math.max(1, (len / mps).ceil());
    for (var k = 1; k <= n; k++) {
      pts.add((ax + (bx - ax) * k / n, ay + (by - ay) * k / n));
    }
  }
  final samples = <Sample>[];
  var dist = 0.0;
  for (var i = 0; i < pts.length; i++) {
    if (i > 0) {
      dist += math.sqrt(
        math.pow(pts[i].$1 - pts[i - 1].$1, 2) +
            math.pow(pts[i].$2 - pts[i - 1].$2, 2),
      );
    }
    final x = pts[i].$1 + (rnd.nextDouble() - 0.5) * 2 * noiseM;
    final y = pts[i].$2 + (rnd.nextDouble() - 0.5) * 2 * noiseM;
    samples.add(
      Sample(
        tMs: i * 1000,
        lat: _lat0 + y / 111320.0,
        lon: _lon0 + x / _kLon,
        accM: 5,
        distM: dist,
      ),
    );
  }
  return fixture('easy_free_run').run
      .copyWith(id: id, mode: RunMode.trail, samples: samples, laps: const []);
}

List<P> _rot(List<P> ring, int k) => [
  ...ring.sublist(k, ring.length - 1),
  ...ring.sublist(0, k),
  ring[k],
];

class _Row {
  _Row(this.name, this.lengthPct, this.boards, this.ghost, this.note);
  final String name;
  final int lengthPct;
  final bool boards;
  final String ghost;
  final String note;
}

void main() {
  // A 2.4 km loop and a 3 km out-and-back (turn at 1.5 km).
  final loop = <P>[(0, 0), (800, 0), (800, 400), (0, 400), (0, 0)];
  final oab = <P>[(0, 0), (1500, 0), (0, 0)];
  final rows = <_Row>[];

  RouteSignature sig(RunFile r) => RouteSignature.of(r)!;

  /// The in-run view: the anchor as the recorder's trail, the candidate fed
  /// fix by fix; "matched" and the ahead figure at the end.
  String ghost(RunFile anchor, RunFile r) {
    final t = TrailGhostBuilder.build(
      id: 'a',
      name: 'Anchor',
      best: anchor,
      last: anchor,
    )!;
    final g = TrailGhostTracker([t]);
    var active = 0;
    for (final s in r.samples) {
      active = s.tMs;
      g.offer(s.tMs, s.lat!, s.lon!, 5, active, s.distM);
    }
    final st = g.state;
    if (st == null) return 'no match';
    return st.off ? 'matched then off' : 'matched';
  }

  void check(
    String name,
    RunFile anchor,
    RunFile r, {
    required bool boards,
    required String ghostSays,
    String note = '',
  }) {
    final a = sig(anchor), b = sig(r);
    final same = RouteMatch.same(a, b);
    final gh = ghost(anchor, r);
    rows.add(
      _Row(
        name,
        (r.distanceM / anchor.distanceM * 100).round(),
        same,
        gh,
        note,
      ),
    );
    if (Platform.environment['AUDIT_EXPLORE'] == null) {
      expect(same, boards, reason: '$name: boards');
      expect(gh, ghostSays, reason: '$name: ghost');
    }
  }

  final aLoop = _run('loop', loop, seed: 1);
  final aOab = _run('oab', oab, seed: 1);

  test('loops', () {
    check(
      'Loop again',
      aLoop,
      _run('l2', loop, seed: 2),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Loop, sloppy GPS (15 m noise)',
      aLoop,
      _run('l3', loop, noiseM: 15, seed: 3),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Loop started at another corner',
      aLoop,
      _run('l4', _rot(loop, 2), seed: 4),
      boards: true,
      ghostSays: 'no match',
      note: 'joined mid-loop, the ghost reaches the end of the trail line before the run ends, goes off, and lets go after 500 m',
    );
    check(
      'Loop run the other way',
      aLoop,
      _run('l5', loop.reversed.toList(), seed: 5),
      boards: false,
      ghostSays: 'no match',
    );
    check(
      'Loop, one corner cut (-4%)',
      aLoop,
      _run('l6', [
        (0, 0),
        (800, 0),
        (800, 400),
        (30, 400),
        (0, 370),
        (0, 0),
      ], seed: 6),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Loop with a 200 m spur (+8%)',
      aLoop,
      _run('l7', [
        (0, 0),
        (800, 0),
        (900, 0),
        (800, 0),
        (800, 400),
        (0, 400),
        (0, 0),
      ], seed: 7),
      boards: false,
      ghostSays: 'matched',
      note: 'the spur is 100 m out and back, so the boards (Frechet 50 m) split it',
    );
    check(
      'Loop with a shortcut across (-10%)',
      aLoop,
      _run('l8', [(0, 0), (800, 0), (400, 400), (0, 400), (0, 0)], seed: 8),
      boards: false,
      ghostSays: 'matched',
      note: 'the ghost rejoins the line after the cut and credits the skipped ground as time gained',
    );
  });

  test('out and backs', () {
    check(
      'Out and back again',
      aOab,
      _run('o2', oab, seed: 12),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Turned 50 m early (-3%)',
      aOab,
      _run('o8', [(0, 0), (1450, 0), (0, 0)], seed: 18),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Turned 50 m late (+3%)',
      aOab,
      _run('o9', [(0, 0), (1550, 0), (0, 0)], seed: 19),
      boards: true,
      ghostSays: 'matched',
    );
    check(
      'Turned 100 m early (-7%)',
      aOab,
      _run('o3', [(0, 0), (1400, 0), (0, 0)], seed: 13),
      boards: true,
      ghostSays: 'matched',
      note: 'out and backs group on the shared ground, so a turn point 100 m off is still one trail (was split by the Frechet check)',
    );
    check(
      'Turned 200 m early (-13%)',
      aOab,
      _run('o4', [(0, 0), (1300, 0), (0, 0)], seed: 14),
      boards: false,
      ghostSays: 'matched',
      note: 'same stem, shorter: the ghost recognises it, the boards call it another trail',
    );
    check(
      'Turned 200 m late (+13%)',
      aOab,
      _run('o5', [(0, 0), (1700, 0), (0, 0)], seed: 15),
      boards: false,
      ghostSays: 'matched',
      note: 'the ghost compares like for like over the shared stem; no board for it',
    );
    check(
      'Parallel track 60 m away',
      aOab,
      _run('o6', [(0, 60), (1500, 60), (0, 60)], seed: 16),
      boards: false,
      ghostSays: 'no match',
    );
    check(
      'Same start, diverges after 1 km',
      aOab,
      _run('o7', [(0, 0), (1000, 0), (1500, 500), (1000, 0), (0, 0)], seed: 17),
      boards: false,
      ghostSays: 'no match',
      note: 'the ghost follows the shared first km, then lets go 500 m after it loses the line',
    );
  });

  test('the anchor, not the neighbour, decides', () {
    // Turn points 1500 (anchor), 1560 and 1620 m out: each within the match of
    // the one before it, but the third is 120 m from the anchor.
    RunFile oabTo(String id, double turn, int seed) =>
        _run(id, [(0, 0), (turn, 0), (0, 0)], seed: seed);
    final runs = [aOab, oabTo('b', 1560, 21), oabTo('c', 1620, 22)];
    final facts = [
      for (final (i, r) in runs.indexed)
        TrailRunFacts(
          id: r.id,
          start: DateTime.utc(2026, 9, 1 + i),
          movingMs: r.samples.last.tMs,
          distanceM: r.distanceM,
          route: sig(r),
        ),
    ];
    final groups = Trails.group(facts);
    final desc = [for (final g in groups) g.runs.map((r) => r.id).join('+')];
    rows.add(
      _Row(
        'Chain by date: turn at 1500, 1560, 1620 m',
        108,
        groups.length == 1,
        'n/a',
        'groups: ${desc.join(' | ')}; out and backs no longer chain-split on turn points',
      ),
    );
    expect(desc, ['oab+b+c']);
  });

  tearDownAll(() {
    final out = Platform.environment['AUDIT_OUT'];
    if (out == null) return;
    final b = StringBuffer()
      ..writeln(
        '| Scenario | Length vs anchor | Boards say same trail | In-run ghost | Note |',
      )
      ..writeln('|---|---|---|---|---|');
    for (final r in rows) {
      b.writeln(
        '| ${r.name} | ${r.lengthPct}% | ${r.boards ? 'yes' : 'no'} | ${r.ghost} | ${r.note} |',
      );
    }
    File(out).writeAsStringSync(b.toString());
  });
}
