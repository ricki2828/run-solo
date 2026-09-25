import 'dart:convert';

import '../model/run_file.dart';
import '../model/sidecar.dart';

/// A run file with its sidecar: the unit of JSON export and import (plan
/// §4 W1, §18.7). Export is the inverse of import, not sync: the run's bytes
/// and every user-authored or frozen fact travel together so a dogfood
/// (`app.runsolo.debug`) run lands in the Play build with its verdict intact.
class RunBundle {
  RunBundle({required this.run, this.sidecar}) {
    final s = sidecar;
    if (s != null && s.runId != run.id) {
      throw RunFileFormatException(
        'sidecar run_id ${s.runId} does not match run ${run.id}',
      );
    }
  }

  final RunFile run;

  /// Null when the run had no edits, override, notes or frozen verdict.
  final RunSidecar? sidecar;

  String get id => run.id;
}

/// One exported document: `{"kind": "runsolo-export", "schema": 2, "run":
/// the run file, "sidecar": the sidecar or null}`. The decoder also accepts a
/// bare run file (the decompressed `run-<id>.json.gz`, schema 1 or 2), which
/// is what a dogfood build's files look like when copied off the device.
///
/// Zip and gzip handling belong to the app (the engine has no I/O): pass
/// each member's text here.
class RunBundleCodec {
  const RunBundleCodec._();

  static const String kind = 'runsolo-export';

  static String encode(RunBundle bundle) => jsonEncode({
    'kind': kind,
    'schema': RunFile.schema,
    'run': bundle.run.toJson(),
    'sidecar': bundle.sidecar?.toJson(),
  });

  /// Throws [RunFileFormatException] for malformed input and
  /// [RunFileNewerVersionException] when the run or sidecar was written by a
  /// newer app (the import screen says "made by a newer version").
  static RunBundle decode(String text) {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (e) {
      throw RunFileFormatException('not JSON: ${e.message}');
    }
    if (parsed is! Map<String, Object?>) {
      throw RunFileFormatException('top level must be an object');
    }
    if (parsed['kind'] != kind) {
      // A bare run file: the strict codec decides whether it is one.
      if (parsed.containsKey('samples')) {
        return RunBundle(run: RunFile.fromJson(parsed));
      }
      throw RunFileFormatException(
        'not a Run Solo export (kind "$kind") or run file',
      );
    }
    final schema = parsed['schema'];
    if (schema is! int) {
      throw RunFileFormatException('export.schema must be an int');
    }
    if (schema > RunFile.schema) {
      throw RunFileNewerVersionException(
        'export schema $schema is newer than ${RunFile.schema}',
      );
    }
    final runJson = parsed['run'];
    if (runJson is! Map<String, Object?>) {
      throw RunFileFormatException('export.run must be an object');
    }
    final sidecarJson = parsed['sidecar'];
    if (sidecarJson != null && sidecarJson is! Map<String, Object?>) {
      throw RunFileFormatException('export.sidecar must be an object or null');
    }
    return RunBundle(
      run: RunFile.fromJson(runJson),
      sidecar: sidecarJson == null
          ? null
          : RunSidecar.fromJson(sidecarJson as Map<String, Object?>),
    );
  }
}

/// Result of deduplicating bundles against the runs already on the device.
class BundleImportPlan {
  const BundleImportPlan({
    required this.toImport,
    required this.alreadyOnDeviceIds,
    required this.duplicateIds,
  });

  /// Bundles not yet on the device, in first-seen order, one per uuid.
  final List<RunBundle> toImport;

  /// Ids the device already has. Never overwritten and the incoming
  /// sidecar is never merged: the import screen says "already on this
  /// phone; its edits were not merged".
  final List<String> alreadyOnDeviceIds;

  /// Ids that repeated within the batch (the extra copies).
  final List<String> duplicateIds;

  /// Every skipped id, in input order.
  List<String> get skippedIds => [...alreadyOnDeviceIds, ...duplicateIds];
}

/// Dedupe by uuid. An indexed id is skipped, never overwritten. Within the
/// batch, the copy that carries a sidecar wins over a bare run file (a zip
/// of a dogfood phone holds `run-<id>.json.gz` beside the export bundle;
/// dropping the bundle would lose the frozen verdict and edits, §4 W1);
/// between two bundles with sidecars, or two bare files, the first wins.
BundleImportPlan planBundleImport(
  Iterable<RunBundle> incoming,
  Set<String> existingIds,
) {
  final chosen = <String, RunBundle>{};
  final order = <String>[];
  final existing = <String>[];
  final duplicates = <String>[];
  for (final b in incoming) {
    if (existingIds.contains(b.id)) {
      existing.add(b.id);
      continue;
    }
    final current = chosen[b.id];
    if (current == null) {
      chosen[b.id] = b;
      order.add(b.id);
      continue;
    }
    duplicates.add(b.id);
    if (current.sidecar == null && b.sidecar != null) chosen[b.id] = b;
  }
  return BundleImportPlan(
    toImport: [for (final id in order) chosen[id]!],
    alreadyOnDeviceIds: existing,
    duplicateIds: duplicates,
  );
}
