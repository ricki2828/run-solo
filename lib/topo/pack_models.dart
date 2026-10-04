/// Offline map packs (Topo): the shapes in `regions.json` and on disk.
///
/// A pack is one folder of three `.pmtiles` files (basemap, terrain,
/// contours). `regions.json` lists the packs on offer; the same entry is
/// stored as `installed.json` once a pack is installed.
library;

import 'package:flutter/foundation.dart';

@immutable
class PackFileSpec {
  const PackFileSpec({
    required this.name,
    required this.size,
    required this.sha256,
  });

  factory PackFileSpec.fromJson(Map<String, Object?> j) => PackFileSpec(
    name: j['name']! as String,
    size: (j['size']! as num).toInt(),
    sha256: (j['sha256']! as String).toLowerCase(),
  );

  final String name;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    'sha256': sha256,
  };
}

/// One line of credit: shown per pack in Settings (licences are a
/// compliance matter, not decoration).
@immutable
class PackCredit {
  const PackCredit({required this.text, this.license, this.url});

  factory PackCredit.fromJson(Map<String, Object?> j) => PackCredit(
    text: j['text']! as String,
    license: j['license'] as String?,
    url: j['url'] as String?,
  );

  final String text;
  final String? license;
  final String? url;

  Map<String, Object?> toJson() => {
    'text': text,
    if (license != null) 'license': license,
    if (url != null) 'url': url,
  };
}

/// A pack on offer (or installed). Bounding box is west, south, east, north.
@immutable
class PackRegion {
  const PackRegion({
    required this.id,
    required this.name,
    required this.bbox,
    required this.version,
    required this.files,
    this.mapText = '',
    this.credits = const [],
  });

  factory PackRegion.fromJson(Map<String, Object?> j) {
    final box = (j['bbox']! as List).map((e) => (e as num).toDouble()).toList();
    if (box.length != 4 || box[0] >= box[2] || box[1] >= box[3]) {
      throw const FormatException('bad bbox');
    }
    final id = j['id']! as String;
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
      throw FormatException('bad pack id: $id');
    }
    final files = [
      for (final f in j['files']! as List)
        PackFileSpec.fromJson((f as Map).cast<String, Object?>()),
    ];
    if (files.isEmpty) throw const FormatException('no files');
    for (final f in files) {
      if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(f.name) ||
          f.name.startsWith('.')) {
        throw FormatException('bad file name: ${f.name}');
      }
    }
    final att = (j['attribution'] as Map?)?.cast<String, Object?>() ?? {};
    return PackRegion(
      id: id,
      name: j['name']! as String,
      bbox: box,
      version: j['version']! as String,
      files: files,
      mapText: att['map_text'] as String? ?? '',
      credits: [
        for (final c in (att['credits'] as List?) ?? const [])
          PackCredit.fromJson((c as Map).cast<String, Object?>()),
      ],
    );
  }

  final String id;
  final String name;
  final List<double> bbox;
  final String version;
  final List<PackFileSpec> files;

  /// The short line for the map's attribution control.
  final String mapText;
  final List<PackCredit> credits;

  int get totalBytes => files.fold(0, (a, f) => a + f.size);

  bool contains(double lat, double lon) =>
      lon >= bbox[0] && lon <= bbox[2] && lat >= bbox[1] && lat <= bbox[3];

  double get area => (bbox[2] - bbox[0]) * (bbox[3] - bbox[1]);

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'bbox': bbox,
    'version': version,
    'total_bytes': totalBytes,
    'files': [for (final f in files) f.toJson()],
    'attribution': {
      'map_text': mapText,
      'credits': [for (final c in credits) c.toJson()],
    },
  };
}

/// An installed pack with the absolute path of each file, for the map
/// surface to hand to the renderer.
@immutable
class InstalledPack {
  const InstalledPack({required this.region, required this.directory});
  final PackRegion region;
  final String directory;

  String get id => region.id;
  String get version => region.version;

  /// Absolute path of one of the pack's files, e.g. `basemap.pmtiles`.
  String pathOf(String name) => '$directory/$name';
}

enum PackStatusKind {
  notInstalled,
  downloading,
  installed,
  updateAvailable,
  failed,
}

@immutable
class PackStatus {
  const PackStatus(
    this.kind, {
    this.doneBytes = 0,
    this.totalBytes = 0,
    this.partialBytes = 0,
    this.error,
  });

  final PackStatusKind kind;

  /// Downloading: bytes of this pack on disk so far, of [totalBytes].
  final int doneBytes;
  final int totalBytes;

  /// A half-finished download is kept, so the next try resumes from here.
  final int partialBytes;
  final PackException? error;

  double get progress => totalBytes == 0 ? 0 : doneBytes / totalBytes;
}

enum PackErrorKind {
  /// No base URL, or the network call needs one the user has not given.
  notConfigured,
  offline,
  http,
  badIndex,
  checksum,
  storageCap,
  wifiRequired,
  disk,
  unknownPack,
}

class PackException implements Exception {
  const PackException(this.kind, this.message, {this.bytes});
  final PackErrorKind kind;
  final String message;

  /// storageCap: bytes the download needs beyond what is free under the cap.
  final int? bytes;

  @override
  String toString() => 'PackException(${kind.name}): $message';
}
