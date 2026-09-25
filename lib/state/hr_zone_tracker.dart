/// Interim mirror of the engine's `HrZoneTracker` (plan §18.1) so the record
/// screen can be built and tested before `run2-engine-fable` ships
/// `packages/run_engine/lib/src/engine/hr_zone.dart`. Semantics copied from
/// the plan, not invented: 2 bpm hysteresis past a boundary, 5 s dwell of
/// continuous samples before a change (a spike back resets it), no HR for
/// > 5 s → zone 0, the first valid sample sets the zone immediately, a seed
/// on recreate paints the last zone on the first frame.
///
/// TODO(run2-app-fable): delete this file and import the engine tracker once
/// its branch lands; `RecordingController` only depends on [ZoneTracker].
library;

import 'package:flutter/foundation.dart';

@immutable
class ZoneState {
  const ZoneState({required this.zone, required this.sinceMs});

  /// 0 = no HR; 1–5 per the addendum A1 table.
  final int zone;

  /// Run time when this zone became current.
  final int sinceMs;
}

abstract class ZoneTracker {
  ZoneState get state;
  ZoneState update(int tMs, int? hr);
}

class UiHrZoneTracker implements ZoneTracker {
  UiHrZoneTracker({required this.maxHr, int? seedZone, int? seedHr})
    : _state = ZoneState(zone: seedZone ?? 0, sinceMs: 0),
      _lastHr = seedHr,
      _seeded = seedZone != null;

  static const int hysteresisBpm = 2;
  static const int dwellMs = 5000;
  static const int noHrMs = 5000;
  static const List<double> _bounds = [0.6, 0.7, 0.8, 0.9];

  final int maxHr;
  ZoneState _state;
  int? _lastHr;
  bool _seeded;
  int? _lastHrAtMs;
  int? _candidate;
  int? _candidateSinceMs;

  @override
  ZoneState get state => _state;

  int _rawZone(int hr) {
    final f = hr / maxHr;
    var z = 1;
    for (final b in _bounds) {
      if (f >= b) z++;
    }
    return z;
  }

  /// A crossing counts only when HR is ≥ 2 bpm past the boundary in the
  /// direction of travel; between the boundary and +2 the old zone holds.
  int _zoneWithHysteresis(int hr, int current) {
    if (current <= 0) return _rawZone(hr);
    final raw = _rawZone(hr);
    if (raw == current) return current;
    if (raw > current) {
      final boundary = _bounds[current - 1] * maxHr;
      return hr >= boundary + hysteresisBpm ? raw : current;
    }
    final boundary = _bounds[current - 2 < 0 ? 0 : current - 2] * maxHr;
    return hr <= boundary - hysteresisBpm ? raw : current;
  }

  @override
  ZoneState update(int tMs, int? hr) {
    if (hr == null || hr <= 0) {
      final lastAt = _lastHrAtMs;
      final lost = lastAt == null
          ? (!_seeded || tMs >= noHrMs)
          : tMs - lastAt > noHrMs;
      if (lost && _state.zone != 0) {
        _state = ZoneState(zone: 0, sinceMs: tMs);
        _candidate = null;
      }
      return _state;
    }
    _lastHr = hr;
    _lastHrAtMs = tMs;
    final current = _state.zone;
    final target = _zoneWithHysteresis(hr, current);
    if (current == 0) {
      // First valid sample (or return after a strap drop): immediate.
      _state = ZoneState(zone: target, sinceMs: tMs);
      _candidate = null;
      _seeded = true;
      return _state;
    }
    if (target == current) {
      _candidate = null;
      return _state;
    }
    if (_candidate != target) {
      _candidate = target;
      _candidateSinceMs = tMs;
      return _state;
    }
    if (tMs - _candidateSinceMs! >= dwellMs &&
        tMs - _state.sinceMs >= dwellMs) {
      _state = ZoneState(zone: target, sinceMs: tMs);
      _candidate = null;
    }
    return _state;
  }

  int? get lastHr => _lastHr;
}
