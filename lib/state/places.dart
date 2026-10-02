/// Place names for finished runs.
///
/// A run's start point (first fix) is turned into a short area name by the
/// phone's own geocoder ([PlaceGateway]); the app makes no request itself.
/// The name is stored in the run's sidecar (`place`, `street`) and the index row, so
/// the point itself never leaves the phone through us.
///
/// - A run starting within [engine.RunIdentity.placeReuseRadiusM] of an
///   earlier run that already has a name reuses it, without asking the
///   geocoder (one park, one name). The street is only reused within
///   [engine.RunIdentity.streetReuseRadiusM]; further out it needs its own
///   lookup.
/// - A run with an area but no street is asked once for the street when its
///   detail opens (`streetTried` in the sidecar).
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

  final _inFlight = <String, Future<PlaceLookup?>>{};

  /// Runs already looked up this app session: one attempt each, so opening
  /// the same detail again does not ask again.
  final _attempted = <String>{};

  /// The run's place, resolving and saving it when it has none yet. Returns
  /// null when it cannot be named. At most one lookup per run per session
  /// and [maxTries] failures in all (counted in the sidecar). Never throws.
  Future<PlaceLookup?> ensure(String id) =>
      _inFlight[id] ??= _ensure(id).whenComplete(() {
        // A block body: returning the removed future would make it wait on
        // itself.
        _inFlight.remove(id);
      });

  /// At finish: remember the phone's UTC offset (the fallback for an indoor
  /// run), work out the zone the run started in from its fix, then name the
  /// start.
  Future<PlaceLookup?> onFinished(String id, {DateTime? now}) async {
    try {
      await store.setUtcOffset(
        id,
        (now ?? DateTime.now()).timeZoneOffset.inMinutes,
      );
    } catch (e) {
      debugPrint('place: could not stamp offset for $id ($e)');
    }
    try {
      await store.stampLocalTime(id);
    } catch (e) {
      debugPrint('place: could not stamp local time for $id ($e)');
    }
    return ensure(id);
  }

  Future<PlaceLookup?> _ensure(String id) async {
    try {
      final detail = await store.load(id);
      if (detail == null) return null;
      var area = detail.sidecar.place;
      var street = detail.sidecar.street;
      PlaceLookup? held() => area == null && street == null
          ? null
          : PlaceLookup(area: area, street: street);
      // An older run with an area but no street is asked once for the street
      // (streetTried), not every time its detail opens.
      final needArea = area == null;
      final needStreet =
          street == null && (needArea || !detail.sidecar.streetTried);
      if (!needArea && !needStreet) return held();
      final start = engine.RunIdentity.startOf(detail.run);
      if (start == null) return held();
      if (detail.sidecar.placeTries >= maxTries || !_attempted.add(id)) {
        return held();
      }
      final rows = [
        for (final r in await store.list())
          if (r.id != id && r.startPoint != null) r,
      ];
      if (needArea) {
        area = engine.RunIdentity.reusePlace(start.lat, start.lon, [
          for (final r in rows)
            if (r.place != null)
              (lat: r.startPoint!.lat, lon: r.startPoint!.lon, place: r.place!),
        ]);
      }
      if (needStreet) {
        street = engine.RunIdentity.reuseStreet(start.lat, start.lon, [
          for (final r in rows)
            if (r.street != null)
              (
                lat: r.startPoint!.lat,
                lon: r.startPoint!.lon,
                street: r.street!,
              ),
        ]);
      }
      final lookupWanted =
          (needArea && area == null) || (needStreet && street == null);
      var answered = !lookupWanted;
      var gotArea = !(needArea && area == null);
      if (lookupWanted) {
        final said = await _ask(id, start);
        answered = said != null;
        if (said != null) {
          if (needArea && area == null) {
            area = engine.RunIdentity.cleanPlace(said.area);
            gotArea = area != null;
          }
          if (needStreet && street == null) {
            street = engine.RunIdentity.cleanStreet(said.street);
          }
        }
      }
      if (needArea && area != null) await store.setPlace(id, area);
      // A street answer, even an empty one, closes the street question.
      if (needStreet && (street != null || answered)) {
        await store.setStreet(id, street);
      }
      if (!answered || !gotArea) await store.addPlaceTry(id);
      return held();
    } catch (e) {
      debugPrint('place: could not name $id ($e)');
      return null;
    }
  }

  Future<PlaceLookup?> _ask(String id, ({double lat, double lon}) start) async {
    try {
      return await gateway.placeName(start.lat, start.lon).timeout(timeout);
    } on TimeoutException {
      debugPrint('place: geocoder timed out for $id');
      return null;
    }
  }
}
