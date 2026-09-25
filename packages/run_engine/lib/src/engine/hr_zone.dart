/// HR zones for the in-run background (plan §18.1, W4). Pure Dart so the
/// hysteresis, dwell and strap-loss rules are fixture-tested.
///
/// Zones are shares of the resolved max HR (`MetricsCalculator.maxHrFor`,
/// never `settings.maxHr` raw): Z1 < 60 %, Z2 60–70, Z3 70–80, Z4 80–90,
/// Z5 ≥ 90. Zone 0 = no HR. The engine's 85–95 % time-in-zone window is a
/// different concept ("in the 4x4 band") and is untouched.
library;

/// The tracker's output: current zone (0–5) and when it became current.
class ZoneState {
  const ZoneState({required this.zone, required this.sinceMs});

  final int zone;

  /// Run-clock ms of the sample that made [zone] current (the seed time
  /// after a recreate).
  final int sinceMs;

  @override
  bool operator ==(Object other) =>
      other is ZoneState && other.zone == zone && other.sinceMs == sinceMs;

  @override
  int get hashCode => Object.hash(zone, sinceMs);

  @override
  String toString() => 'ZoneState(Z$zone since $sinceMs)';
}

/// One `update` result: the state after the sample and whether it changed
/// on this sample (the UI crossfades on `changed`).
class ZoneUpdate {
  const ZoneUpdate(this.state, {required this.changed});
  final ZoneState state;
  final bool changed;
  int get zone => state.zone;
}

class HrZoneTracker {
  /// [maxHr] is the resolved value from `maxHrFor`. Constructor for a fresh
  /// recording: zone 0 until the first HR sample.
  HrZoneTracker({
    required this.maxHr,
    this.hysteresisBpm = 2,
    this.dwellMs = 5000,
    this.lossMs = 5000,
    this.minChangeIntervalMs = 5000,
  }) : _state = const ZoneState(zone: 0, sinceMs: 0),
       _lastChangeMs = null;

  /// After an Activity recreate (W4): restore the last known zone and HR at
  /// once so the first frame is not black for 5 s. [atMs] is the run clock
  /// of the last tick the controller saw.
  HrZoneTracker.seeded({
    required this.maxHr,
    required int zone,
    required int? hr,
    required int atMs,
    this.hysteresisBpm = 2,
    this.dwellMs = 5000,
    this.lossMs = 5000,
    this.minChangeIntervalMs = 5000,
  }) : _state = ZoneState(zone: zone.clamp(0, 5), sinceMs: atMs),
       // Seeding is a restore, not a change: the next real change may
       // happen as soon as its dwell completes.
       _lastChangeMs = null,
       _lastHrMs = hr == null ? null : atMs;

  /// The resolved max HR the zones are shares of.
  final double maxHr;

  /// A boundary crossing counts only when HR is this far past the boundary.
  final double hysteresisBpm;

  /// The candidate zone must hold continuously this long before it becomes
  /// current; a sample back in the current zone resets it.
  final int dwellMs;

  /// HR null for longer than this → zone 0 (not instantly).
  final int lossMs;

  /// No zone change is ever emitted twice within this interval.
  final int minChangeIntervalMs;

  ZoneState _state;
  int? _lastChangeMs;
  int? _lastHrMs;
  int? _candidate;
  int? _candidateSinceMs;

  ZoneState get state => _state;
  int get zone => _state.zone;

  /// Lower boundary (bpm) of zone [z] for z in 2..5.
  double lowerBound(int z) =>
      maxHr *
      switch (z) {
        2 => 0.60,
        3 => 0.70,
        4 => 0.80,
        5 => 0.90,
        _ => throw ArgumentError.value(z, 'z', 'zones 2..5 have a lower bound'),
      };

  /// Zone of a raw HR with no hysteresis (1–5).
  int rawZone(int hr) {
    for (var z = 5; z >= 2; z--) {
      if (hr >= lowerBound(z)) return z;
    }
    return 1;
  }

  /// Zone [hr] resolves to when the current zone is [from], with hysteresis:
  /// stepping up into zone k needs `hr >= lower(k) + h`; stepping down out of
  /// zone k needs `hr <= lower(k) − h`. From zone 0 there is nothing to
  /// stick to, so the raw zone applies.
  int zoneWithHysteresis(int hr, int from) {
    if (from == 0) return rawZone(hr);
    var z = from;
    while (z < 5 && hr >= lowerBound(z + 1) + hysteresisBpm) {
      z++;
    }
    while (z > 1 && hr <= lowerBound(z) - hysteresisBpm) {
      z--;
    }
    return z;
  }

  /// Feed one tick. [hr] null = no strap reading in this tick.
  ZoneUpdate update(int tMs, int? hr) {
    if (hr == null) {
      _candidate = null;
      _candidateSinceMs = null;
      final last = _lastHrMs;
      if (_state.zone != 0 && (last == null || tMs - last > lossMs)) {
        return _change(0, tMs);
      }
      return ZoneUpdate(_state, changed: false);
    }
    _lastHrMs = tMs;
    final current = _state.zone;
    final target = zoneWithHysteresis(hr, current);
    if (target == current) {
      _candidate = null;
      _candidateSinceMs = null;
      return ZoneUpdate(_state, changed: false);
    }
    // From zone 0 the first valid HR sets the zone at once (W4), unless a
    // change was emitted under minChangeIntervalMs ago (strap flapping):
    // then it goes through the dwell like any other change.
    final lastChange = _lastChangeMs;
    if (current == 0 &&
        (lastChange == null || tMs - lastChange >= minChangeIntervalMs)) {
      return _change(target, tMs);
    }
    if (_candidate != target) {
      _candidate = target;
      _candidateSinceMs = tMs;
    }
    if (tMs - _candidateSinceMs! >= dwellMs &&
        (lastChange == null || tMs - lastChange >= minChangeIntervalMs)) {
      return _change(target, tMs);
    }
    return ZoneUpdate(_state, changed: false);
  }

  ZoneUpdate _change(int zone, int tMs) {
    _state = ZoneState(zone: zone, sinceMs: tMs);
    _lastChangeMs = tMs;
    _candidate = null;
    _candidateSinceMs = null;
    return ZoneUpdate(_state, changed: true);
  }

  /// Zone label for the header ("ZONE 4 · HARD"); label + number, never
  /// colour alone.
  static String label(int zone) => switch (zone) {
    1 => 'EASY',
    2 => 'STEADY',
    3 => 'TEMPO',
    4 => 'HARD',
    5 => 'MAX',
    _ => 'NO HR',
  };
}
