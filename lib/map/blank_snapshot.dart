/// Detecting a map that authorised nothing (plan §18.3 W9): a rejected key
/// or an unregistered signing SHA-1 still creates the platform view and
/// fires `onMapCreated`, but the canvas stays one flat colour. After the
/// first camera idle the surface takes a snapshot and asks this.
library;

import 'dart:typed_data';

/// True when the RGBA bitmap is (near) a single colour: fewer than
/// [minDistinct] quantised colours over a stride of sampled pixels, ignoring
/// fully transparent ones. Styled tiles (land, roads, water) plus the Bone
/// polyline always exceed that; a blank grey canvas with the Google logo
/// in one corner does not.
bool isBlankSnapshot(
  Uint8List rgba, {
  required int width,
  required int height,
  int minDistinct = 4,
  int stride = 5,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return true;
  }
  final seen = <int>{};
  for (var y = 0; y < height; y += stride) {
    for (var x = 0; x < width; x += stride) {
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 8) continue;
      // Quantise to 4 bits per channel so anti-aliasing and JPEG-ish noise
      // do not count as colours.
      final key =
          (rgba[i] >> 4) << 8 | (rgba[i + 1] >> 4) << 4 | (rgba[i + 2] >> 4);
      if (seen.add(key) && seen.length >= minDistinct) return false;
    }
  }
  return true;
}
