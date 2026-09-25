import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/blank_snapshot.dart';

/// W9: a map whose key or SHA-1 was refused stays the SDK's light grey with
/// our overlays and the Google logo on top; authorised Night Session tiles
/// are dark and varied.
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

const grey = 0xE5E3DF; // SDK default canvas
const bone = 0xEDEAE3;
const base = 0x0A0B0D;

/// Rejected key as it really looks: grey canvas, a 4 px Bone route across
/// the card, start/finish dots, four 22 px lap chips, the Google logo.
int rejectedKeyPixel(int x, int y, int w, int h) {
  // Route: diagonal band 4 px wide.
  if ((y - (x * h ~/ w)).abs() < 3) return bone;
  // Lap chips: 22 px circles with dark fill.
  for (final cx in [w ~/ 5, 2 * w ~/ 5, 3 * w ~/ 5, 4 * w ~/ 5]) {
    final cy = cx * h ~/ w;
    final dx = x - cx, dy = y - cy;
    if (dx * dx + dy * dy < 11 * 11) return base;
  }
  // Start / finish dots.
  if ((x - 12) * (x - 12) + (y - 12) * (y - 12) < 25) return bone;
  // Google logo bottom-left: blue, red, yellow, green patches.
  if (y > h - 24 && x < 80) {
    return [0x4285F4, 0xEA4335, 0xFBBC05, 0x34A853][(x ~/ 20) % 4];
  }
  return grey;
}

/// Authorised tiles: land, water, roads, a park, the Bone route.
int styledPixel(int x, int y, int w, int h) {
  if ((y - (x * h ~/ w)).abs() < 3) return bone;
  if (x % 40 < 3) return 0x1C1F24;
  if (y % 50 < 2) return 0x2B2F36;
  if (x > w * 0.6 && y > h * 0.6) return 0x0F1614;
  if (x < w * 0.2 && y < h * 0.25) return 0x050506;
  return 0x0F1114;
}

void main() {
  const w = 1080, h = 810;

  test('flat grey canvas is blank', () {
    expect(
      isBlankSnapshot(bitmap(w, h, (x, y) => grey), width: w, height: h),
      isTrue,
    );
  });

  test('rejected key: grey + route + chips + dots + logo is blank', () {
    final b = bitmap(w, h, (x, y) => rejectedKeyPixel(x, y, w, h));
    expect(isBlankSnapshot(b, width: w, height: h), isTrue);
  });

  test('authorised Night Session tiles with the route are not blank', () {
    final b = bitmap(w, h, (x, y) => styledPixel(x, y, w, h));
    expect(isBlankSnapshot(b, width: w, height: h), isFalse);
  });

  test(
    'a dark uniform frame (tiles still loading over our style) is not "blank"',
    () {
      // Dark dominant colour: not the unauthorised grey, so no failed state;
      // the watchdog / a later check decides.
      final b = bitmap(w, h, (x, y) => 0x0F1114);
      expect(isBlankSnapshot(b, width: w, height: h), isFalse);
    },
  );

  test('anti-aliasing noise on grey still reads as one colour', () {
    final b = bitmap(w, h, (x, y) => grey + ((x + y) % 5) * 0x010101);
    expect(isBlankSnapshot(b, width: w, height: h), isTrue);
  });

  test('empty or truncated buffers are blank', () {
    expect(isBlankSnapshot(Uint8List(0), width: 10, height: 10), isTrue);
    expect(isBlankSnapshot(Uint8List(10), width: 10, height: 10), isTrue);
  });
}
