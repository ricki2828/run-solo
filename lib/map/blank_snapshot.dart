/// Detecting a map that authorised nothing (plan §18.3 W9): a rejected key
/// or an unregistered signing SHA-1 still creates the platform view and
/// fires `onMapCreated`, but the tiles never arrive and the canvas stays the
/// SDK's default light grey, with our own overlays (Bone polyline, marker
/// icons) and the Google logo drawn on top. After the first camera idle the
/// surface takes a snapshot and asks this.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../app/perf_diagnostics.dart';

/// The unauthorised canvas is near-neutral: the Maps SDK default `#E5E3DF`
/// (R-G-B spread 6) up to `#F5F5F5` (spread 0). Google's terrain tiles are
/// light too but tinted (beige, green, blue water), so they sit above this.
const int kNeutralSpread = 8;

/// Why a snapshot was or was not judged blank; shown in Settings →
/// Diagnostics so a device report names the cause (#terrain false-failure).
class SnapshotVerdict {
  const SnapshotVerdict({
    required this.blank,
    required this.reason,
    this.dominantHex,
    this.share,
  });
  final bool blank;

  /// `empty`, `uniform-neutral-light`, `ok`, or why the check never ran.
  final String reason;
  final String? dominantHex;
  final double? share;

  String describe({String? mapType}) =>
      '${blank ? 'failed' : 'passed'}: $reason'
      '${dominantHex == null ? '' : ', dominant $dominantHex'}'
      '${share == null ? '' : ' ${(share! * 100).round()}%'}'
      '${mapType == null ? '' : ', $mapType'}';
}

/// True when one colour dominates the RGBA bitmap AND that colour is the
/// SDK's neutral light grey. See [analyseSnapshot].
bool isBlankSnapshot(
  Uint8List rgba, {
  required int width,
  required int height,
  double dominantShare = 0.90,
  int tolerance = 24,
  int stride = 5,
}) => analyseSnapshot(
  rgba,
  width: width,
  height: height,
  dominantShare: dominantShare,
  tolerance: tolerance,
  stride: stride,
).blank;

/// Blank = at least [dominantShare] of samples within [tolerance] per
/// channel of the most common 4-bit-quantised colour, AND that colour
/// (averaged over the matching samples) is light and near-neutral
/// (R-G-B spread <= [kNeutralSpread]). Fully transparent pixels are skipped.
/// Night Session tiles are dark (land `#0F1114`, water `#050506`), so never
/// match; Google terrain is light but tinted, so a field or a lake filling
/// the view is not mistaken for the unauthorised grey. Overlays and the logo
/// are a few percent of the pixels and never tip the share.
SnapshotVerdict analyseSnapshot(
  Uint8List rgba, {
  required int width,
  required int height,
  double dominantShare = 0.90,
  int tolerance = 24,
  int stride = 5,
}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return const SnapshotVerdict(blank: true, reason: 'empty');
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
  if (total == 0) return const SnapshotVerdict(blank: true, reason: 'empty');
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
  // quantisation edge and tile anti-aliasing); their mean is the true colour.
  var near = 0;
  var sr = 0, sg = 0, sb = 0;
  for (var y = 0; y < height; y += stride) {
    for (var x = 0; x < width; x += stride) {
      final i = (y * width + x) * 4;
      if (rgba[i + 3] < 8) continue;
      if ((rgba[i] - r0).abs() <= tolerance &&
          (rgba[i + 1] - g0).abs() <= tolerance &&
          (rgba[i + 2] - b0).abs() <= tolerance) {
        near += 1;
        sr += rgba[i];
        sg += rgba[i + 1];
        sb += rgba[i + 2];
      }
    }
  }
  final share = near / total;
  final r = near == 0 ? r0 : (sr / near).round();
  final g = near == 0 ? g0 : (sg / near).round();
  final b = near == 0 ? b0 : (sb / near).round();
  final hex =
      '#${((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  final luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  final spread =
      [r, g, b].reduce((a, c) => a > c ? a : c) -
      [r, g, b].reduce((a, c) => a < c ? a : c);
  final blank =
      share >= dominantShare && luminance > 0.5 && spread <= kNeutralSpread;
  return SnapshotVerdict(
    blank: blank,
    reason: blank ? 'uniform-neutral-light' : 'ok',
    dominantHex: hex,
    share: share,
  );
}

/// Decodes a snapshot PNG and judges it. A decode failure reads as blank.
Future<SnapshotVerdict> judgeSnapshotPng(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (rgba == null) return const SnapshotVerdict(blank: true, reason: 'empty');
  return analyseSnapshot(
    rgba.buffer.asUint8List(),
    width: frame.image.width,
    height: frame.image.height,
  );
}

/// Debug log plus the Settings → Diagnostics line.
void recordMapVerdict(String surface, SnapshotVerdict v, {String? mapType}) {
  final line = '$surface ${v.describe(mapType: mapType)}';
  debugPrint('map: $line');
  PerfDiagnostics.instance.recordMap(line);
}
