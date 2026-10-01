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
  PlaceResolver({
    required this.store,
    required this.gateway,
    this.timeout = const Duration(seconds: 10),
    this.maxTries = 3,
  });

  final RunStore store;
  final PlaceGateway gateway;

  /// A geocoder that never answers (no Play services, a stuck network) must
  /// not hold a lookup, or its in-flight slot, forever.
  final Duration timeout;

  /// Lookups that found no name before the app stops asking for a run.
  final int maxTries;

  final _inFlight = <String, Future<String?>>{};

  /// Runs already looked up this app session: one attempt each, so opening
  /// the same detail again does not ask again.
  final _attempted = <String>{};

  /// The run's place, resolving and saving it when it has none yet. Returns
  /// null when it cannot be named. At most one lookup per run per session
  /// and [maxTries] failures in all (counted in the sidecar). Never throws.
  Future<String?> ensure(String id) =>
      _inFlight[id] ??= _ensure(id).whenComplete(() {
        // A block body: returning the removed future would make it wait on
        // itself.
        _inFlight.remove(id);
      });

  /// At finish: remember the phone's UTC offset for the run (so its time of
  /// day is the zone it was run in), then name the start.
  Future<String?> onFinished(String id, {DateTime? now}) async {
    try {
      await store.setUtcOffset(
        id,
        (now ?? DateTime.now()).timeZoneOffset.inMinutes,
      );
    } catch (e) {
      debugPrint('place: could not stamp offset for $id ($e)');
    }
    return ensure(id);
  }

  Future<String?> _ensure(String id) async {
    try {
      final detail = await store.load(id);
      if (detail == null) return null;
      final have = detail.sidecar.place;
      if (have != null) return have;
      final start = engine.RunIdentity.startOf(detail.run);
      if (start == null) return null;
      if (detail.sidecar.placeTries >= maxTries || !_attempted.add(id)) {
        return null;
      }
      final name = await _nameFor(id, start);
      if (name == null) {
        await store.addPlaceTry(id);
        return null;
      }
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
    try {
      return engine.RunIdentity.cleanPlace(
        await gateway.placeName(start.lat, start.lon).timeout(timeout),
      );
    } on TimeoutException {
      debugPrint('place: geocoder timed out for $id');
      return null;
    }
  }
}
