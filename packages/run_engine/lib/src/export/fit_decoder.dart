import 'dart:convert';
import 'dart:typed_data';

import 'fit_writer.dart';

/// A decoded FIT data message: its global message number and its fields by
/// field number (ints for numbers, String for strings, null when the field
/// held its invalid value).
class FitRecord {
  const FitRecord(this.mesgNum, this.fields);
  final int mesgNum;
  final Map<int, Object?> fields;

  @override
  String toString() => 'FitRecord($mesgNum, $fields)';
}

class FitFormatException implements Exception {
  const FitFormatException(this.message);
  final String message;
  @override
  String toString() => 'FitFormatException: $message';
}

/// A small FIT decoder for round-trip checks of what [FitWriter] writes.
/// Reads normal record headers, little or big endian definitions, numeric and
/// string fields. Compressed timestamp headers and developer fields are
/// refused (we never write them). Not a general FIT reader.
abstract final class FitDecoder {
  static List<FitRecord> decode(Uint8List bytes) {
    if (bytes.length < 16) throw const FitFormatException('too short');
    final headerSize = bytes[0];
    if (headerSize != 12 && headerSize != 14) {
      throw FitFormatException('header size $headerSize');
    }
    if (ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != '.FIT') {
      throw const FitFormatException('missing .FIT signature');
    }
    final view = ByteData.sublistView(bytes);
    final dataSize = view.getUint32(4, Endian.little);
    if (headerSize == 14) {
      final stored = view.getUint16(12, Endian.little);
      if (stored != 0 && stored != FitCrc.of(bytes, 0, 12)) {
        throw const FitFormatException('header CRC mismatch');
      }
    }
    final end = headerSize + dataSize;
    if (bytes.length != end + 2) {
      throw FitFormatException(
        'size mismatch: header says ${end + 2}, file is ${bytes.length}',
      );
    }
    if (view.getUint16(end, Endian.little) != FitCrc.of(bytes, 0, end)) {
      throw const FitFormatException('file CRC mismatch');
    }

    final defs = <int, _Def>{};
    final out = <FitRecord>[];
    var i = headerSize;
    while (i < end) {
      final h = bytes[i++];
      if (h & 0x80 != 0) {
        throw const FitFormatException('compressed timestamp header');
      }
      final local = h & 0x0F;
      if (h & 0x40 != 0) {
        if (h & 0x20 != 0) {
          throw const FitFormatException('developer fields');
        }
        i++; // reserved
        final little = bytes[i++] == 0;
        final endian = little ? Endian.little : Endian.big;
        final mesg = view.getUint16(i, endian);
        i += 2;
        final n = bytes[i++];
        final fields = <_FieldDef>[];
        for (var k = 0; k < n; k++) {
          fields.add(_FieldDef(bytes[i], bytes[i + 1], bytes[i + 2]));
          i += 3;
        }
        defs[local] = _Def(mesg, endian, fields);
      } else {
        final d = defs[local];
        if (d == null) throw FitFormatException('no definition for $local');
        final values = <int, Object?>{};
        for (final f in d.fields) {
          values[f.number] = _read(view, bytes, i, f, d.endian);
          i += f.size;
        }
        out.add(FitRecord(d.mesgNum, values));
      }
    }
    if (i != end) throw const FitFormatException('record overran data size');
    return out;
  }

  static Object? _read(
    ByteData view,
    Uint8List bytes,
    int at,
    _FieldDef f,
    Endian endian,
  ) {
    switch (f.baseCode) {
      case 0x07:
        var n = f.size;
        for (var k = 0; k < f.size; k++) {
          if (bytes[at + k] == 0) {
            n = k;
            break;
          }
        }
        return utf8.decode(bytes.sublist(at, at + n));
      case 0x00:
      case 0x02:
        final v = bytes[at];
        return v == 0xFF ? null : v;
      case 0x84:
        final v = view.getUint16(at, endian);
        return v == 0xFFFF ? null : v;
      case 0x86:
        final v = view.getUint32(at, endian);
        return v == 0xFFFFFFFF ? null : v;
      default:
        throw FitFormatException('base type 0x${f.baseCode.toRadixString(16)}');
    }
  }
}

class _FieldDef {
  const _FieldDef(this.number, this.size, this.baseCode);
  final int number;
  final int size;
  final int baseCode;
}

class _Def {
  const _Def(this.mesgNum, this.endian, this.fields);
  final int mesgNum;
  final Endian endian;
  final List<_FieldDef> fields;
}
