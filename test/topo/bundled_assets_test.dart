import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/topo/bundled_assets.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.data);
  final Map<String, String> data;
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    final s = data[key];
    if (s == null) throw FlutterError('no asset $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(s)));
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('runsolo-assets-'));
  tearDown(() => dir.deleteSync(recursive: true));

  BundledAssets make(_Bundle b, String version) => BundledAssets(
    bundle: b,
    root: Directory('${dir.path}/topo-assets'),
    version: version,
    files: {
      'assets/maps/style.json': 'style.json',
      'assets/maps/glyphs/0-255.pbf': 'glyphs/0-255.pbf',
    },
  );

  final data = {
    'assets/maps/style.json': '{"v":1}',
    'assets/maps/glyphs/0-255.pbf': 'glyphs',
  };

  test('copies once per version and is idempotent', () async {
    final b = _Bundle(data);
    final out = await make(b, 'v1').install();
    expect(File('${out.path}/style.json').readAsStringSync(), '{"v":1}');
    expect(File('${out.path}/glyphs/0-255.pbf').readAsStringSync(), 'glyphs');
    final loads = b.loads;
    await make(b, 'v1').install();
    expect(b.loads, loads);
  });

  test('a new version replaces and prunes the old one', () async {
    final b = _Bundle(data);
    await make(b, 'v1').install();
    final out = await make(b, 'v2').install();
    expect(out.path, endsWith('/v2'));
    expect(Directory('${dir.path}/topo-assets/v1').existsSync(), isFalse);
  });

  test('a half-copied folder is never used', () async {
    final b = _Bundle({'assets/maps/style.json': '{}'});
    await expectLater(make(b, 'v1').install(), throwsA(isA<FlutterError>()));
    expect(Directory('${dir.path}/topo-assets/v1').existsSync(), isFalse);
    // Fixed asset set: the retry starts clean and succeeds.
    final out = await make(_Bundle(data), 'v1').install();
    expect(File('${out.path}/.complete').existsSync(), isTrue);
  });
}
