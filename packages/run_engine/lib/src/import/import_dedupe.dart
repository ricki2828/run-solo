import '../model/run_file.dart';

/// Result of deduplicating an import batch against the runs already on the
/// device (plan §4 W1: import is the inverse of export, not sync).
class ImportPlan {
  const ImportPlan({required this.toImport, required this.skippedIds});

  /// Runs not yet on the device, in input order, one per uuid.
  final List<RunFile> toImport;

  /// Ids skipped because they already exist or repeat within the batch.
  final List<String> skippedIds;
}

/// Dedupe by uuid. The first occurrence in the batch wins; anything whose id
/// is already indexed is skipped, never overwritten.
ImportPlan planImport(Iterable<RunFile> incoming, Set<String> existingIds) {
  final seen = <String>{...existingIds};
  final toImport = <RunFile>[];
  final skipped = <String>[];
  for (final run in incoming) {
    if (seen.add(run.id)) {
      toImport.add(run);
    } else {
      skipped.add(run.id);
    }
  }
  return ImportPlan(toImport: toImport, skippedIds: skipped);
}
