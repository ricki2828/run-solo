/// Puts what MapLibre's native engine reads by path on disk: the bundled
/// glyphs and one ready-to-load style file per installed pack. Assets are not
/// `file://` readable in place (T0 spike), so both are copied into the app's
/// files dir on first use, atomically, and redone when [kMapStyleVersion]
/// or the pack's version changes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show ByteData, rootBundle;

import '../map/snapshot_cache.dart' show kMapStyleVersion;
import 'pack_models.dart';
import 'topo_style.dart';

typedef AssetLoader = Future<ByteData> Function(String key);

const String kTopoStyleAsset = 'assets/maps/aurora_topo.json';

/// Home card styles: a pale printed-map look (and its dark twin), generated
/// by tools/topo/build_card_style.py. The live and detail maps keep
/// [kTopoStyleAsset].
const String kTopoCardLightAsset = 'assets/maps/card/aurora_card_light.json';
const String kTopoCardDarkAsset = 'assets/maps/card/aurora_card_dark.json';
const String kTopoGlyphAssetDir = 'assets/topo/glyphs/NotoSans';

class TopoFiles {
  TopoFiles({
    required Directory packsRoot,
    AssetLoader? loader,
    this.cardLightAsset = kTopoCardLightAsset,
    this.cardDarkAsset = kTopoCardDarkAsset,
  }) : _dir = Directory('${packsRoot.parent.path}/topo-assets'),
       _load = loader ?? rootBundle.load;

  /// The style a Home card is drawn with, by theme. The harness points these
  /// at the variants (or the old dark style) to compare them.
  final String cardLightAsset;
  final String cardDarkAsset;

  /// False when the card uses the live map's own style (the old look): its
  /// snapshot then gets the card's tint and the gradient route.
  bool get printedCards =>
      cardLightAsset != kTopoStyleAsset && cardDarkAsset != kTopoStyleAsset;

  /// `<app files>/topo-assets`, beside the pack folder so the pack manager
  /// never mistakes it for a pack.
  final Directory _dir;
  final AssetLoader _load;
  final Map<String, Future<String>> _styles = {};
  Future<void>? _glyphs;

  String get glyphsDir => '${_dir.path}/glyphs';

  /// The style file for [pack]: pack paths filled in, glyphs ready. Safe to
  /// call from many map widgets at once; the work runs once per pack.
  Future<String> styleFor(InstalledPack pack) {
    final name = '${pack.id}-${pack.version}-v$kMapStyleVersion'.replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final path = '${_dir.path}/styles/$name.json';
    return _styles[path] ??= _prepare(pack, path).catchError((Object e) {
      _styles.remove(path);
      throw e;
    });
  }

  /// A one-off style for a Home card: the base style with the run's route
  /// data inside the file (a snapshot re-reads the style, so a route set on
  /// the live map afterwards would not be in it). Delete it with
  /// [dropCardStyle] when the snapshot is done.
  Future<String> cardStyleFor(
    InstalledPack pack, {
    required String key,
    required Map<String, Map<String, Object?>> data,
    double pixelScale = 1,
    bool dark = false,
    Map<String, String> swaps = const {},
  }) async {
    await (_glyphs ??= _copyGlyphs().catchError((Object e) {
      _glyphs = null;
      throw e;
    }));
    final bytes = await _load(dark ? cardDarkAsset : cardLightAsset);
    final text = TopoStyle.build(
      utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      ),
      packDir: pack.directory,
      glyphsDir: glyphsDir,
      routeData: data,
      pixelScale: pixelScale,
      swaps: swaps,
    );
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File('${_dir.path}/styles/card-$safe.json');
    await _writeAtomic(file, text);
    return file.path;
  }

  Future<void> dropCardStyle(String path) async {
    try {
      await File(path).delete();
    } on Object {
      // Already gone.
    }
  }

  Future<String> _prepare(InstalledPack pack, String path) async {
    await (_glyphs ??= _copyGlyphs().catchError((Object e) {
      _glyphs = null;
      throw e;
    }));
    final file = File(path);
    if (await file.exists() && await file.length() > 0) return path;
    final bytes = await _load(kTopoStyleAsset);
    final text = TopoStyle.build(
      utf8.decode(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      ),
      packDir: pack.directory,
      glyphsDir: glyphsDir,
    );
    await _writeAtomic(file, text);
    // Card styles that outlived their snapshot (a killed app) and older
    // styles of the same pack are dead weight.
    final prefix = '${pack.id}-';
    final stale = DateTime.now().subtract(const Duration(minutes: 10));
    await for (final e in file.parent.list()) {
      if (e is! File || e.path == path) continue;
      final name = e.uri.pathSegments.last;
      final oldStyle = name.startsWith(prefix);
      // A card style in use is minutes old at most.
      final deadCard =
          name.startsWith('card-') && e.lastModifiedSync().isBefore(stale);
      if (oldStyle || deadCard) await e.delete().catchError((Object _) => e);
    }
    return path;
  }

  Future<void> _copyGlyphs() async {
    final out = Directory('$glyphsDir/$kTopoFontStack');
    await out.create(recursive: true);
    final stamp = File('$glyphsDir/.v');
    final want = '$kMapStyleVersion:${kTopoGlyphRanges.join(',')}';
    try {
      if (await stamp.readAsString() == want) return;
    } on Object {
      // No stamp yet: copy.
    }
    for (final r in kTopoGlyphRanges) {
      final data = await _load('$kTopoGlyphAssetDir/$r.pbf');
      final tmp = File('${out.path}/$r.pbf.part');
      await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await tmp.rename('${out.path}/$r.pbf');
    }
    await _writeAtomic(stamp, want);
  }

  static Future<void> _writeAtomic(File file, String text) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.part');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }
}
