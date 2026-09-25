import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/blank_snapshot.dart';

/// W9: a map whose key or SHA-1 was refused stays one flat colour.
Uint8List bitmap(int w, int h, int Function(int x, int y) rgb) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = rgb(x, y);
      final i = (y * w + x) * 4;
      out[i] = (c >> 16) & 0xff;
      out[i + 1] = (c >> 8) & 0xff;
      out[i + 2] = c & 0xff;
      out[i + 3] = 0xff;
    }
  }
  return out;
}

void main() {
  test('flat grey canvas is blank', () {
    final b = bitmap(200, 150, (x, y) => 0xE5E3DF);
    expect(isBlankSnapshot(b, width: 200, height: 150), isTrue);
  });

  test('flat canvas with a small logo is still blank', () {
    final b = bitmap(
      200,
      150,
      (x, y) => x > 180 && y > 140 ? 0x4285F4 : 0xE5E3DF,
    );
    expect(isBlankSnapshot(b, width: 200, height: 150), isTrue);
  });

  test('styled tiles with roads and a Bone route are not blank', () {
    final b = bitmap(200, 150, (x, y) {
      if ((y - x ~/ 2).abs() < 3) return 0xEDEAE3; // route
      if (x % 40 < 3) return 0x1C1F24; // local road
      if (y % 50 < 2) return 0x2B2F36; // highway
      if (x > 120 && y > 90) return 0x0F1614; // park
      if (x < 40 && y < 40) return 0x050506; // water
      return 0x0F1114; // land
    });
    expect(isBlankSnapshot(b, width: 200, height: 150), isFalse);
  });

  test('anti-aliasing noise on one colour does not count as detail', () {
    final b = bitmap(200, 150, (x, y) => 0xE5E3DF + ((x + y) % 3));
    expect(isBlankSnapshot(b, width: 200, height: 150), isTrue);
  });

  test('empty or truncated buffers are blank', () {
    expect(isBlankSnapshot(Uint8List(0), width: 10, height: 10), isTrue);
    expect(isBlankSnapshot(Uint8List(10), width: 10, height: 10), isTrue);
  });
}
