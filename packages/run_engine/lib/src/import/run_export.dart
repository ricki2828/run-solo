import 'dart:async';
import 'dart:convert';

import '../model/run_file.dart';
import 'run_bundle.dart';

/// "Move all runs (one file)": every run with its sidecar in ONE document.
///
/// ```
/// {"format":"runsupreme-export","version":1,"exported_at":"…","runs":[
/// <RunBundle JSON on one line>,
/// <RunBundle JSON on one line>
/// ]}
/// ```
///
/// Valid JSON throughout, but laid out one bundle per line so both sides
/// stream it: the writer never holds more than one run, and the reader
/// decodes one line at a time (a 500-run file is never one giant string).
/// The app gzips the stream; the engine has no I/O and sees plain text.
///
/// [readAny] also accepts the old per-run files ([RunBundleCodec] output or a
/// bare run file), so one import path serves both.
class RunExportCodec {
  const RunExportCodec._();

  static const String format = 'runsupreme-export';
  static const int version = 1;

  static const String _headStart = '{"format":"$format"';
  static const String _headEnd = '"runs":[';
  static const String _tail = ']}';

  /// The document as text chunks, one bundle per chunk.
  static Stream<String> encode(
    Stream<RunBundle> bundles, {
    required DateTime exportedAt,
  }) async* {
    yield '$_headStart,"version":$version,'
        '"exported_at":${jsonEncode(exportedAt.toUtc().toIso8601String())},'
        '$_headEnd\n';
    var first = true;
    await for (final b in bundles) {
      yield '${first ? '' : ',\n'}${RunBundleCodec.encode(b)}';
      first = false;
    }
    yield '\n$_tail\n';
  }

  /// Decode a whole export (or an old single-run document) held in memory.
  /// Convenience for tests and small inputs; the app streams via [readAny].
  /// Unreadable runs inside an export are reported to [onSkipped] and left
  /// out; a damaged envelope throws [RunFileFormatException].
  static List<RunBundle> decode(
    String text, {
    void Function(Object error)? onSkipped,
  }) {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (e) {
      throw RunFileFormatException('not JSON: ${e.message}');
    }
    if (parsed is Map<String, Object?> && parsed['format'] == format) {
      _checkVersion(parsed['version']);
      final runs = parsed['runs'];
      if (runs is! List) {
        throw RunFileFormatException('export.runs must be a list');
      }
      final out = <RunBundle>[];
      for (final r in runs) {
        try {
          if (r is! Map<String, Object?>) {
            throw RunFileFormatException('export run must be an object');
          }
          out.add(RunBundleCodec.decode(jsonEncode(r)));
        } on RunFileFormatException catch (e) {
          if (onSkipped == null) rethrow;
          onSkipped(e);
        }
      }
      return out;
    }
    return [RunBundleCodec.decode(text)];
  }

  /// Stream bundles out of any Run Supreme document: the one-file export
  /// (decoded a line at a time) or an old per-run file.
  ///
  /// A bundle that cannot be read (damaged, or made by a newer app) is
  /// reported to [onSkipped] and the rest still come through. An envelope
  /// from a newer app, or a file cut short before its closing `]}`, ends the
  /// stream with a [RunFileNewerVersionException] / [RunFileFormatException]
  /// after the intact bundles were already yielded.
  static Stream<RunBundle> readAny(
    Stream<String> lines, {
    void Function(Object error)? onSkipped,
  }) async* {
    final it = StreamIterator<String>(lines);
    try {
      String? head;
      while (await it.moveNext()) {
        if (it.current.trim().isEmpty) continue;
        head = it.current.trim();
        break;
      }
      if (head == null) throw RunFileFormatException('file is empty');

      if (head.startsWith(_headStart) && head.endsWith(_headEnd)) {
        Object? env;
        try {
          env = jsonDecode('$head$_tail');
        } on FormatException catch (e) {
          throw RunFileFormatException('bad export header: ${e.message}');
        }
        _checkVersion((env as Map<String, Object?>)['version']);
        var closed = false;
        while (await it.moveNext()) {
          var line = it.current.trim();
          if (line.isEmpty) continue;
          if (line == _tail) {
            closed = true;
            break;
          }
          if (line.endsWith(',')) line = line.substring(0, line.length - 1);
          try {
            yield RunBundleCodec.decode(line);
          } on RunFileFormatException catch (e) {
            if (onSkipped == null) rethrow;
            onSkipped(e);
          }
        }
        if (!closed) {
          throw RunFileFormatException('export is cut short (no closing)');
        }
        return;
      }

      // Anything else: gather it and let the whole-document decoders judge.
      final buf = StringBuffer(head);
      while (await it.moveNext()) {
        buf
          ..write('\n')
          ..write(it.current);
      }
      for (final b in decode(buf.toString(), onSkipped: onSkipped)) {
        yield b;
      }
    } finally {
      unawaited(it.cancel());
    }
  }

  static void _checkVersion(Object? v) {
    if (v is! int) {
      throw RunFileFormatException('export.version must be an int');
    }
    if (v > version) {
      throw RunFileNewerVersionException(
        'export version $v is newer than $version',
      );
    }
  }
}
