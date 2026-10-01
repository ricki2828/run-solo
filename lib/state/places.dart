/// Place names for finished runs.
///
/// A run's start point (first fix) is turned into a short area name by the
/// phone's own geocoder ([PlaceGateway]); the app makes no request itself.
/// The name is stored in the run's sidecar (`place`) and the index row, so
/// the point itself never leaves the phone through us.
///
/// - A run starting within [engine.RunIdentity.placeReuseRadiusM] of an
///   earlier run that already has a name reuses it, without asking the
///   geocoder (one park, one name).
/// - No fix (indoor), no geocoder, offline or no answer: no place, never a
///   coordinate. The next call retries, so opening an old run's detail
///   backfills it lazily.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/gateway.dart';
import 'history_store.dart';

class PlaceResolver {
  PlaceResolver({required this.store, required this.gateway});

  final RunStore store;
  final PlaceGateway gateway;

  final _inFlight = <String, Future<String?>>{};

  /// The run's place, resolving and saving it when it has none yet. Returns
  /// null when it cannot be named. Never throws.
  Future<String?> ensure(String id) =>
      _inFlight[id] ??= _ensure(id).whenComplete(() {
        // A block body: returning the removed future would make it wait on
        // itself.
        _inFlight.remove(id);
      });

  Future<String?> _ensure(String id) async {
    try {
      final detail = await store.load(id);
      if (detail == null) return null;
      final have = detail.sidecar.place;
      if (have != null) return have;
      final start = engine.RunIdentity.startOf(detail.run);
      if (start == null) return null;
      final name = await _nameFor(id, start);
      if (name == null) return null;
      await store.setPlace(id, name);
      return name;
    } catch (e) {
      debugPrint('place: could not name $id ($e)');
      return null;
    }
  }

  Future<String?> _nameFor(String id, ({double lat, double lon}) start) async {
    final known = [
      for (final r in await store.list())
        if (r.id != id && r.place != null && r.startPoint != null)
          (lat: r.startPoint!.lat, lon: r.startPoint!.lon, place: r.place!),
    ];
    final reused = engine.RunIdentity.reusePlace(start.lat, start.lon, known);
    if (reused != null) return reused;
    return engine.RunIdentity.cleanPlace(
      await gateway.placeName(start.lat, start.lon),
    );
  }
}
