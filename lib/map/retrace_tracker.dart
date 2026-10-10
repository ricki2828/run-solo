/// Which stretches of the live track are a retrace of the runner's own
/// earlier track, so the map can draw them in a second style.
///
/// Feeds the engine's [RetraceDetector] with the live points and cuts the
/// track into sections: a section opens when the detector says `retracing`
/// (backdated by the detector's sustain distance, because it only decides
/// after that much running) and closes when it stops. Pure Dart.
library;

import 'dart:math' as math;

import 'package:run_engine/run_engine.dart' show RetraceDetector;

import 'route_builder.dart';

class RetraceTracker {
  RetraceTracker({RetraceDetector? detector})
    : _detector = detector ?? RetraceDetector();

  final RetraceDetector _detector;
  final List<GeoPoint> _pts = [];
  final List<double> _cum = [];
  final List<List<GeoPoint>> _closed = [];
  int? _openFrom;

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
  }

  /// Feeds new points; returns true when the sections changed.
  bool add(Iterable<GeoPoint> points) {
    var changed = false;
    for (final p in points) {
      final prev = _pts.isEmpty ? null : _pts.last;
      _pts.add(p);
      _cum.add(prev == null ? 0 : _cum.last + _metres(prev, p));
      final s = _detector.add(lat: p.lat, lon: p.lon, elevM: p.ele);
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
