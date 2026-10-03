import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/app/perf_diagnostics.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/map/route_builder.dart';
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

  // Terrain is Google's own light, tinted palette (the dark style is ignored).
  int terrainPixel(int x, int y, int w, int h, int land) {
    if ((y - (x * h ~/ w)).abs() < 3) return 0x1B1D20; // casing under route
    if (y > h - 24 && x < 80) return 0x4285F4; // logo
    return land;
  }

  test('SDK neutral light range is blank (#E5E3DF to #F5F5F5)', () {
    for (final c in [0xE5E3DF, 0xEEEEEE, 0xF5F5F5]) {
      expect(
        isBlankSnapshot(bitmap(w, h, (x, y) => c), width: w, height: h),
        isTrue,
        reason: c.toRadixString(16),
      );
    }
  });

  test('light beige terrain filling the view is not blank', () {
    final b = bitmap(w, h, (x, y) => terrainPixel(x, y, w, h, 0xE8E0C8));
    expect(isBlankSnapshot(b, width: w, height: h), isFalse);
  });

  test('light green terrain filling the view is not blank', () {
    final b = bitmap(w, h, (x, y) => terrainPixel(x, y, w, h, 0xC8E6C9));
    expect(isBlankSnapshot(b, width: w, height: h), isFalse);
  });

  test('mostly water (dark style) is not blank', () {
    final b = bitmap(w, h, (x, y) => x < w * 0.95 ? 0x050506 : 0x0F1114);
    expect(isBlankSnapshot(b, width: w, height: h), isFalse);
  });

  test('light blue terrain water is not blank', () {
    final b = bitmap(w, h, (x, y) => 0xAADAFF);
    expect(isBlankSnapshot(b, width: w, height: h), isFalse);
  });

  test('verdict reports dominant colour, share and reason', () {
    final v = analyseSnapshot(
      bitmap(w, h, (x, y) => 0xE8E0C8),
      width: w,
      height: h,
    );
    expect(v.blank, isFalse);
    expect(v.dominantHex, '#E8E0C8');
    expect(v.share, closeTo(1.0, 0.001));
    expect(v.describe(mapType: 'terrain'), contains('#E8E0C8'));
  });

  Future<Uint8List> png(int rgb) async {
    const s = 64;
    final px = bitmap(s, s, (x, y) => rgb);
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, s, s, ui.PixelFormat.rgba8888, c.complete);
    final bytes = await (await c.future).toByteData(
      format: ui.ImageByteFormat.png,
    );
    return bytes!.buffer.asUint8List();
  }

  testWidgets('terrain surface: a light non-grey snapshot is not failed', (
    tester,
  ) async {
    // The platform view cannot run in tests; this drives the same decode and
    // verdict both surfaces use, then renders what each verdict shows.
    final beige = await tester.runAsync(
      () async => judgeSnapshotPng(await png(0xE8E0C8)),
    );
    final grey = await tester.runAsync(
      () async => judgeSnapshotPng(await png(0xE5E3DF)),
    );
    expect(beige!.blank, isFalse);
    expect(grey!.blank, isTrue);
    const route = RouteGeometry(points: [], markers: [], bounds: null);
    Widget shown(SnapshotVerdict v) => v.blank
        ? const MapFailedCard(route: route)
        : const SizedBox(key: ValueKey('terrain-ok'));
    await tester.pumpWidget(MaterialApp(home: shown(beige)));
    expect(find.byType(MapFailedCard), findsNothing);
    recordMapVerdict('test', beige, mapType: 'terrain');
    expect(PerfDiagnostics.instance.lastMapVerdict, contains('#E8E0C8'));
  });
}
