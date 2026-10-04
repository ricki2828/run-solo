/// The Topo style, glyph ranges and sprites ship as Flutter assets, but
/// MapLibre reads `file://` paths, so they are copied to the files dir once
/// per version. Atomic: a half-copied folder is never used, and old versions
/// are pruned.
library;

import 'dart:io';

import 'package:flutter/services.dart';

class BundledAssets {
  BundledAssets({
    required this.bundle,
    required this.root,
    required this.version,
    required this.files,
  });

  final AssetBundle bundle;

  /// `<app files>/topo-assets`.
  final Directory root;

  /// `kMapStyleVersion`: a new version means a new folder.
  final String version;

  /// Asset key -> path inside the version folder (e.g.
  /// `assets/maps/glyphs/Archivo/0-255.pbf` -> `glyphs/Archivo/0-255.pbf`).
  final Map<String, String> files;

  Directory get directory => Directory('${root.path}/$version');

  /// Copies the assets if this version is not there yet and returns the
  /// folder. Safe to call on every start.
  Future<Directory> install() async {
    final done = File('${directory.path}/.complete');
    if (await done.exists()) return directory;
    final staging = Directory('${root.path}/.$version.tmp');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    for (final e in files.entries) {
      if (e.value.contains('..') || e.value.startsWith('/')) {
        throw ArgumentError('bad asset path ${e.value}');
      }
      final data = await bundle.load(e.key);
      final out = File('${staging.path}/${e.value}');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    await File('${staging.path}/.complete').writeAsString(version);
    if (await directory.exists()) await directory.delete(recursive: true);
    await staging.rename(directory.path);
    await for (final e in root.list()) {
      if (e is Directory && e.path != directory.path) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!name.startsWith('.')) await e.delete(recursive: true);
      }
    }
    return directory;
  }
}
