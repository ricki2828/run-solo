/// Downloads, verifies and keeps offline map packs (Topo).
///
/// Pure Dart over `dart:io`: no plugin. Rules:
/// - The network is only touched by [refreshRegions] and [download], which
///   the UI calls from a user tap. Nothing runs on start, on a timer or from
///   the map.
/// - A download writes `<root>/<id>/<file>.part`, resumes with an HTTP Range
///   request, checks sha256 against `regions.json`, and only when every file
///   passes does it rename the parts into place and write `installed.json`
///   last. A pack without `installed.json` is not installed.
/// - Files live at `<base>/<id>/<version>/<file>`, the index at
///   `<base>/regions.json`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../app/version.dart';
import 'pack_models.dart';

/// True when the phone is on Wi-Fi. TODO: no connectivity plugin is in the
/// app yet, so production passes null and the Wi-Fi-only switch is hidden
/// rather than shown unenforced.
typedef WifiProbe = Future<bool> Function();

const int kDefaultStorageCap = 1000 * 1000 * 1000;

class PackManager extends ChangeNotifier {
  PackManager({
    required this.root,
    this.baseUrl,
    this.capBytes = kDefaultStorageCap,
    this.wifi,
    HttpClient Function()? clientFactory,
    this.idleTimeout = const Duration(seconds: 30),
    this.userAgent = 'RunSupreme/$kAppVersion (Android)',
  }) : _newClient = clientFactory ?? HttpClient.new;

  /// `<app files>/topo`.
  final Directory root;

  /// Null until the hosting exists; every network call then refuses.
  final Uri? baseUrl;
  final int capBytes;
  final WifiProbe? wifi;
  final Duration idleTimeout;

  /// Cloudflare refuses some default agents, so we always say who we are.
  final String userAgent;
  final HttpClient Function() _newClient;

  List<PackRegion> _regions = const [];
  final Map<String, InstalledPack> _installed = {};
  final Map<String, int> _diskBytes = {};
  final Map<String, _Job> _jobs = {};
  final Map<String, PackException> _failed = {};
  bool _wifiOnly = true;
  bool _loaded = false;
  bool _refreshing = false;
  PackException? _refreshError;

  bool get loaded => _loaded;
  bool get refreshing => _refreshing;
  PackException? get refreshError => _refreshError;

  /// Packs on offer, from the last [refreshRegions] (kept on disk).
  List<PackRegion> get regions => _regions;
  List<InstalledPack> get installed => _installed.values.toList();

  bool get wifiOnly => _wifiOnly;

  /// False when there is no way to tell (no probe), so the UI hides the
  /// switch.
  bool get canEnforceWifiOnly => wifi != null;

  /// Everything the packs take on disk, including half-finished downloads.
  int get usedBytes {
    var n = 0;
    for (final id in {..._diskBytes.keys, ..._jobs.keys}) {
      final job = _jobs[id];
      // A running download grows faster than the scan: use its own count.
      n += job == null
          ? _diskBytes[id] ?? 0
          : (_installed[id]?.region.totalBytes ?? 0) + job.doneBytes;
    }
    return n;
  }

  Directory _dir(String id) => Directory('${root.path}/$id');

  File get _regionsFile => File('${root.path}/regions.json');
  File get _prefsFile => File('${root.path}/prefs.json');

  /// Reads prefs, the cached index and what is installed. No network.
  Future<void> load() async {
    await root.create(recursive: true);
    try {
      final p = jsonDecode(await _prefsFile.readAsString());
      if (p is Map && p['wifi_only'] is bool) {
        _wifiOnly = p['wifi_only'] as bool;
      }
    } on Object {
      // No prefs yet, or unreadable: the defaults stand.
    }
    try {
      _regions = _parseIndex(await _regionsFile.readAsString());
    } on Object {
      _regions = const [];
    }
    _installed.clear();
    _diskBytes.clear();
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final id = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      await _scan(id);
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _scan(String id) async {
    final dir = _dir(id);
    var bytes = 0;
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is File) bytes += await f.length();
      }
    }
    if (bytes == 0) {
      _diskBytes.remove(id);
    } else {
      _diskBytes[id] = bytes;
    }
    _installed.remove(id);
    try {
      final region = PackRegion.fromJson(
        (jsonDecode(
          await File('${dir.path}/installed.json').readAsString(),
        ) as Map).cast<String, Object?>(),
      );
      // Every file must be there at its recorded size: a pack that lost a
      // file is not installed, it is a repair.
      for (final f in region.files) {
        final file = File('${dir.path}/${f.name}');
        if (!await file.exists() || await file.length() != f.size) {
          return;
        }
      }
      _installed[id] = InstalledPack(region: region, directory: dir.path);
    } on Object {
      // No installed.json, or unreadable: not installed.
    }
  }

  Future<void> setWifiOnly(bool on) async {
    _wifiOnly = on;
    notifyListeners();
    await _writeAtomic(_prefsFile, jsonEncode({'wifi_only': on}));
  }

  PackStatus statusOf(String id) {
    final job = _jobs[id];
    if (job != null) {
      return PackStatus(
        PackStatusKind.downloading,
        doneBytes: job.doneBytes,
        totalBytes: job.region.totalBytes,
      );
    }
    final failed = _failed[id];
    final partial = _partialBytes(id);
    if (failed != null) {
      return PackStatus(
        PackStatusKind.failed,
        error: failed,
        partialBytes: partial,
      );
    }
    final have = _installed[id];
    if (have != null) {
      final offer = _regionFor(id);
      if (offer != null && offer.version != have.version) {
        return PackStatus(
          PackStatusKind.updateAvailable,
          totalBytes: offer.totalBytes,
        );
      }
      return const PackStatus(PackStatusKind.installed);
    }
    return PackStatus(PackStatusKind.notInstalled, partialBytes: partial);
  }

  int _partialBytes(String id) {
    final dir = _dir(id);
    if (!dir.existsSync()) return 0;
    var n = 0;
    for (final f in dir.listSync()) {
      if (f is File && f.path.endsWith('.part')) n += f.lengthSync();
    }
    return n;
  }

  PackRegion? _regionFor(String id) {
    for (final r in _regions) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The installed pack whose box holds the point; the tightest box wins
  /// where two overlap. Synchronous and offline: the map surface calls it.
  InstalledPack? packCovering(double lat, double lon) {
    InstalledPack? best;
    for (final p in _installed.values) {
      if (!p.region.contains(lat, lon)) continue;
      if (best == null || p.region.area < best.region.area) best = p;
    }
    return best;
  }

  // ---- network: explicit user actions only ----

  HttpClient _client() => _newClient()
    ..connectionTimeout = idleTimeout
    ..userAgent = userAgent;

  Uri _url(String path) {
    final base = baseUrl;
    if (base == null) {
      throw const PackException(
        PackErrorKind.notConfigured,
        'Offline maps are not switched on in this build.',
      );
    }
    final b = base.path.endsWith('/') ? base.path : '${base.path}/';
    return base.replace(path: '$b$path');
  }

  /// Fetches `regions.json` and keeps it on disk. Only on a user tap.
  Future<void> refreshRegions() async {
    if (_refreshing) return;
    _refreshing = true;
    _refreshError = null;
    notifyListeners();
    final client = _client();
    try {
      final req = await client.getUrl(_url('regions.json'));
      final res = await req.close().timeout(idleTimeout);
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(idleTimeout);
      if (res.statusCode != 200) {
        throw PackException(
          PackErrorKind.http,
          'The map list answered ${res.statusCode}.',
        );
      }
      final parsed = _parseIndex(body);
      _regions = parsed;
      await _writeAtomic(_regionsFile, body);
    } on PackException catch (e) {
      _refreshError = e;
      rethrow;
    } on FormatException catch (e) {
      _refreshError = PackException(
        PackErrorKind.badIndex,
        'The map list could not be read (${e.message}).',
      );
      throw _refreshError!;
    } on Object catch (e, st) {
      debugPrint('TOPO refresh failed: $e\n$st');
      _refreshError = _networkError(e);
      throw _refreshError!;
    } finally {
      client.close(force: true);
      _refreshing = false;
      notifyListeners();
    }
  }

  static List<PackRegion> _parseIndex(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map || j['regions'] is! List) {
        throw const FormatException('no regions list');
      }
      return [
        for (final r in j['regions'] as List)
          PackRegion.fromJson((r as Map).cast<String, Object?>()),
      ];
    } on FormatException {
      rethrow;
    } on Object {
      // A missing key or a wrong type in an entry.
      throw const FormatException('unexpected shape');
    }
  }

  static PackException _networkError(Object e) => switch (e) {
    TimeoutException() => const PackException(
      PackErrorKind.offline,
      'No answer from the map server.',
    ),
    FileSystemException() => const PackException(
      PackErrorKind.disk,
      'Could not write to the phone. Check it has free storage.',
    ),
    _ => PackException(
      PackErrorKind.offline,
      'Could not reach the map server.',
      detail: _describe(e),
    ),
  };

  /// "SocketException: Failed host lookup" and the like, one short line.
  static String _describe(Object e) {
    var msg = switch (e) {
      SocketException() => e.message,
      HandshakeException() => e.message,
      TlsException() => e.message,
      HttpException() => e.message,
      _ => e.toString(),
    }.replaceAll(RegExp(r'\s+'), ' ').trim();
    final os = switch (e) {
      SocketException(:final osError?) => osError.message,
      _ => '',
    };
    if (os.isNotEmpty && !msg.contains(os)) msg = '$msg ($os)';
    if (msg.length > 120) msg = '${msg.substring(0, 117)}...';
    return '${e.runtimeType}: $msg';
  }

  /// Installs or updates a pack. Returns true when installed, false when
  /// cancelled (the partial download is kept). Throws [PackException] on
  /// failure, and the status line shows it too. Only on a user tap.
  Future<bool> download(String id) async {
    if (_jobs.containsKey(id)) return false;
    final region = _regionFor(id);
    if (region == null) {
      throw PackException(PackErrorKind.unknownPack, 'No map called $id.');
    }
    _failed.remove(id);
    final job = _Job(region);
    _jobs[id] = job;
    notifyListeners();
    try {
      if (_wifiOnly && wifi != null && !await wifi!()) {
        throw const PackException(
          PackErrorKind.wifiRequired,
          'Connect to Wi-Fi, or turn off Wi-Fi only.',
        );
      }
      final dir = _dir(id);
      await dir.create(recursive: true);
      await _dropStaleParts(dir, region);
      await _scan(id);
      _checkCap(region);
      for (final spec in region.files) {
        if (job.cancelled) return false;
        await _fetchFile(job, dir, spec);
        if (job.cancelled) return false;
      }
      await _commit(dir, region);
      await _scan(id);
      return true;
    } on PackException catch (e) {
      _failed[id] = e;
      await _scan(id);
      rethrow;
    } on Object catch (e) {
      final pe = e is PackException ? e : _networkError(e);
      _failed[id] = pe;
      await _scan(id);
      throw pe;
    } finally {
      job.client?.close(force: true);
      _jobs.remove(id);
      notifyListeners();
    }
  }

  /// Stops a running download. The `.part` files stay, so the next tap
  /// resumes.
  void cancel(String id) {
    final job = _jobs[id];
    if (job == null) return;
    job.cancelled = true;
    job.client?.close(force: true);
  }

  /// Removes a pack and any half-finished download of it.
  Future<void> delete(String id) async {
    cancel(id);
    final dir = _dir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    _installed.remove(id);
    _diskBytes.remove(id);
    _failed.remove(id);
    notifyListeners();
  }

  /// Bytes the pack would take beyond the cap, or null when it fits. The cap
  /// is a budget on what packs take once installed: an update replaces the
  /// old files, so they do not count against it.
  int? shortfall(PackRegion region) {
    final id = region.id;
    final replaced = _installed[id]?.region.totalBytes ?? 0;
    final alreadyHere = _partialBytes(id);
    final after = usedBytes - replaced - alreadyHere + region.totalBytes;
    return after > capBytes ? after - capBytes : null;
  }

  void _checkCap(PackRegion region) {
    final over = shortfall(region);
    if (over != null) {
      throw PackException(
        PackErrorKind.storageCap,
        'Not enough room under your offline maps limit.',
        bytes: over,
      );
    }
  }

  /// A `.part` from another version is useless: drop it. Records the version
  /// being fetched.
  Future<void> _dropStaleParts(Directory dir, PackRegion region) async {
    final marker = File('${dir.path}/download.json');
    String? was;
    try {
      was =
          (jsonDecode(await marker.readAsString()) as Map)['version']
              as String?;
    } on Object {
      was = null;
    }
    if (was != region.version) {
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.part')) await f.delete();
      }
      await _writeAtomic(marker, jsonEncode({'version': region.version}));
    }
  }

  Future<void> _fetchFile(_Job job, Directory dir, PackFileSpec spec) async {
    final part = File('${dir.path}/${spec.name}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > spec.size) {
      await part.delete();
      have = 0;
    }
    job.currentBytes = have;
    notifyListeners();
    if (have < spec.size) await _range(job, part, spec, have);
    if (job.cancelled) return;
    final len = await part.length();
    if (len != spec.size) {
      throw const PackException(
        PackErrorKind.offline,
        'The download stopped early. Tap to resume.',
      );
    }
    final digest = (await sha256.bind(part.openRead()).first).toString();
    if (digest != spec.sha256) {
      await part.delete();
      throw PackException(
        PackErrorKind.checksum,
        'A file did not match what the map server listed (${spec.name}). '
        'It was discarded. Try again.',
      );
    }
    job.completedBytes += spec.size;
    job.currentBytes = 0;
  }

  Future<void> _range(_Job job, File part, PackFileSpec spec, int from) async {
    final id = job.region.id;
    final client = _client();
    job.client = client;
    RandomAccessFile? out;
    try {
      final req = await client.getUrl(
        _url('$id/${job.region.version}/${spec.name}'),
      );
      if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final res = await req.close().timeout(idleTimeout);
      var offset = from;
      if (res.statusCode == 416) {
        // Our partial is past what the server has: start the file again.
        await res.drain<void>();
        await part.delete();
        await _range(job, part, spec, 0);
        return;
      }
      if (res.statusCode == 200) {
        offset = 0; // the server ignored Range: it sent the whole file
      } else if (res.statusCode != 206) {
        await res.drain<void>();
        throw PackException(
          PackErrorKind.http,
          'The map server answered ${res.statusCode} for ${spec.name}.',
        );
      }
      out = await part.open(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );
      var written = offset;
      var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
      job.currentBytes = offset;
      await for (final chunk in res.timeout(idleTimeout)) {
        if (job.cancelled) return;
        written += chunk.length;
        if (written > spec.size) {
          throw const PackException(
            PackErrorKind.checksum,
            'The map server sent more than it listed.',
          );
        }
        await out.writeFrom(chunk);
        job.currentBytes = written;
        final t = DateTime.now();
        if (t.difference(lastNotify).inMilliseconds > 120) {
          lastNotify = t;
          notifyListeners();
        }
      }
      await out.flush();
    } on PackException {
      rethrow;
    } on Object catch (e, st) {
      if (job.cancelled) return;
      debugPrint('TOPO fetch failed: $e\n$st');
      throw _networkError(e);
    } finally {
      await out?.close();
      job.client = null;
      client.close(force: true);
    }
  }

  Future<void> _commit(Directory dir, PackRegion region) async {
    for (final f in region.files) {
      await File('${dir.path}/${f.name}.part').rename('${dir.path}/${f.name}');
    }
    await _writeAtomic(
      File('${dir.path}/installed.json'),
      jsonEncode(region.toJson()),
    );
    final marker = File('${dir.path}/download.json');
    if (await marker.exists()) await marker.delete();
  }

  static Future<void> _writeAtomic(File file, String text) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }
}

class _Job {
  _Job(this.region);
  final PackRegion region;
  HttpClient? client;
  bool cancelled = false;

  /// Verified files, plus the one being fetched.
  int completedBytes = 0;
  int currentBytes = 0;

  int get doneBytes => completedBytes + currentBytes;
}
