/// Which stretches of the live track are a retrace of the runner's own
/// earlier track, so the map can draw them in a second style.
///
/// Feeds the engine's [RetraceDetector] with the live points and cuts the
/// track into sections: a section opens when the detector says `retracing`
/// (backdated by the detector's sustain distance, because it only decides
/// after that much running) and closes when it stops. Pure Dart.
library;

import 'dart:math' as math;

import 'package:run_engine/run_engine.dart'
    show RetraceDetector, RetraceDirection, RetraceState;

import 'route_builder.dart';

class RetraceTracker {
  RetraceTracker({RetraceDetector? detector})
    : _detector = detector ?? RetraceDetector();

  final RetraceDetector _detector;
  final List<GeoPoint> _pts = [];
  final List<double> _cum = [];
  final List<List<GeoPoint>> _closed = [];
  int? _openFrom;
  RetraceState _state = RetraceState.none;

  /// Metres of track kept in memory per section is bounded by the run; the
  /// sections are small next to the track itself.
  List<List<GeoPoint>> get sections => [
    ..._closed,
    if (_openFrom != null) _pts.sublist(_openFrom!),
  ];

  bool get retracing => _openFrom != null;

  /// Extra distance backdated when a section opens.
  double get backdateM => _detector.sustainM;

  void clear() {
    _detector.reset();
    _pts.clear();
    _cum.clear();
    _closed.clear();
    _openFrom = null;
    _state = RetraceState.none;
  }

  /// The stretch of the OLD track still ahead of the runner, in the order
  /// they will run it, up to [maxM] metres. Colour it with `gradientRuns`
  /// and the grades come out in the runner's direction: on the way back a
  /// hill that was run up reads as down, and a descent reads as up. Empty
  /// when not retracing.
  List<GeoPoint> ahead({double maxM = 2000}) {
    final d = _state.distanceToStartM;
    final from = _openFrom;
    if (!_state.retracing || d == null || from == null) return const [];
    // The matched point on the old track: where the recorded distance is d.
    var k = 0;
    while (k + 1 < from && _cum[k + 1] <= d) {
      k++;
    }
    final out = <GeoPoint>[_pts[k]];
    var run = 0.0;
    if (_state.direction == RetraceDirection.reverse) {
      for (var i = k - 1; i >= 0 && run < maxM; i--) {
        run += _cum[i + 1] - _cum[i];
        out.add(_pts[i]);
      }
    } else {
      for (var i = k + 1; i < from && run < maxM; i++) {
        run += _cum[i] - _cum[i - 1];
        out.add(_pts[i]);
      }
    }
    return out.length < 2 ? const [] : out;
  }

  /// Feeds new points; returns true when the sections changed.
  bool add(Iterable<GeoPoint> points) {
    var changed = false;
    for (final p in points) {
      final prev = _pts.isEmpty ? null : _pts.last;
      _pts.add(p);
      _cum.add(prev == null ? 0 : _cum.last + _metres(prev, p));
      final s = _state = _detector.add(lat: p.lat, lon: p.lon, elevM: p.ele);
      if (s.retracing) {
        if (_openFrom == null) {
          var i = _pts.length - 1;
          while (i > 0 && _cum.last - _cum[i] < backdateM) {
            i--;
          }
          _openFrom = i;
        }
        changed = true; // the open section grows
      } else if (_openFrom != null) {
        _closed.add(_pts.sublist(_openFrom!));
        _openFrom = null;
        changed = true;
      }
    }
    return changed;
  }

  static double _metres(GeoPoint a, GeoPoint b) {
    const mPerDeg = 111320.0;
    final dy = (b.lat - a.lat) * mPerDeg;
    final dx = (b.lon - a.lon) * mPerDeg * math.cos(a.lat * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }
}
