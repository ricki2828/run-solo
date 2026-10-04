import 'dart:convert';
import 'dart:typed_data';

/// Minimal FIT (Flexible and Interoperable Data Transfer) writer: just the
/// framing the workout encoder needs. Little-endian, normal record headers
/// only (no compressed timestamps), one definition per message layout.
///
/// Framing per the FIT SDK (protocol 2.0): a 14 byte header (size, protocol,
/// profile version, data size, ".FIT", CRC of the first 12 bytes), the
/// records, then a CRC-16 over header and records.

/// FIT base types (SDK Profile, "Base Types"), the byte a field definition
/// carries and its invalid value.
enum FitBase {
  enum8(0x00, 1, 0xFF),
  uint16(0x84, 2, 0xFFFF),
  uint32(0x86, 4, 0xFFFFFFFF),
  string(0x07, 1, 0);

  const FitBase(this.code, this.size, this.invalid);
  final int code;
  final int size;
  final int invalid;
}

/// One field of a message layout. [size] is the byte size on the wire; only a
/// [FitBase.string] may exceed [FitBase.size] (a fixed, zero padded buffer).
class FitFieldDef {
  const FitFieldDef(this.number, this.base, [this.size = 0]);
  final int number;
  final FitBase base;
  final int size;

  /// Bytes on the wire: [size], or the base type's own size when 0.
  int get bytes => size == 0 ? base.size : size;
}

/// CRC-16 as the FIT SDK defines it (CRC-16/ARC, nibble table).
abstract final class FitCrc {
  static const List<int> _table = [
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, //
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
  ];

  static int update(int crc, int byte) {
    var tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ _table[byte & 0xF];
    tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    return crc ^ tmp ^ _table[(byte >> 4) & 0xF];
  }

  static int of(List<int> bytes, [int start = 0, int? end]) {
    var crc = 0;
    for (var i = start; i < (end ?? bytes.length); i++) {
      crc = update(crc, bytes[i]);
    }
    return crc;
  }
}

class FitWriter {
  FitWriter();

  /// FIT SDK profile version the files claim (21.x series; 2140 = 21.40).
  static const int profileVersion = 2140;

  /// Protocol version 2.0 (high nibble 2, low nibble 0).
  static const int protocolVersion = 0x20;

  /// Seconds between the Unix epoch and the FIT epoch (1989-12-31 UTC).
  static const int fitEpochOffsetS = 631065600;

  static int fitTimestamp(DateTime t) =>
      t.toUtc().millisecondsSinceEpoch ~/ 1000 - fitEpochOffsetS;

  final BytesBuilder _data = BytesBuilder();
  final Map<int, _Layout> _defined = {};
  final Map<int, int> _localOf = {};

  /// Write a data message for global message number [mesgNum]. [values] is
  /// parallel to [fields]: an int for numeric bases (null = invalid), a
  /// String for [FitBase.string]. The definition record is written the first
  /// time a layout is seen; a message number keeps one layout per file.
  void message(int mesgNum, List<FitFieldDef> fields, List<Object?> values) {
    assert(fields.length == values.length);
    var local = _localOf[mesgNum];
    if (local == null) {
      local = _localOf.length;
      if (local > 15) throw StateError('more than 16 message types');
      _localOf[mesgNum] = local;
      _defined[mesgNum] = _Layout(fields);
      _data.addByte(0x40 | local);
      _data.addByte(0); // reserved
      _data.addByte(0); // little-endian
      _u16(_data, mesgNum);
      _data.addByte(fields.length);
      for (final f in fields) {
        _data
          ..addByte(f.number)
          ..addByte(f.bytes)
          ..addByte(f.base.code);
      }
    } else if (!_defined[mesgNum]!.matches(fields)) {
      throw StateError('message $mesgNum changed layout');
    }
    _data.addByte(local);
    for (var i = 0; i < fields.length; i++) {
      final f = fields[i];
      final v = values[i];
      switch (f.base) {
        case FitBase.string:
          _data.add(_fixedString(v as String? ?? '', f.bytes));
        case FitBase.enum8:
          _data.addByte((v as int?) ?? f.base.invalid);
        case FitBase.uint16:
          _u16(_data, (v as int?) ?? f.base.invalid);
        case FitBase.uint32:
          _u32(_data, (v as int?) ?? f.base.invalid);
      }
    }
  }

  /// The finished file: header, records, trailing CRC.
  Uint8List finish() {
    final body = _data.toBytes();
    final header = BytesBuilder()
      ..addByte(14)
      ..addByte(protocolVersion);
    _u16(header, profileVersion);
    _u32(header, body.length);
    header.add(ascii.encode('.FIT'));
    final h = header.toBytes();
    final out = BytesBuilder()..add(h);
    _u16(out, FitCrc.of(h));
    out.add(body);
    final all = out.toBytes();
    final withCrc = BytesBuilder()..add(all);
    _u16(withCrc, FitCrc.of(all));
    return withCrc.toBytes();
  }

  /// UTF-8, cut at a character boundary to leave room for the zero
  /// terminator, then zero padded to [size].
  static List<int> _fixedString(String s, int size) {
    final out = <int>[];
    for (final rune in s.runes) {
      final enc = utf8.encode(String.fromCharCode(rune));
      if (out.length + enc.length > size - 1) break;
      out.addAll(enc);
    }
    while (out.length < size) {
      out.add(0);
    }
    return out;
  }

  static void _u16(BytesBuilder b, int v) {
    b
      ..addByte(v & 0xFF)
      ..addByte((v >> 8) & 0xFF);
  }

  static void _u32(BytesBuilder b, int v) {
    b
      ..addByte(v & 0xFF)
      ..addByte((v >> 8) & 0xFF)
      ..addByte((v >> 16) & 0xFF)
      ..addByte((v >> 24) & 0xFF);
  }
}

class _Layout {
  _Layout(this.fields);
  final List<FitFieldDef> fields;
  bool matches(List<FitFieldDef> other) {
    if (other.length != fields.length) return false;
    for (var i = 0; i < fields.length; i++) {
      if (other[i].number != fields[i].number ||
          other[i].base != fields[i].base ||
          other[i].bytes != fields[i].bytes) {
        return false;
      }
    }
    return true;
  }
}
