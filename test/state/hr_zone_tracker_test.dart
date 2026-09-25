import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/state/hr_zone_tracker.dart';

/// Plan §18.1 fixtures (a)–(f) against the UI mirror of the engine tracker.
/// Max 190: boundaries 114 / 133 / 152 / 171.
void main() {
  test('(a) ramp 120→175 at 1 bpm/s: four transitions, each ≥ 5 s after the boundary', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    final changes = <(int, int)>[]; // (tMs, zone)
    var last = -1;
    for (var s = 0; s <= 60; s++) {
      final z = tr.update(s * 1000, 120 + s).zone;
      if (z != last) {
        changes.add((s * 1000, z));
        last = z;
      }
    }
    expect(changes.first, (0, 2), reason: '120 is zone 2, set immediately');
    final transitions = changes.skip(1).toList();
    expect(transitions.map((c) => c.$2).toList(), [3, 4, 5]);
    // 133 boundary crossed (+2 hysteresis) at 135 = t 15 s, dwell 5 s → 20 s.
    expect(transitions[0].$1, greaterThanOrEqualTo(20000));
    // 152 → 154 at t 34 s, + 5 s → 39 s.
    expect(transitions[1].$1, greaterThanOrEqualTo(39000));
    // 171 → 173 at t 53 s, + 5 s → 58 s.
    expect(transitions[2].$1, greaterThanOrEqualTo(58000));
    for (var i = 1; i < transitions.length; i++) {
      expect(
        transitions[i].$1 - transitions[i - 1].$1,
        greaterThanOrEqualTo(5000),
      );
    }
  });

  test('(b) 4 s square wave 149/155 around 152 for 60 s: zero transitions', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    tr.update(0, 149); // zone 3 immediately
    var zone = tr.state.zone;
    var changes = 0;
    for (var s = 1; s <= 60; s++) {
      final hr = (s ~/ 2).isEven ? 149 : 155;
      final z = tr.update(s * 1000, hr).zone;
      if (z != zone) {
        changes++;
        zone = z;
      }
    }
    expect(changes, 0);
    expect(zone, 3);
  });

  test('(c) strap drop 3 s → no change, 6 s → zone 0', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    tr.update(0, 160);
    expect(tr.state.zone, 4);
    for (var s = 1; s <= 3; s++) {
      tr.update(s * 1000, null);
    }
    expect(tr.state.zone, 4);
    for (var s = 4; s <= 6; s++) {
      tr.update(s * 1000, null);
    }
    expect(tr.state.zone, 0);
    // Strap back: immediate again (no dwell from zone 0).
    expect(tr.update(7000, 160).zone, 4);
  });

  test('(e) first sample 165 → zone 4 at t=0, no dwell', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    expect(tr.update(0, 165).zone, 4);
    expect(tr.state.sinceMs, 0);
  });

  test('(f) recreate with (zone 4, 165) seed → first frame is zone 4', () {
    final tr = UiHrZoneTracker(maxHr: 190, seedZone: 4, seedHr: 165);
    expect(tr.state.zone, 4);
    // No samples yet for 4 s after recreate: still 4, not black.
    expect(tr.update(4000, null).zone, 4);
    expect(
      tr.update(6000, null).zone,
      0,
      reason: 'seeded with no HR for > 5 s',
    );
  });

  test('hysteresis: 1 bpm past a boundary does not count', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    tr.update(0, 150); // zone 3
    for (var s = 1; s <= 10; s++) {
      tr.update(s * 1000, 153); // 152 + 1: inside hysteresis
    }
    expect(tr.state.zone, 3);
    for (var s = 11; s <= 20; s++) {
      tr.update(s * 1000, 154); // 152 + 2: counts after 5 s dwell
    }
    expect(tr.state.zone, 4);
  });

  test('a spike back resets the dwell', () {
    final tr = UiHrZoneTracker(maxHr: 190);
    tr.update(0, 150);
    for (var s = 1; s <= 4; s++) {
      tr.update(s * 1000, 156);
    }
    tr.update(5000, 150); // back to zone 3 → candidate cleared
    for (var s = 6; s <= 9; s++) {
      tr.update(s * 1000, 156);
    }
    expect(tr.state.zone, 3, reason: 'only 4 s of continuous zone-4 samples');
    tr.update(10000, 156);
    tr.update(11000, 156);
    expect(tr.state.zone, 4);
  });
}
