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

/// The UTC offset in minutes an imported timestamp states itself ("+03:00"
/// is 180); null for "Z", no offset, or text that is not a timestamp.
int? importTimeOffsetMin(String? text) {
  final m = RegExp(r'([+-])(\d\d):?(\d\d)$').firstMatch(text?.trim() ?? '');
  if (m == null) return null;
  final minutes = int.parse(m[2]!) * 60 + int.parse(m[3]!);
  return m[1] == '-' ? -minutes : minutes;
}

/// The run file `tz` for an import: [requested] unless it is the bare "UTC"
/// placeholder and the timestamps carry an offset, then that offset as
/// "+HH:MM" (the file has no IANA zone to give). [RunZone] reads it back.
String importTz(String requested, Iterable<String?> timeTexts) {
  if (requested != 'UTC') return requested;
  for (final t in timeTexts) {
    final m = importTimeOffsetMin(t);
    if (m == null) continue;
    final a = m.abs();
    final hh = (a ~/ 60).toString().padLeft(2, '0');
    final mm = (a % 60).toString().padLeft(2, '0');
    return '${m < 0 ? '-' : '+'}$hh:$mm';
  }
  return requested;
}

/// Parses a TCX/GPX timestamp. A value without `Z` or an offset is taken as
/// UTC (never the phone's local zone, which would shift with travel).
DateTime? parseImportTime(String? text) {
  if (text == null) return null;
  final t = text.trim();
  final parsed = DateTime.tryParse(t);
  if (parsed == null) return null;
  final hasOffset = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(t);
  if (hasOffset) return parsed.toUtc();
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
  );
}
