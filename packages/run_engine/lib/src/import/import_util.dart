import 'dart:math' as math;

/// Thrown when a TCX/GPX file cannot be converted.
class ImportFormatException implements Exception {
  ImportFormatException(this.message);
  final String message;

  @override
  String toString() => 'ImportFormatException: $message';
}

/// A stable id for an imported file: importing the same TCX/GPX twice yields
/// the same uuid, so dedupe by id works for converted runs as well as for the
/// app's own exports. FNV-1a over the text, laid out as a version-4-shaped
/// uuid (the version nibble is set so the id passes the same validation).
String deterministicUuid(String text) {
  var h1 = 0xcbf29ce484222325;
  var h2 = 0x84222325cbf29ce4;
  for (final unit in text.codeUnits) {
    h1 = ((h1 ^ unit) * 0x100000001b3) & 0xffffffffffffffff;
    h2 = ((h2 ^ (unit + 0x9e37)) * 0x100000001b3) & 0xffffffffffffffff;
  }
  String hex64(int h) =>
      (h >>> 32).toRadixString(16).padLeft(8, '0') +
      (h & 0xffffffff).toRadixString(16).padLeft(8, '0');
  final hex = hex64(h1) + hex64(h2);
  final b = hex.substring(0, 32).split('');
  b[12] = '4';
  b[16] = '8';
  final s = b.join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-${s.substring(20, 32)}';
}

double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
