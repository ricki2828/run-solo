import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:run_solo/topo/pack_models.dart';

/// A loopback HTTP server that behaves like the R2 bucket: static files, HTTP
/// Range, and a switch to cut the connection mid-body.
class FakePackServer {
  FakePackServer._(this._server);

  static Future<FakePackServer> start() async {
    final s = FakePackServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    s._server.listen(s._handle);
    return s;
  }

  final HttpServer _server;

  /// url path -> body.
  final Map<String, Uint8List> files = {};
  final List<String> requests = [];
  final List<String?> ranges = [];

  /// Cut the connection after this many body bytes, once (then resets).
  int? cutAfter;

  /// Answer 200 with the whole file even when Range is asked.
  bool ignoreRange = false;
  int? failStatus;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/maps');

  Future<void> close() => _server.close(force: true);

  /// Adds a pack's files and returns its `regions.json` entry.
  Map<String, Object?> addPack(
    String id, {
    String version = 'v1',
    int bytes = 300000,
    List<double> bbox = const [24.3, 36.64, 24.55, 36.76],
    String? name,
    int seed = 1,
  }) {
    final specs = <Map<String, Object?>>[];
    for (final (i, n) in ['basemap.pmtiles', 'terrain.pmtiles'].indexed) {
      final body = Uint8List.fromList([
        for (var b = 0; b < bytes ~/ (i + 1); b++) (b * 31 + seed + i) & 0xff,
      ]);
      files['/maps/$id/$version/$n'] = body;
      specs.add({
        'name': n,
        'size': body.length,
        'sha256': sha256.convert(body).toString(),
      });
    }
    return {
      'id': id,
      'name': name ?? id,
      'bbox': bbox,
      'version': version,
      'files': specs,
      'attribution': {
        'map_text': '© OpenStreetMap contributors | Protomaps',
        'credits': [
          {'text': '© OpenStreetMap contributors', 'license': 'ODbL 1.0'},
        ],
      },
    };
  }

  void setIndex(List<Map<String, Object?>> regions) {
    files['/maps/regions.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode({'schema': 1, 'regions': regions})),
    );
  }

  Future<void> _handle(HttpRequest req) async {
    requests.add(req.uri.path);
    ranges.add(req.headers.value(HttpHeaders.rangeHeader));
    final res = req.response;
    final status = failStatus;
    final body = files[req.uri.path];
    if (status != null) {
      res.statusCode = status;
      await res.close();
      return;
    }
    if (body == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    var start = 0;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null && !ignoreRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length) {
        res.statusCode = 416;
        await res.close();
        return;
      }
      res.statusCode = 206;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${body.length - 1}/${body.length}',
      );
    }
    final slice = Uint8List.sublistView(body, start);
    res.contentLength = slice.length;
    final cut = cutAfter;
    if (cut != null && cut < slice.length) {
      cutAfter = null;
      final socket = await res.detachSocket();
      socket.add(Uint8List.sublistView(slice, 0, cut));
      await socket.flush();
      socket.destroy();
      return;
    }
    res.add(slice);
    await res.close();
  }
}

PackRegion regionOf(Map<String, Object?> j) => PackRegion.fromJson(j);
