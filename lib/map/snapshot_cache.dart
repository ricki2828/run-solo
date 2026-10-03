/// Disk cache for the map snapshots behind Home's recent-run cards. Keyed by
/// run id + map style version + route fingerprint + card size, so a restyle,
/// a Fix laps / recalculation, or a different card size regenerates instead
/// of showing a stale or stretched image. Bounded in total size (LRU), swept
/// of stray temp files, and it remembers failed renders so a broken map is
/// not retried forever. Every method swallows I/O errors: a cache problem
/// means "miss", never a crash.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'route_builder.dart';

/// Bump when `assets/maps/night_session_card.json` or the map drawing on the
/// card changes, so cached PNGs are rebuilt.
const int kMapStyleVersion = 3;

/// Why a card render failed; decides whether and when it is retried.
enum MapFailure {
  /// Offline, timeout, no snapshot: retried on a later app open.
  transient,

  /// Flat grey snapshot (rejected key or SHA-1): backs off [kBlankBackoff].
  blank,

  /// Could not even set up the map: this session only, never persisted.
  permanent,
}

/// A blank snapshot is retried no sooner than this.
const Duration kBlankBackoff = Duration(days: 7);

/// Failed (transient) renders allowed per run + route before we stop trying.
const int kMaxRenderTries = 3;

/// Stable hash of what the card draws: route points (about 1 m grid) and the
/// marker set. Fix laps or a recalculation moves markers or points, so the
/// hash, and with it the cache key, changes.
String routeFingerprint(RouteGeometry route) {
  // 32-bit FNV-1a over 32-bit words.
  var h = 0x811c9dc5;
  void mix(int v) {
    h = ((h ^ (v & 0xffffffff)) * 0x01000193) & 0xffffffff;
  }

  void point(GeoPoint p) {
    mix((p.lat * 1e5).round());
    mix((p.lon * 1e5).round());
  }

  route.points.forEach(point);
  for (final m in route.markers) {
    mix(m.kind.index);
    mix(m.lapIndex ?? -1);
    for (final c in (m.label ?? "").codeUnits) {
      mix(c);
    }
    point(m.point);
  }
  return h.toRadixString(16);
}

/// What a card needs from the snapshot cache; tests use an in-memory one.
abstract interface class MapCardStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List png);
  Future<bool> mayRender(String key);
  Future<void> recordFailure(String key, MapFailure kind);
  Future<void> clearFailures(String key);
}

class MapSnapshotCache implements MapCardStore {
  MapSnapshotCache(this._dir, {this.maxBytes = 30 * 1024 * 1024});

  /// The app-wide cache under the platform cache directory (the OS may clear
  /// it; a miss just re-renders).
  static final MapSnapshotCache shared = MapSnapshotCache(() async {
    final base = await getApplicationCacheDirectory();
    return Directory('${base.path}/recent_maps');
  });

  final Future<Directory> Function() _dir;
  final int maxBytes;
  final LinkedHashMap<String, Uint8List> _mem = LinkedHashMap();
  static const _memCap = 8;
  static const _failuresFile = 'failures.json';

  /// Failure keys that failed in this app session: not retried until the
  /// next app open, whatever the persisted count says.
  final Set<String> _sessionFailed = {};
  Future<void>? _swept;

  /// `<runId>_v<style>_<routeHash>_<w>x<h>@<dpr>`, file-name safe. The run id
  /// has every non-alphanumeric (including `_`) turned into `-`.
  static String keyFor({
    required String runId,
    required int styleVersion,
    required String routeHash,
    required double width,
    required double height,
    required double pixelRatio,
  }) {
    final id = _safeId(runId);
    return '${id}_v${styleVersion}_${routeHash}_${width.round()}x'
        '${height.round()}@${pixelRatio.toStringAsFixed(2)}';
  }

  static String _safeId(String runId) =>
      runId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '-');

  /// The run-id part of a [keyFor] key.
  static String runPrefix(String key) {
    final i = key.indexOf('_v');
    return i < 0 ? key : key.substring(0, i);
  }

  /// [keyFor] without the card size: one failure record per run + route +
  /// style version.
  static String failureKey(String key) {
    final i = key.lastIndexOf('_');
    return i < 0 ? key : key.substring(0, i);
  }

  Future<Directory?> _safeDir() async {
    try {
      final dir = await _dir();
      await _sweep(dir);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Once per cache instance (app start): delete half-written temp files.
  Future<void> _sweep(Directory dir) => _swept ??= () async {
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.tmp')) await e.delete();
      }
    } catch (_) {}
  }();

  @override
  Future<Uint8List?> read(String key) async {
    final hot = _mem.remove(key);
    if (hot != null) {
      _mem[key] = hot;
      return hot;
    }
    try {
      final dir = await _safeDir();
      if (dir == null) return null;
      final f = File('${dir.path}/$key.png');
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) return null;
      // Touch for LRU eviction.
      unawaited(f.setLastModified(DateTime.now()).catchError((_) {}));
      _remember(key, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Writes [png], deletes older snapshots of the same run (other style
  /// version, route or card size) and evicts least recently used files past
  /// [maxBytes].
  @override
  Future<void> write(String key, Uint8List png) async {
    _remember(key, png);
    try {
      final dir = await _safeDir();
      if (dir == null) return;
      await dir.create(recursive: true);
      final prefix = runPrefix(key);
      for (final f in await _pngs(dir)) {
        final name = _stem(f);
        if (name != key && runPrefix(name) == prefix) {
          await f.delete();
          _mem.remove(name);
        }
      }
      // Temp + rename so a half-written PNG is never read as a hit.
      final tmp = File('${dir.path}/$key.tmp');
      await tmp.writeAsBytes(png, flush: true);
      await tmp.rename('${dir.path}/$key.png');
      await _evict(dir);
    } catch (_) {
      // Cache is best effort.
    }
  }

  Future<void> _evict(Directory dir) async {
    final files = <(File, int, DateTime)>[];
    var total = 0;
    for (final f in await _pngs(dir)) {
      final st = await f.stat();
      files.add((f, st.size, st.modified));
      total += st.size;
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (f, size, _) in files) {
      if (total <= maxBytes) break;
      await f.delete();
      _mem.remove(_stem(f));
      total -= size;
    }
  }

  /// Delete snapshots and failure records of runs that no longer exist.
  /// [liveRunIds] are raw run ids. An empty set means "history not loaded":
  /// nothing is deleted.
  Future<void> pruneOrphans(Set<String> liveRunIds) async {
    if (liveRunIds.isEmpty) return;
    final live = liveRunIds.map(_safeId).toSet();
    try {
      final dir = await _safeDir();
      if (dir == null || !await dir.exists()) return;
      for (final f in await _pngs(dir)) {
        final name = _stem(f);
        if (!live.contains(runPrefix(name))) {
          await f.delete();
          _mem.remove(name);
        }
      }
      final failures = await _readFailures(dir);
      final keep = {
        for (final e in failures.entries)
          if (live.contains(runPrefix(e.key))) e.key: e.value,
      };
      if (keep.length != failures.length) await _writeFailures(dir, keep);
    } catch (_) {}
  }

  /// Whether a render of [key] should be attempted: false after a failure in
  /// this session, once [kMaxRenderTries] failures are recorded, or while a
  /// blank-snapshot failure is inside [kBlankBackoff].
  @override
  Future<bool> mayRender(String key, {DateTime? now}) async {
    final fk = failureKey(key);
    if (_sessionFailed.contains(fk)) return false;
    final dir = await _safeDir();
    if (dir == null) return true;
    final rec = (await _readFailures(dir))[fk];
    if (rec == null) return true;
    if (rec.count >= kMaxRenderTries) return false;
    if (rec.blank) {
      final at = DateTime.fromMillisecondsSinceEpoch(rec.atMs);
      if ((now ?? DateTime.now()).difference(at) < kBlankBackoff) return false;
    }
    return true;
  }

  /// A render failed. Everything blocks retries for this session; all but
  /// [MapFailure.permanent] also persist a count and timestamp.
  @override
  Future<void> recordFailure(
    String key,
    MapFailure kind, {
    DateTime? now,
  }) async {
    final fk = failureKey(key);
    _sessionFailed.add(fk);
    if (kind == MapFailure.permanent) return;
    try {
      final dir = await _safeDir();
      if (dir == null) return;
      await dir.create(recursive: true);
      final failures = await _readFailures(dir);
      failures[fk] = _Failure(
        (failures[fk]?.count ?? 0) + 1,
        (now ?? DateTime.now()).millisecondsSinceEpoch,
        kind == MapFailure.blank,
      );
      await _writeFailures(dir, failures);
    } catch (_) {}
  }

  @override
  Future<void> clearFailures(String key) async {
    final fk = failureKey(key);
    _sessionFailed.remove(fk);
    try {
      final dir = await _safeDir();
      if (dir == null) return;
      final failures = await _readFailures(dir);
      if (failures.remove(fk) != null) await _writeFailures(dir, failures);
    } catch (_) {}
  }

  Future<Map<String, _Failure>> _readFailures(Directory dir) async {
    try {
      final f = File('${dir.path}/$_failuresFile');
      if (!await f.exists()) return {};
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.value case {
            'n': final int n,
            't': final int t,
            'b': final bool b,
          })
            e.key as String: _Failure(n, t, b),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeFailures(Directory dir, Map<String, _Failure> m) async {
    final tmp = File('${dir.path}/$_failuresFile.tmp');
    await tmp.writeAsString(
      jsonEncode({
        for (final e in m.entries)
          e.key: {'n': e.value.count, 't': e.value.atMs, 'b': e.value.blank},
      }),
      flush: true,
    );
    await tmp.rename('${dir.path}/$_failuresFile');
  }

  Future<List<File>> _pngs(Directory dir) async => [
    await for (final e in dir.list())
      if (e is File && e.path.endsWith('.png')) e,
  ];

  String _stem(File f) {
    final name = f.uri.pathSegments.last;
    return name.substring(0, name.length - 4);
  }

  void _remember(String key, Uint8List bytes) {
    _mem.remove(key);
    _mem[key] = bytes;
    while (_mem.length > _memCap) {
      _mem.remove(_mem.keys.first);
    }
  }
}

class _Failure {
  const _Failure(this.count, this.atMs, this.blank);
  final int count;
  final int atMs;
  final bool blank;
}
