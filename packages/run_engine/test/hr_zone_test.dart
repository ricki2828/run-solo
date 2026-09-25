import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// Plan §18.1 fixtures (a)–(c), (e), (f); (d) is a widget test in the app.
/// Max HR 190 → boundaries Z2 114, Z3 133, Z4 152, Z5 171.
void main() {
  const maxHr = 190.0;

  /// Feeds `(t, hr)` pairs and returns the emitted changes as `t → zone`.
  List<(int, int)> run(HrZoneTracker tracker, Iterable<(int, int?)> ticks) {
    final changes = <(int, int)>[];
    for (final (t, hr) in ticks) {
      final u = tracker.update(t, hr);
      if (u.changed) changes.add((t, u.zone));
    }
    return changes;
  }

  Iterable<(int, int?)> ramp({
    required int from,
    required int to,
    int holdSeconds = 20,
  }) sync* {
    var t = 0;
    for (var hr = from; hr <= to; hr++, t++) {
      yield (t * 1000, hr);
    }
    for (var i = 0; i < holdSeconds; i++, t++) {
      yield (t * 1000, to);
    }
  }

  test('boundaries and raw zones', () {
    final z = HrZoneTracker(maxHr: maxHr);
    expect(z.lowerBound(2), 114);
    expect(z.lowerBound(3), 133);
    expect(z.lowerBound(4), 152);
    expect(z.lowerBound(5), 171);
    expect(z.rawZone(100), 1);
    expect(z.rawZone(114), 2);
    expect(z.rawZone(133), 3);
    expect(z.rawZone(152), 4);
    expect(z.rawZone(171), 5);
    expect(z.rawZone(200), 5);
    expect(HrZoneTracker.label(4), 'HARD');
    expect(HrZoneTracker.label(0), 'NO HR');
  });

  test('(a) ramp 120→175 at 1 bpm/s: exactly four transitions, each ≥ 5 s '
      'after its boundary', () {
    final changes = run(HrZoneTracker(maxHr: maxHr), ramp(from: 120, to: 175));
    // t=0: first sample 120 (63 %) → Z2 at once (W4).
    // Z3: boundary 133 crossed at t=13, +2 bpm hysteresis at t=15, dwell 5 s
    // → t=20. Z4: 152 at t=32, 154 at t=34 → t=39. Z5: 171 at t=51, 173 at
    // t=53 → t=58.
    expect(changes, [(0, 2), (20000, 3), (39000, 4), (58000, 5)]);
    const boundaryCrossedAt = {3: 13000, 4: 32000, 5: 51000};
    for (final (t, zone) in changes.skip(1)) {
      expect(
        t - boundaryCrossedAt[zone]!,
        greaterThanOrEqualTo(5000),
        reason: 'Z$zone',
      );
    }
  });

  test('(b) 4 s-period square wave 149/155 around the 152 boundary for 60 s '
      '→ zero transitions after the first sample', () {
    final ticks = <(int, int?)>[
      for (var t = 0; t < 60; t++) (t * 1000, (t ~/ 2).isEven ? 149 : 155),
    ];
    final tracker = HrZoneTracker(maxHr: maxHr);
    final changes = run(tracker, ticks);
    expect(changes, [
      (0, 3),
    ], reason: '149 is Z3; each 2 s half-period is under the 5 s dwell');
    expect(tracker.zone, 3);
  });

  test('(c) strap drop for 3 s → no change; 6 s → zone 0; return is immediate '
      'once 5 s have passed since the last change', () {
    final tracker = HrZoneTracker(maxHr: maxHr);
    final ticks = <(int, int?)>[
      for (var t = 0; t < 10; t++) (t * 1000, 160),
      // 3 s without HR (t=10,11,12), then back.
      (10000, null),
      (11000, null),
      (12000, null),
      for (var t = 13; t < 20; t++) (t * 1000, 160),
      // 6 s without HR (t=20..25): zone 0 once the gap exceeds 5 s.
      for (var t = 20; t < 26; t++) (t * 1000, null),
      (26000, null),
      (27000, 160),
      (28000, 160),
    ];
    final changes = run(tracker, ticks);
    // Last HR at t=19; t=25 is exactly 6 s later (> 5 s) → zone 0 at 25.
    // HR returns at t=27, only 2 s after the zone-0 change: it goes through
    // the dwell instead of flipping at once (no two changes within 5 s).
    expect(changes, [(0, 4), (25000, 0)]);
    expect(tracker.zone, 0);
  });

  test('(c′) after a loss, HR returning ≥ 5 s after the zone-0 change sets '
      'the zone at once', () {
    final tracker = HrZoneTracker(maxHr: maxHr);
    final ticks = <(int, int?)>[
      for (var t = 0; t < 10; t++) (t * 1000, 160),
      for (var t = 10; t < 30; t++) (t * 1000, null),
      (30000, 140),
    ];
    // Zone 0 at t=15 (last HR at 9, 15−9 = 6 > 5). Return at 30 ≥ 15+5.
    expect(run(tracker, ticks), [(0, 4), (15000, 0), (30000, 3)]);
  });

  test('(e) first sample 165 → zone 4 at t=0, no dwell', () {
    final tracker = HrZoneTracker(maxHr: maxHr);
    final u = tracker.update(0, 165);
    expect(u.changed, isTrue);
    expect(u.state, const ZoneState(zone: 4, sinceMs: 0));
  });

  test('(f) recreate seeded with (zone 4, 165) → first frame is zone 4, '
      'not a change', () {
    final tracker = HrZoneTracker.seeded(
      maxHr: maxHr,
      zone: 4,
      hr: 165,
      atMs: 600000,
    );
    expect(tracker.zone, 4);
    expect(tracker.state.sinceMs, 600000);
    final u = tracker.update(601000, 166);
    expect(u.changed, isFalse);
    expect(u.zone, 4);
    // A seeded tracker still needs the dwell for a real change.
    final changes = run(tracker, [
      for (var t = 602; t < 612; t++) (t * 1000, 140),
    ]);
    expect(changes, [(607000, 3)]);
  });

  test('(f′) seeded with no HR (zone 0) behaves like a fresh tracker', () {
    final tracker = HrZoneTracker.seeded(
      maxHr: maxHr,
      zone: 0,
      hr: null,
      atMs: 600000,
    );
    expect(tracker.update(601000, 140).changed, isTrue);
    expect(tracker.zone, 3);
  });

  test('a 3 s spike back to the old zone resets the dwell', () {
    final tracker = HrZoneTracker(maxHr: maxHr);
    final ticks = <(int, int?)>[
      (0, 140), // Z3
      (1000, 156), // candidate Z4 from t=1
      (2000, 156),
      (3000, 156),
      (4000, 140), // back in Z3: dwell reset
      (5000, 140),
      (6000, 140),
      (7000, 156), // candidate Z4 again from t=7
      (8000, 156),
      (9000, 156),
      (10000, 156),
      (11000, 156),
      (12000, 156), // 5 s after t=7 → change
    ];
    expect(run(tracker, ticks), [(0, 3), (12000, 4)]);
  });

  test('hysteresis: 1 bpm past a boundary is not a crossing, 2 bpm is', () {
    final up = HrZoneTracker(maxHr: maxHr);
    up.update(0, 140); // Z3
    expect(up.zoneWithHysteresis(152, 3), 3);
    expect(up.zoneWithHysteresis(153, 3), 3);
    expect(up.zoneWithHysteresis(154, 3), 4);
    // Down out of Z4 needs ≤ 150.
    expect(up.zoneWithHysteresis(151, 4), 4);
    expect(up.zoneWithHysteresis(150, 4), 3);
    // A big jump can cross two boundaries at once.
    expect(up.zoneWithHysteresis(180, 2), 5);
    expect(up.zoneWithHysteresis(100, 5), 1);
  });

  test('downward ramp emits each zone once, ≥ 5 s apart', () {
    final changes = run(
      HrZoneTracker(maxHr: maxHr),
      ramp(
        from: 175,
        to: 175,
        holdSeconds: 0,
      ).followedBy([for (var i = 1; i <= 80; i++) (i * 1000, 175 - i)]),
    );
    expect(changes.map((c) => c.$2).toList(), [5, 4, 3, 2, 1]);
    for (var i = 1; i < changes.length; i++) {
      expect(changes[i].$1 - changes[i - 1].$1, greaterThanOrEqualTo(5000));
    }
  });

  test('no zone change is ever emitted twice within 5 s (random walk)', () {
    // Deterministic pseudo-random HR around the Z3/Z4 boundary with drops.
    var seed = 12345;
    int next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed;
    }

    final ticks = <(int, int?)>[
      for (var t = 0; t < 1800; t++)
        (t * 1000, next() % 23 == 0 ? null : 140 + next() % 30),
    ];
    final changes = run(HrZoneTracker(maxHr: maxHr), ticks);
    for (var i = 1; i < changes.length; i++) {
      expect(
        changes[i].$1 - changes[i - 1].$1,
        greaterThanOrEqualTo(5000),
        reason: '${changes[i - 1]} → ${changes[i]}',
      );
    }
  });
}
