/// "Move all runs (one file)" and "Import runs": the logic behind the two
/// Settings rows, kept out of the screen.
///
/// Export streams every run, one at a time, through gzip into ONE file
/// (`run-supreme-runs-<date>-<N>runs.runsupreme`), so 500+ runs never sit in
/// memory together. Import streams it back in small batches and also accepts
/// the old per-run `.json` files. gzip is sniffed from the two magic bytes,
/// so a file Drive or Files renamed still opens.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:run_engine/run_engine.dart' as engine;

import '../platform/transfer_gateway.dart';
import 'history_store.dart';

/// Runs written to the store per batch while importing.
const int kImportBatch = 25;

String _two(int n) => n.toString().padLeft(2, '0');

/// `run-supreme-runs-2026-10-10-143runs.runsupreme`
String exportFileName(DateTime now, int runs) {
  final d = now.toLocal();
  return 'run-supreme-runs-${d.year}-${_two(d.month)}-${_two(d.day)}'
      '-${runs}runs.runsupreme';
}

/// What an export did. [runs] == 0 means nothing was shared.
class ExportOutcome {
  const ExportOutcome({required this.runs, this.skipped = 0});
  final int runs;

  /// Run files that could not be read and are NOT in the file.
  final int skipped;

  /// The toast after the share sheet closes. Android cannot say whether the
  /// user actually saved the file, so this says "Shared", not "Saved".
  String get message =>
      warning ??
      'Shared $runs run${runs == 1 ? '' : 's'} in one file. Keep it until '
          "you've imported it.";

  /// A line about runs left out; null when everything went cleanly.
  String? get warning {
    if (skipped == 0) return null;
    final s = '$skipped run${skipped == 1 ? '' : 's'} could not be read';
    return runs == 0
        ? 'Nothing exported · $s.'
        : 'Exported $runs · $s and are NOT in the file. Keep them on this '
              'phone until you have checked.';
  }
}

/// What an import did, for one result line.
class ImportOutcome {
  const ImportOutcome({
    required this.imported,
    required this.alreadyHere,
    required this.unreadableRuns,
    required this.unreadableFiles,
    required this.newerFiles,
    this.saveFailed = 0,
  });
  final int imported;

  /// Already on the phone, or repeated within the files.
  final int alreadyHere;

  /// Single runs inside a readable file that could not be read.
  final int unreadableRuns;

  /// Files that are not Run Supreme files, or are cut short or damaged.
  final int unreadableFiles;

  /// Files (or runs inside a file) made by a newer Run Supreme.
  final int newerFiles;

  /// Runs that could not be written to this phone (storage error).
  final int saveFailed;

  /// "Imported 143 · 0 already here", plus a trailing part for anything
  /// that could not be read.
  String get summary {
    final parts = <String>[
      'Imported $imported',
      '$alreadyHere already here${alreadyHere > 0 ? ' (edits not merged)' : ''}',
      if (unreadableRuns > 0)
        '$unreadableRuns run${unreadableRuns == 1 ? '' : 's'} unreadable',
      if (unreadableFiles > 0) '$unreadableFiles not Run Supreme files',
      if (saveFailed > 0)
        '$saveFailed run${saveFailed == 1 ? '' : 's'} could not be saved',
      if (newerFiles > 0)
        '$newerFiles from a newer Run Supreme, update this one first',
    ];
    return parts.join(' · ');
  }
}

class RunTransfer {
  RunTransfer({
    required this.history,
    required this.transfer,
    DateTime Function()? now,
    Future<Directory> Function()? tempDir,
  }) : _now = now ?? DateTime.now,
       _tempDir =
           tempDir ??
           (() async => Directory.systemTemp.createTemp('runsupreme-'));

  final RunStore history;
  final TransferGateway transfer;
  final DateTime Function() _now;
  final Future<Directory> Function() _tempDir;

  /// Write every run into one gzipped file and offer it through the share
  /// sheet. Null when there is nothing to move. The temp copy holds every
  /// run, so it is deleted when the share finishes or fails.
  Future<ExportOutcome?> exportAll() async {
    final dir = await _tempDir();
    try {
      final tmp = File('${dir.path}/export.partial');
      var count = 0;
      var skipped = 0;
      Stream<engine.RunBundle> counted() async* {
        await for (final b in history.exportBundleStream(
          onSkipped: () => skipped += 1,
        )) {
          count += 1;
          yield b;
        }
      }

      await engine.RunExportCodec.encode(
        counted(),
        exportedAt: _now(),
      ).transform(utf8.encoder).transform(gzip.encoder).pipe(tmp.openWrite());
      if (count == 0) {
        return skipped == 0 ? null : ExportOutcome(runs: 0, skipped: skipped);
      }
      final file = await tmp.rename(
        '${dir.path}/${exportFileName(_now(), count)}',
      );
      // Drive and Files take the subject as the saved file's title, so it is
      // the real file name (date, count and .runsupreme extension).
      await transfer.shareFiles(
        [file.path],
        subject: file.uri.pathSegments.last,
        mimeType: 'application/octet-stream',
      );
      return ExportOutcome(runs: count, skipped: skipped);
    } finally {
      await _tryDelete(dir);
    }
  }

  /// Read the picked files (one-file exports and old per-run files), write
  /// the runs that are new, and count the rest.
  Future<ImportOutcome> importPicked(List<PickedSource> picked) async {
    var imported = 0;
    var already = 0;
    var badRuns = 0;
    var badFiles = 0;
    var newer = 0;
    var saveFailed = 0;
    var batch = <engine.RunBundle>[];

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final pending = batch;
      batch = <engine.RunBundle>[];
      try {
        final r = await history.importBundles(pending);
        imported += r.imported;
        already += r.skippedIds.length;
      } catch (_) {
        // A storage error loses this batch only; the counts so far stand.
        saveFailed += pending.length;
      }
    }

    for (final src in picked) {
      try {
        final lines =
            (await _isGzip(src)
                    ? src.open().transform(gzip.decoder)
                    : src.open())
                .transform(utf8.decoder)
                .transform(const LineSplitter());
        await for (final b in engine.RunExportCodec.readAny(
          lines,
          onSkipped: (e) {
            if (e is engine.RunFileNewerVersionException) {
              newer += 1;
            } else {
              badRuns += 1;
            }
          },
        )) {
          batch.add(b);
          if (batch.length >= kImportBatch) await flush();
        }
      } on engine.RunFileNewerVersionException {
        newer += 1;
      } on engine.RunFileFormatException {
        badFiles += 1;
      } on FormatException {
        // Not UTF-8 or not gzip after all.
        badFiles += 1;
      } on FileSystemException {
        badFiles += 1;
      }
    }
    await flush();
    return ImportOutcome(
      imported: imported,
      alreadyHere: already,
      unreadableRuns: badRuns,
      unreadableFiles: badFiles,
      newerFiles: newer,
      saveFailed: saveFailed,
    );
  }

  /// Peek at the first chunk (a file chunk is KBs, never one byte).
  static Future<bool> _isGzip(PickedSource src) async {
    try {
      final head = await src.open().first;
      return head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b;
    } on StateError {
      return false; // empty file: the reader reports it
    }
  }

  static Future<void> _tryDelete(Directory d) async {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }
}
