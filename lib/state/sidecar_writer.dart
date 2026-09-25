/// The one way to change a `run-<id>.edits.json` sidecar (Phase 3 plan §7 I1,
/// eng-review BLOCK-1).
///
/// Every writer (History freezing verdicts, fix-laps, override, import, and
/// later weather and the heat-compare flip) goes through [update]:
/// - calls for the same run id run one after another (a `Future` chain per
///   id), so a slow `list()` can no longer write a stale copy over a fix-laps
///   edit that landed while it was analysing;
/// - the sidecar is read INSIDE that critical section and handed to a
///   transform, so each caller changes the latest bytes, never a snapshot;
/// - the bytes go to a unique tmp file, are flushed to disk, then renamed
///   over the sidecar, so two writers never share a tmp path and a crash
///   leaves either the old or the new file;
/// - nothing is written when the transform returns the same content.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:run_engine/run_engine.dart' as engine;

class SidecarWriter {
  final Map<String, Future<void>> _tails = {};
  int _seq = 0;

  /// Test seam: runs between the read and the write of every [update].
  @visibleForTesting
  Future<void> Function(String id)? afterRead;

  /// Read → [transform] → write for run [id] at [file], serialised per id.
  /// A missing sidecar reads as an empty one. Returns the sidecar now on
  /// disk (the transform's result, or the unchanged one when it matched).
  ///
  /// A sidecar from a newer app (`RunFileNewerVersionException`) is never
  /// rewritten (W6): the exception reaches the caller and nothing is written.
  /// An unreadable (corrupt) sidecar is replaced, as before.
  ///
  /// With [runFile], nothing is written once that run file is gone (checked
  /// inside the critical section): a `list()` that scanned a run just
  /// deleted must not recreate its sidecar as an orphan, which a later
  /// re-import of the same uuid would adopt (PR #21 review P2).
  Future<engine.RunSidecar> update(
    String id,
    File file,
    engine.RunSidecar Function(engine.RunSidecar current) transform, {
    File? runFile,
  }) => _serial(id, () => _apply(id, file, transform, runFile));

  /// Serialised read → [transform] → atomic write of a whole text file under
  /// [key] (the summary index uses this). The transform gets null for a
  /// missing file; returning null or the same text writes nothing.
  Future<void> replaceText(
    String key,
    File file,
    String? Function(String? current) transform,
  ) => _serial(key, () async {
    final current = await file.exists() ? await file.readAsString() : null;
    final next = transform(current);
    if (next == null || next == current) return;
    await file.parent.create(recursive: true);
    await _writeAtomic(file, next);
  });

  /// Delete run [id]'s run file and sidecar in one critical section, after
  /// any write queued before it; a write queued after it finds the run file
  /// gone and writes nothing.
  Future<void> deleteRun(String id, File runFile, File sidecar) =>
      _serial(id, () async {
        if (await runFile.exists()) await runFile.delete();
        if (await sidecar.exists()) await sidecar.delete();
      });

  /// Run [op] after every earlier operation on [id] has finished (success or
  /// failure); operations on different ids do not wait for each other.
  Future<T> _serial<T>(String id, Future<T> Function() op) {
    final previous = _tails[id] ?? Future<void>.value();
    final result = previous.then((_) => op());
    final Future<void> tail = result.then<void>((_) {}, onError: (_) {});
    _tails[id] = tail;
    // Drop the tail once nothing is queued behind it, so the map stays small.
    unawaited(
      tail.then((_) {
        if (identical(_tails[id], tail)) _tails.remove(id);
      }),
    );
    return result;
  }

  Future<engine.RunSidecar> _apply(
    String id,
    File file,
    engine.RunSidecar Function(engine.RunSidecar current) transform,
    File? runFile,
  ) async {
    if (runFile != null && !await runFile.exists()) {
      return await read(file) ?? engine.RunSidecar(runId: id);
    }
    final current = await read(file) ?? engine.RunSidecar(runId: id);
    await afterRead?.call(id);
    final next = transform(current);
    // A transform that returns its input asks for no write (this also keeps
    // an old-schema sidecar as it is: migration stays lazy, plan §3.8).
    if (identical(next, current)) return current;
    final text = engine.RunSidecarCodec.encode(next);
    // Same content → no write (the common `list()` case once every verdict
    // is frozen).
    if (current.readSchema == engine.RunSidecar.schema &&
        await file.exists() &&
        engine.RunSidecarCodec.encode(current) == text) {
      return current;
    }
    await _writeAtomic(file, text);
    return next;
  }

  /// Unique tmp name, write, flush to disk, rename over [file].
  Future<void> _writeAtomic(File file, String text) async {
    final tmp = File('${file.path}.${pid}_${_seq++}.tmp');
    try {
      final raf = await tmp.open(mode: FileMode.writeOnly);
      try {
        await raf.writeString(text);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await tmp.rename(file.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Decode [file]; null when missing or unreadable. A newer schema rethrows
  /// (W6 read-only rule).
  static Future<engine.RunSidecar?> read(File file) async {
    if (!await file.exists()) return null;
    try {
      return engine.RunSidecarCodec.decode(await file.readAsString());
    } on engine.RunFileNewerVersionException {
      rethrow;
    } catch (e) {
      debugPrint('history: sidecar unreadable ${file.path} ($e)');
      return null;
    }
  }
}
