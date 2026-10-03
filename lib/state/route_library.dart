/// The route library (Follow a route): routes kept on the phone in
/// `files/state/routes.json`, a plain list. A route comes from a GPX or TCX
/// file the runner picks (only the simplified points are kept, never the file)
/// or from one of their own past runs. Nothing here touches the network.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../platform/transfer_gateway.dart'
    show RouteFileTooBig, kMaxRouteFileBytes;

class _ParseJob {
  const _ParseJob(this.text, this.now, this.fallbackName);
  final String text;
  final DateTime now;
  final String? fallbackName;
}

engine.SavedRoute _parseRoute(_ParseJob j) => const engine.RouteImporter()
    .fromFile(j.text, now: j.now, fallbackName: j.fallbackName);

abstract class RouteStore {
  Future<List<engine.SavedRoute>> load();
  Future<void> save(List<engine.SavedRoute> routes);
}

class MemoryRouteStore implements RouteStore {
  MemoryRouteStore([List<engine.SavedRoute>? initial]) : routes = [...?initial];
  List<engine.SavedRoute> routes;

  @override
  Future<List<engine.SavedRoute>> load() async => [...routes];

  @override
  Future<void> save(List<engine.SavedRoute> routes) async =>
      this.routes = [...routes];
}

/// `{"schema": 1, "routes": [...]}`; a missing or damaged file reads as no
/// routes, and one damaged route is skipped, never the whole list.
class FileRouteStore implements RouteStore {
  FileRouteStore(this.stateDir);
  final Directory stateDir;
  static const int schema = 1;

  File get file => File('${stateDir.path}/routes.json');

  @override
  Future<List<engine.SavedRoute>> load() async {
    try {
      if (!await file.exists()) return const [];
      final j = jsonDecode(await file.readAsString());
      if (j is! Map<String, Object?> || j['schema'] != schema) return const [];
      final list = j['routes'];
      if (list is! List) return const [];
      final out = <engine.SavedRoute>[];
      for (final e in list) {
        if (e is! Map<String, Object?>) continue;
        try {
          out.add(engine.SavedRoute.fromJson(e));
        } catch (err) {
          debugPrint('routes: skipped a damaged route ($err)');
        }
      }
      return out;
    } catch (e) {
      debugPrint('routes: unreadable, none loaded ($e)');
      return const [];
    }
  }

  @override
  Future<void> save(List<engine.SavedRoute> routes) async {
    await stateDir.create(recursive: true);
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tmp.writeAsString(
      jsonEncode({
        'schema': schema,
        'routes': [for (final r in routes) r.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// Thrown by [RouteLibrary.add] when the library is full.
class RouteLibraryFull implements Exception {
  const RouteLibraryFull();
  @override
  String toString() =>
      'The route library is full (${RouteLibrary.maxRoutes} routes). Delete one first.';
}

class RouteLibrary extends ChangeNotifier {
  RouteLibrary(this._store, {DateTime Function()? now, this.offIsolate = true})
    : _now = now ?? DateTime.now;

  /// Parse files in a background isolate. Widget tests turn it off (a real
  /// isolate never completes under their fake clock).
  final bool offIsolate;

  final RouteStore _store;
  final DateTime Function() _now;
  List<engine.SavedRoute> _routes = const [];
  Future<void> _writes = Future.value();

  static const int maxRoutes = 50;
  static const int maxNameLength = 40;

  /// Newest first.
  List<engine.SavedRoute> get routes => List.unmodifiable(_routes);

  engine.SavedRoute? byId(String id) {
    for (final r in _routes) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    _routes = _sorted(await _store.load());
    notifyListeners();
  }

  /// Synchronous seed for tests and the fake APK.
  void preload(List<engine.SavedRoute> routes) => _routes = _sorted(routes);

  static List<engine.SavedRoute> _sorted(List<engine.SavedRoute> r) =>
      [...r]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// A GPX or TCX file's text as a route. Throws
  /// [engine.ImportFormatException] when it is not a followable route and
  /// [RouteLibraryFull] when there is no room. The same file twice is one
  /// route.
  Future<engine.SavedRoute> importText(
    String text, {
    String? fallbackName,
  }) async {
    if (text.length > maxFileChars) throw const RouteFileTooBig();
    final now = _now().toUtc();
    // Parsing a big file must not hold the UI isolate.
    final job = _ParseJob(text, now, fallbackName);
    final route = offIsolate
        ? await compute(_parseRoute, job)
        : _parseRoute(job);
    return add(route);
  }

  /// Same cap as the picker's, in characters (one byte each for GPX/TCX).
  static const int maxFileChars = kMaxRouteFileBytes;

  /// One of the runner's own runs as a route ("Run this route again").
  Future<engine.SavedRoute> addFromRun(
    engine.RunFile run, {
    String? name,
  }) async => add(
    const engine.RouteImporter().fromRun(run, name: name, now: _now().toUtc()),
  );

  /// "Run this route again" from a run that followed a route: the planned
  /// line the run kept (not the line it ran). The library entry it came from
  /// is returned as it is while it is still there.
  Future<engine.SavedRoute> addFromFollowed(engine.FollowedRoute r) async =>
      add(const engine.RouteImporter().fromFollowed(r, now: _now().toUtc()));

  /// Adds [route]; a route already in the library (same id) is returned as it is.
  Future<engine.SavedRoute> add(engine.SavedRoute route) async {
    final have = byId(route.id);
    if (have != null) return have;
    if (_routes.length >= maxRoutes) throw const RouteLibraryFull();
    _routes = _sorted([route, ..._routes]);
    notifyListeners();
    await _persist();
    return route;
  }

  Future<void> rename(String id, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final clipped = n.length > maxNameLength
        ? n.substring(0, maxNameLength)
        : n;
    _routes = [for (final r in _routes) r.id == id ? r.renamed(clipped) : r];
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    if (byId(id) == null) return;
    _routes = [
      for (final r in _routes)
        if (r.id != id) r,
    ];
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() {
    final snapshot = [..._routes];
    return _writes = _writes.then((_) => _store.save(snapshot));
  }
}
