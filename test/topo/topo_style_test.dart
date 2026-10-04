import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/snapshot_cache.dart';
import 'package:run_solo/topo/pack_models.dart';
import 'package:run_solo/topo/topo_files.dart';
import 'package:run_solo/topo/topo_style.dart';

String _template() => File(kTopoStyleAsset).readAsStringSync();

InstalledPack _pack(
  String dir, {
  String version = '20261002',
  String text = '© OSM',
}) => InstalledPack(
  region: PackRegion(
    id: 'milos',
    name: 'Milos',
    bbox: const [24.3, 36.64, 24.55, 36.76],
    version: version,
    files: const [PackFileSpec(name: 'basemap.pmtiles', size: 1, sha256: 'a')],
    mapText: text,
    credits: const [],
  ),
  directory: dir,
);

Future<ByteData> _disk(String key) async {
  final b = File(key).readAsBytesSync();
  return ByteData.sublistView(Uint8List.fromList(b));
}

void main() {
  group('TopoStyle.build', () {
    final built = TopoStyle.build(
      _template(),
      packDir: '/data/topo/milos',
      glyphsDir: '/data/topo-assets/glyphs',
      attribution: '© OSM | Protomaps',
    );
    final style = jsonDecode(built) as Map<String, dynamic>;

    test('every placeholder is replaced with a real path', () {
      expect(built, isNot(contains('{pack}')));
      expect(built, isNot(contains('{glyphs}')));
      final sources = style['sources'] as Map<String, dynamic>;
      expect(
        sources['basemap']['url'],
        'pmtiles://file:///data/topo/milos/basemap.pmtiles',
      );
      expect(
        sources['terrain']['url'],
        'pmtiles://file:///data/topo/milos/terrain.pmtiles',
      );
      expect(
        sources['contours']['url'],
        'pmtiles://file:///data/topo/milos/contours.pmtiles',
      );
      expect(
        style['glyphs'],
        'file:///data/topo-assets/glyphs/{fontstack}/{range}.pbf',
      );
    });

    test('the pack text goes on the base source for the native control', () {
      expect(style['sources']['basemap']['attribution'], '© OSM | Protomaps');
    });

    test('every label uses the one bundled font stack', () {
      var labels = 0;
      for (final l in style['layers'] as List) {
        final font = (l['layout'] as Map?)?['text-font'];
        if (font != null) {
          labels++;
          expect(font, [kTopoFontStack]);
        }
      }
      expect(labels, greaterThan(0));
    });

    test('route sources and layers sit on top of the map', () {
      final sources = style['sources'] as Map<String, dynamic>;
      for (final id in const ['rs-plan', 'rs-track', 'rs-marks', 'rs-me']) {
        expect(sources[id]['type'], 'geojson');
        expect(sources[id]['data']['features'], isEmpty);
      }
      final ids = [for (final l in style['layers'] as List) l['id']];
      final routeAt = ids.indexOf('rs-plan-casing');
      expect(routeAt, greaterThan(0));
      expect(ids.sublist(routeAt), [
        'rs-plan-casing',
        'rs-plan',
        'rs-track-casing',
        'rs-track',
        'rs-marks',
        'rs-me',
      ]);
      // Casings under the lines they belong to.
      expect(ids.indexOf('rs-track-casing'), lessThan(ids.indexOf('rs-track')));
    });

    test('the template itself is not touched', () {
      expect(_template(), contains('{pack}'));
    });
  });

  group('route data', () {
    test('a line is lon/lat, with colours as properties', () {
      final fc = TopoStyle.line(
        const [(36.7, 24.4), (36.71, 24.41)],
        colour: const Color(0xFFFF8800),
        casing: const Color(0xFF050506),
      );
      final f = (fc['features']! as List).single as Map;
      expect(f['properties'], {'c': '#ff8800', 'k': '#050506'});
      expect((f['geometry'] as Map)['coordinates'], [
        [24.4, 36.7],
        [24.41, 36.71],
      ]);
    });

    test('fewer than two points draws nothing', () {
      final fc = TopoStyle.line(
        const [(36.7, 24.4)],
        colour: const Color(0xFFFFFFFF),
        casing: const Color(0xFF000000),
      );
      expect(fc['features'], isEmpty);
    });
  });

  test('glyph ranges the style lists are the files the app bundles', () {
    final files = Directory('assets/topo/glyphs/NotoSans')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.endsWith('.pbf'))
        .map((n) => n.replaceAll('.pbf', ''))
        .toSet();
    expect(files, kTopoGlyphRanges.toSet());
    for (final r in kTopoGlyphRanges) {
      expect(
        File('assets/topo/glyphs/NotoSans/$r.pbf').lengthSync(),
        greaterThan(1000),
      );
    }
  });

  group('TopoFiles', () {
    late Directory tmp;
    late Directory packsRoot;
    var loads = 0;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('topo_files');
      packsRoot = Directory('${tmp.path}/topo')..createSync();
      loads = 0;
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    TopoFiles files() => TopoFiles(
      packsRoot: packsRoot,
      loader: (k) {
        loads++;
        return _disk(k);
      },
    );

    test('copies glyphs beside the packs and writes the pack style', () async {
      final f = files();
      final path = await f.styleFor(_pack('${packsRoot.path}/milos'));
      expect(path, startsWith('${tmp.path}/topo-assets/styles/'));
      final style = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(
        (style['sources'] as Map)['basemap']['url'],
        'pmtiles://file://${packsRoot.path}/milos/basemap.pmtiles',
      );
      expect(style['glyphs'], 'file://${f.glyphsDir}/{fontstack}/{range}.pbf');
      for (final r in kTopoGlyphRanges) {
        expect(
          File('${f.glyphsDir}/$kTopoFontStack/$r.pbf').existsSync(),
          isTrue,
        );
      }
      // The pack manager's folder holds only packs.
      expect(packsRoot.listSync(), isEmpty);
    });

    test('second call and a second instance reuse the files', () async {
      final f = files();
      final pack = _pack('${packsRoot.path}/milos');
      final a = await f.styleFor(pack);
      final loadsAfterFirst = loads;
      expect(await f.styleFor(pack), a);
      expect(loads, loadsAfterFirst);
      // A later app start: glyph stamp and style file are found on disk.
      final again = files();
      final before = loads;
      expect(await again.styleFor(pack), a);
      expect(loads, before, reason: 'nothing recopied');
    });

    test('concurrent maps share one preparation', () async {
      final f = files();
      final pack = _pack('${packsRoot.path}/milos');
      final paths = await Future.wait([f.styleFor(pack), f.styleFor(pack)]);
      expect(paths.first, paths.last);
    });

    test('a new pack version gets a new style and drops the old one', () async {
      final f = files();
      final v1 = await f.styleFor(_pack('${packsRoot.path}/milos'));
      final v2 = await f.styleFor(
        _pack('${packsRoot.path}/milos', version: '20271101'),
      );
      expect(v2, isNot(v1));
      expect(File(v1).existsSync(), isFalse);
      expect(File(v2).existsSync(), isTrue);
      expect(v2, contains('v$kMapStyleVersion'));
    });

    test('a failed load can be retried', () async {
      var fail = true;
      final f = TopoFiles(
        packsRoot: packsRoot,
        loader: (k) {
          if (fail) throw StateError('no asset');
          return _disk(k);
        },
      );
      final pack = _pack('${packsRoot.path}/milos');
      await expectLater(f.styleFor(pack), throwsStateError);
      fail = false;
      expect(File(await f.styleFor(pack)).existsSync(), isTrue);
    });
  });
}
