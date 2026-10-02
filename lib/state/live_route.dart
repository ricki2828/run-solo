/// The live run's route so far, for the record screen's MAP view. Fed by
/// `RoutePointsEvent` deltas (about 1 Hz, simplified natively); a gap or a
/// recreated screen is caught up with `routeSince`. A read-only copy: the
/// recorder never reads it back, so a map that fails changes nothing about
/// the run.
library;

import 'package:flutter/foundation.dart';

import '../map/route_builder.dart';

class LiveRouteTrack extends ChangeNotifier {
  final List<GeoPoint> _points = [];

  /// Points so far (oldest first). Read-only view.
  List<GeoPoint> get points => List.unmodifiable(_points);

  GeoPoint? get last => _points.isEmpty ? null : _points.last;
  int get count => _points.length;

  /// Applies a delta starting at point [fromIndex] (flat `[lat, lon, ...]`).
  /// Overlap with what is held is skipped. Returns false when the delta
  /// starts past the end (points were missed): the caller should
  /// [catchUp].
  bool apply(int fromIndex, List<double> latLon) {
    if (fromIndex > _points.length) return false;
    final skip = _points.length - fromIndex;
    var added = false;
    for (var i = skip * 2; i + 1 < latLon.length; i += 2) {
      _points.add(GeoPoint(latLon[i], latLon[i + 1]));
      added = true;
    }
    if (added) notifyListeners();
    return true;
  }

  void clear() {
    if (_points.isEmpty) return;
    _points.clear();
    notifyListeners();
  }
}
