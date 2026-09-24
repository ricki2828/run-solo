import '../model/run_file.dart';
import '../model/sidecar.dart';
import 'trace.dart';

/// Thrown when a lap edit refers to a lap that no longer exists or splits
/// outside the lap. The UI validates before writing the sidecar; the engine
/// refuses rather than guessing.
class LapEditException implements Exception {
  LapEditException(this.message);
  final String message;

  @override
  String toString() => 'LapEditException: $message';
}

/// Applies fix-laps edits (plan §5) in order. Merge keeps the first lap's
/// kind; split produces two laps of the same kind with distance interpolated
/// from the trace at the split time. Indices are renumbered after each edit.
List<Lap> applyLapEdits(List<Lap> laps, List<LapEdit> edits, Trace trace) {
  var current = List<Lap>.from(laps);
  for (final edit in edits) {
    if (edit.index < 0 || edit.index >= current.length) {
      throw LapEditException('lap ${edit.index} does not exist');
    }
    final lap = current[edit.index];
    if (edit.isMerge) {
      if (edit.index + 1 >= current.length) {
        throw LapEditException('lap ${edit.index} has no next lap to merge');
      }
      final next = current[edit.index + 1];
      current = [
        ...current.sublist(0, edit.index),
        lap.copyWith(t1Ms: next.t1Ms, d1M: next.d1M),
        ...current.sublist(edit.index + 2),
      ];
    } else {
      final at = edit.atMs!;
      if (at <= lap.t0Ms || at >= lap.t1Ms) {
        throw LapEditException('split at $at is outside lap ${edit.index}');
      }
      final dAt = trace.distAt(at).clamp(lap.d0M, lap.d1M);
      current = [
        ...current.sublist(0, edit.index),
        lap.copyWith(t1Ms: at, d1M: dAt),
        lap.copyWith(t0Ms: at, d0M: dAt),
        ...current.sublist(edit.index + 1),
      ];
    }
  }
  return [
    for (var i = 0; i < current.length; i++) current[i].copyWith(index: i),
  ];
}
