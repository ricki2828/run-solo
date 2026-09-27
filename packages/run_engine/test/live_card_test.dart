import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// The design brief's A10.1 card copy table, one case per row, plus the
/// edges (level, one prior, miles, unknown kind).
void main() {
  test('km 3 of a Free run, 2nd of 7', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: '5K',
      index: 3,
      rank: 2,
      of: 7,
      deltaMs: 6200,
    )!;
    expect(c.rank, '#2 OF 7');
    expect(c.eyebrow, 'ON PACE FOR · 5Ks');
    expect(c.detail, '6 s behind your best');
    expect(c.direction, LiveCardDirection.behind);
  });

  test('km 4 ahead of the PB', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: '5K',
      index: 4,
      rank: 1,
      of: 7,
      deltaMs: -9000,
    )!;
    expect(c.rank, '#1 OF 7');
    expect(c.detail, '9 s ahead of your best');
    expect(c.direction, LiveCardDirection.ahead);
  });

  test('level rounds like the voice: under half a second is level', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: '10K',
      index: 7,
      rank: 1,
      of: 4,
      deltaMs: -400,
    )!;
    expect(c.eyebrow, 'ON PACE FOR · 10Ks');
    expect(c.detail, 'Level with your best');
    expect(c.direction, LiveCardDirection.level);
  });

  test('a course board spells its plural in capitals', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: 'Hill parkrun',
      index: 2,
      rank: 3,
      of: 5,
      deltaMs: 3000,
    )!;
    expect(c.eyebrow, 'ON PACE FOR · HILL PARKRUNS');
  });

  test('only one prior: the gap is the big line', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: '5K',
      index: 3,
      rank: 2,
      of: 2,
      deltaMs: 12000,
    )!;
    expect(c.rank, '12 s BEHIND');
    expect(c.eyebrow, 'VS YOUR ONLY OTHER 5K');
    expect(c.detail, 'at 3 km');
    expect(c.direction, LiveCardDirection.behind);
  });

  test('rep 3 end, 8 x 400 m, best start', () {
    final c = LiveCard.of(
      kind: 'intervals',
      boardLabel: '8 × 400 m',
      index: 3,
      rank: 1,
      of: 5,
      deltaSecPerKm: -5.2,
    )!;
    expect(c.rank, '#1 OF 5');
    expect(c.eyebrow, 'AFTER 3 REPS · 8 × 400 M');
    expect(c.detail, '5 s/km up on your best');
    expect(c.direction, LiveCardDirection.ahead);
  });

  test('intervals in miles', () {
    final c = LiveCard.of(
      kind: 'intervals',
      boardLabel: '8 × 400 m',
      index: 1,
      rank: 2,
      of: 2,
      deltaSecPerKm: 5,
      units: Units.mi,
    )!;
    expect(c.rank, '8 s BEHIND');
    expect(c.eyebrow, 'AFTER 1 REP · VS YOUR LAST');
    expect(c.detail, '8 s/mi off your best');
  });

  test('Cooper minute 6, heading for #2 of 4', () {
    final c = LiveCard.of(
      kind: 'cooper',
      boardLabel: 'Cooper',
      index: 6,
      rank: 2,
      of: 4,
      deltaVo2: -1.2,
      value: 50.3,
    )!;
    expect(c.rank, '#2 OF 4');
    expect(c.eyebrow, 'HEADING FOR · 12-MIN TESTS');
    expect(c.detail, 'VO2 est. 50');
    expect(c.direction, LiveCardDirection.level);
    expect(carriesEstimateMarker(c.detail), isTrue);
  });

  test('Cooper with one earlier test', () {
    final c = LiveCard.of(
      kind: 'cooper',
      boardLabel: 'Cooper',
      index: 3,
      rank: 1,
      of: 2,
      deltaVo2: 2.4,
      value: 52,
    )!;
    expect(c.rank, 'UP 2');
    expect(c.eyebrow, 'VS YOUR LAST TEST');
    expect(c.direction, LiveCardDirection.ahead);
  });

  test('timed 5 km, km 2 vs the predicted time', () {
    final c = LiveCard.of(
      kind: 'target',
      boardLabel: 'predicted',
      index: 2,
      rank: 1,
      of: 1,
      deltaMs: -8000,
      value: 24 * 60 * 1000 + 30 * 1000,
      targetM: 5000,
    )!;
    expect(c.rank, '8 s AHEAD');
    expect(c.eyebrow, 'VS PREDICTED 24:30');
    // 24:30 − 8 s × 5000 / 2000 = 24:10.
    expect(c.detail, 'On pace for 24:10 (predicted)');
    expect(carriesEstimateMarker(c.detail), isTrue);
  });

  test('target without a distance says where', () {
    final c = LiveCard.of(
      kind: 'target',
      boardLabel: 'target',
      index: 2,
      rank: 1,
      of: 1,
      deltaMs: 3000,
      value: 1500000,
    )!;
    expect(c.eyebrow, 'VS YOUR TARGET 25:00');
    expect(c.detail, 'at 2 km');
    expect(c.direction, LiveCardDirection.behind);
  });

  test('unknown kind or a missing figure: no card', () {
    expect(
      LiveCard.of(kind: 'x', boardLabel: '5K', index: 1, rank: 1, of: 3),
      isNull,
    );
    expect(
      LiveCard.of(kind: 'distance', boardLabel: '5K', index: 1, rank: 1, of: 3),
      isNull,
    );
  });

  test('copy: no em dashes, semantics carries every line', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: '5K',
      index: 3,
      rank: 2,
      of: 7,
      deltaMs: 6000,
    )!;
    for (final s in [c.rank, c.eyebrow, c.detail, c.semantics]) {
      expect(s.contains('—'), isFalse, reason: s);
    }
    expect(c.semantics, '#2 OF 7. ON PACE FOR · 5Ks. 6 s behind your best.');
  });

  test('a time goal: #1 of 3, about 6.4 km at the finish', () {
    final c = LiveCard.of(
      kind: 'distanceInTime',
      boardLabel: '30 min',
      index: 12,
      rank: 1,
      of: 3,
      value: 6412,
    )!;
    expect(c.rank, '#1 OF 3');
    expect(c.eyebrow, 'ON PACE FOR · 30 MIN');
    expect(c.detail, 'About 6.4 km at the finish');
    expect(carriesEstimateMarker(c.detail), isTrue);
  });

  test('a distance goal races its board like any distance', () {
    final c = LiveCard.of(
      kind: 'distance',
      boardLabel: 'Half',
      index: 8,
      rank: 2,
      of: 5,
      deltaMs: 40000,
    )!;
    expect(c.rank, '#2 OF 5');
    expect(c.eyebrow, 'ON PACE FOR · HALF MARATHONS');
  });
}
