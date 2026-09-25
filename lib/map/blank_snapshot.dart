/// Detecting a map that authorised nothing (plan §18.3 W9): a rejected key
/// or an unregistered signing SHA-1 still creates the platform view and
/// fires `onMapCreated`, but the tiles never arrive and the canvas stays the
/// SDK's default light grey, with our own overlays (Bone polyline, marker
/// icons) and the Google logo drawn on top. After the first camera idle the
/// surface takes a snapshot and asks this.
library;

import 'dart:typed_data';

/// True when one colour dominates the RGBA bitmap AND that colour is light.
/// Sampled on a stride; fully transparent pixels are skipped. "Dominant" =
/// at least [dominantShare] of samples within [tolerance] per channel of the
/// most common 4-bit-quantised colour. Our Night Session tiles are dark
/// (land `#0F1114`, water `#050506`, roads ≤ `#2B2F36`), so a light dominant
/// colour can only be the SDK's unauthorised grey. Overlays and the logo are
/// a few percent of the pixels and never tip the share.
bool isBlankSnapshot(
  Uint8List rgba, {
  required int width,
  required int height,
  double dominantShare = 0.85,
  int tolerance = 24,
  int stride = 5,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return true;
  }
  // Pass 1: most common quantised colour.
  final counts = <int, int>{};
  var total = 0;
  for (var y = 0; y < height; y += stride) {
    for (var x = 0; x < width; x += stride) {
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 8) continue;
      total += 1;
      final key =
          (rgba[i] >> 4) << 8 | (rgba[i + 1] >> 4) << 4 | (rgba[i + 2] >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  if (total == 0) return true;
  var bestKey = 0;
  var bestCount = -1;
  counts.forEach((k, c) {
    if (c > bestCount) {
      bestCount = c;
      bestKey = k;
    }
  });
  final r0 = ((bestKey >> 8) & 0xf) * 17;
  final g0 = ((bestKey >> 4) & 0xf) * 17;
  final b0 = (bestKey & 0xf) * 17;
  // Pass 2: share of samples near that colour (tolerance absorbs the
  // quantisation edge and tile anti-aliasing).
  var near = 0;
  for (var y = 0; y < height; y += stride) {
    for (var x = 0; x < width; x += stride) {
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 8) continue;
      if ((rgba[i] - r0).abs() <= tolerance &&
          (rgba[i + 1] - g0).abs() <= tolerance &&
          (rgba[i + 2] - b0).abs() <= tolerance) {
        near += 1;
      }
    }
  }
  final share = near / total;
  final luminance = (0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0) / 255;
  return share >= dominantShare && luminance > 0.5;
}
