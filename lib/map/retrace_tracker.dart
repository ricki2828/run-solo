/// Which stretches of the live track are a retrace of the runner's own
/// earlier track, so the map can draw them in a second style, and what the
/// old track still ahead looks like.
///
/// One source of truth: the recorder's native retrace state (the same one the
/// run screen and the voice use) says WHETHER the runner is retracing and in
/// which direction. This class never decides that; it only cuts the live
/// points into sections and builds the old stretch ahead. It holds a bounded
/// copy of the track (decimated past [maxPoints]); the recorder keeps the
/// full route. Pure Dart.
library;

import 'dart:math' as math;

import 'route_builder.dart';

/// What the map needs from the recorder's retrace state.
class RetraceInput {
  const RetraceInput({this.retracing = false, this.same = false});
  static const RetraceInput none = RetraceInput();

  /// Back on the runner's own earlier track.
  final bool retracing;

  /// Covering it in the same direction (a second lap), not heading back.
  final bool same;

  @override
  bool operator ==(Object other) =>
      other is RetraceInput &&
      other.retracing == retracing &&
      other.same == same;

  @override
  int get hashCode => Object.hash(retracing, same);
}

class RetraceTracker {
  RetraceTracker({this.maxPoints = 2000, this.sustainM = 100, this.gapM = 30});

  /// The copy of the track is thinned past this many points.
  final int maxPoints;

  /// The native detector decides after about this much running on the old
  /// track, so a section opens this far back.
  final double sustainM;

  /// A retrace that stops and restarts within this much track is one
  /// section: a turnaround or GPS wobble must not flicker the style.
  final double gapM;

  /// Sections kept once closed (oldest dropped).
  static const int maxClosed = 20;

  final List<GeoPoint> _pts = [];
  final List<double> _cum = [];
  final List<List<GeoPoint>> _closed = [];
  RetraceInput _in = RetraceInput.none;

  // The open section: from [_openFrom] to the end, or to [_offIdx] once the
  // native state went false (it is closed after [gapM] more track).
  int? _openFrom;
  int? _offIdx;
  double? _offCum;
  bool _same = false;

  // Track distance where the last closed section ended: a reopened section's
  // backdate never goes behind it, so sections do not overlap.
  double _closedEndCum = 0;

  // Where the runner is on the old stretch (index into _pts), found by
  // nearest point and followed incrementally.
  int? _match;
  List<GeoPoint>? _ahead;
  double _aheadMaxM = 0;

  /// Points held (bounded by [maxPoints]).
  int get length => _pts.length;

  bool get retracing => _openFrom != null && _offIdx == null;

  /// All sections to draw: closed ones and the open one.
  List<List<GeoPoint>> get sections => [
    ..._closed,
    if (_openFrom != null)
      _pts.sublist(_openFrom!, (_offIdx ?? _pts.length - 1) + 1),
  ];

  void clear() {
    _pts.clear();
    _cum.clear();
    _closed.clear();
    _in = RetraceInput.none;
    _openFrom = _offIdx = _match = null;
    _offCum = null;
    _closedEndCum = 0;
    _ahead = null;
  }

  /// The recorder's retrace state, as of now (call on every change).
  /// Returns true when what is drawn may have changed.
  bool update(RetraceInput state) {
    if (state == _in) return false;
    _in = state;
    _ahead = null;
    if (state.retracing) {
      _offIdx = null;
      _offCum = null;
      _same = state.same;
      _openIfNeeded();
    } else if (_openFrom != null && _offIdx == null && _pts.isNotEmpty) {
      _offIdx = _pts.length - 1;
      _offCum = _cum.last;
    }
    return true;
  }

  void _openIfNeeded() {
    if (!_in.retracing || _openFrom != null || _pts.isEmpty) return;
    _match = null;
    var i = _pts.length - 1;
    while (i > 0 &&
        _cum.last - _cum[i] < sustainM &&
        _cum[i - 1] >= _closedEndCum) {
      i--;
    }
    _openFrom = i;
  }

  /// Feeds new live points; returns true when what is drawn may have changed.
  bool add(Iterable<GeoPoint> points) {
    var any = false;
    for (final p in points) {
      final prev = _pts.isEmpty ? null : _pts.last;
      _pts.add(p);
      _cum.add(prev == null ? 0 : _cum.last + _metres(prev, p));
      any = true;
    }
    if (!any) return false;
    _ahead = null;
    _openIfNeeded(); // the screen was recreated mid-retrace
    final off = _offCum;
    if (_openFrom != null &&
        _offIdx != null &&
        off != null &&
        _cum.last - off >= gapM) {
      _closed.add(_pts.sublist(_openFrom!, _offIdx! + 1));
      _closedEndCum = off;
      if (_closed.length > maxClosed) _closed.removeAt(0);
      _openFrom = _offIdx = _match = null;
      _offCum = null;
    }
    while (_pts.length > maxPoints) {
      _thin();
    }
    return true;
  }

  /// Thins by distance so a long run stays bounded: keeps the first and
  /// last point and one point per `total / (maxPoints / 2)` metres between,
  /// so old and recent track end up with the same density however many times
  /// this runs (halving repeatedly left the oldest track coarsest). The
  /// result is about half of [maxPoints], so the cap holds with headroom.
  /// Indices are remapped.
  void _thin() {
    final n = _pts.length;
    final spacing = math.max(_cum.last / (maxPoints / 2), 1e-6);
    var keep = <int>[0];
    for (var i = 1; i < n - 1; i++) {
      if (_cum[i] - _cum[keep.last] >= spacing) keep.add(i);
    }
    keep.add(n - 1);
    if (keep.length >= n) {
      // Nothing to drop by distance (e.g. standing still): fall back to
      // every other point so the cap still holds.
      keep = [for (var i = 0; i < n; i += 2) i, if ((n - 1).isOdd) n - 1];
    }
    int remap(int old) {
      var lo = 0, hi = keep.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (keep[mid] <= old) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return lo;
    }

    final openFrom = _openFrom, offIdx = _offIdx;
    final newPts = [for (final i in keep) _pts[i]];
    final newCum = [for (final i in keep) _cum[i]];
    if (openFrom != null) _openFrom = remap(openFrom);
    if (offIdx != null) _offIdx = remap(offIdx);
    _pts
      ..clear()
      ..addAll(newPts);
    _cum
      ..clear()
      ..addAll(newCum);
    _match = null;
    _ahead = null;
  }

  /// The stretch of the OLD track still ahead of the runner, in the order
  /// they will run it, up to [maxM] metres. Colour it with `gradientRuns`
  /// and the grades come out in the runner's direction: on the way back a
  /// hill that was run up reads as down, and a descent reads as up. Empty
  /// when not retracing.
  ///
  /// The runner's place on the old stretch is the nearest old point to
  /// where they are now, followed incrementally (a window around the last
  /// match), so it does not depend on distances kept elsewhere.
  List<GeoPoint> ahead({double maxM = 2000}) {
    final from = _openFrom;
    if (!retracing || from == null || from < 2) return const [];
    final cached = _ahead;
    if (cached != null && _aheadMaxM == maxM) return cached;
    final here = _pts.last;
    // The old stretch is [0, old). Same direction: the second lap's own first
    // points sit just before `from` (the section is backdated by the
    // detector's decision distance), so stop short of them.
    var old = from;
    if (_same) {
      while (old > 2 && _cum[from] - _cum[old - 1] < sustainM * 1.5) {
        old--;
      }
    }
    if (old < 2) return const [];
    var lo = 0, hi = old - 1;
    final m = _match;
    if (m != null) {
      lo = math.max(0, m - 40);
      hi = math.min(old - 1, m + 40);
    }
    var best = -1;
    var bestD = double.infinity;
    for (var i = lo; i <= hi; i++) {
      final d = _sq(_pts[i], here);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return const [];
    if (m != null && bestD > _lostM * _lostM) {
      // The window may be stuck after a shortcut. Look wider, but bounded:
      // a coarse pass of at most [_coarseSteps] points over the whole old
      // stretch, then the points around its best.
      final step = math.max(1, (old / _coarseSteps).ceil());
      var cb = -1;
      var cd = double.infinity;
      for (var i = 0; i < old; i += step) {
        final d = _sq(_pts[i], here);
        if (d < cd) {
          cd = d;
          cb = i;
        }
      }
      if (cb >= 0) {
        for (
          var i = math.max(0, cb - step);
          i <= math.min(old - 1, cb + step);
          i++
        ) {
          final d = _sq(_pts[i], here);
          if (d < cd) {
            cd = d;
            cb = i;
          }
        }
        if (cd < bestD) {
          bestD = cd;
          best = cb;
        }
      }
    }
    _match = best;
    final out = <GeoPoint>[_pts[best]];
    var run = 0.0;
    if (!_same) {
      for (var i = best - 1; i >= 0 && run < maxM; i--) {
        run += _cum[i + 1] - _cum[i];
        out.add(_pts[i]);
      }
    } else {
      for (var i = best + 1; i < old && run < maxM; i++) {
        run += _cum[i] - _cum[i - 1];
        out.add(_pts[i]);
      }
    }
    _aheadMaxM = maxM;
    return _ahead = out.length < 2 ? const [] : out;
  }

  /// Further than this from the windowed match and the window may be lost.
  static const double _lostM = 30;
  static const int _coarseSteps = 200;

  static const double _mPerDeg = 111320;

  static double _metres(GeoPoint a, GeoPoint b) => math.sqrt(_sq(a, b));

  static double _sq(GeoPoint a, GeoPoint b) {
    final dy = (b.lat - a.lat) * _mPerDeg;
    final dx = (b.lon - a.lon) * _mPerDeg * math.cos(a.lat * math.pi / 180);
    return dx * dx + dy * dy;
  }
}
