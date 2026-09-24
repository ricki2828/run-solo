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

/// Laps after fix-laps edits plus the keep/drop marks, all in the final
/// (renumbered) index space.
class EditedLaps {
  const EditedLaps({
    required this.laps,
    required this.kept,
    required this.dropped,
  });

  final List<Lap> laps;

  /// Laps the user accepted as their phase regardless of the window.
  final Set<int> kept;

  /// Laps the user excluded from metrics and the verdict.
  final Set<int> dropped;

  /// Kept or dropped: both bypass the window check in the detector.
  Set<int> get accepted => {...kept, ...dropped};
}

/// Applies fix-laps edits (plan §5) in order. Merge keeps the first lap's
/// kind; split produces two laps of the same kind with distance interpolated
/// from the trace at the split time; keep/drop only mark. Indices are
/// renumbered after each edit and earlier marks follow their lap.
List<Lap> applyLapEdits(List<Lap> laps, List<LapEdit> edits, Trace trace) =>
    applyLapEditsWithMarks(laps, edits, trace).laps;

EditedLaps applyLapEditsWithMarks(
  List<Lap> laps,
  List<LapEdit> edits,
  Trace trace,
) {
  var current = List<Lap>.from(laps);
  var kept = <int>{};
  var dropped = <int>{};
  for (final edit in edits) {
    if (edit.index < 0 || edit.index >= current.length) {
      throw LapEditException('lap ${edit.index} does not exist');
    }
    final lap = current[edit.index];
    switch (edit.op) {
      case LapEditOp.keep:
        kept.add(edit.index);
        dropped.remove(edit.index);
      case LapEditOp.drop:
        dropped.add(edit.index);
        kept.remove(edit.index);
      case LapEditOp.merge:
        if (edit.index + 1 >= current.length) {
          throw LapEditException('lap ${edit.index} has no next lap to merge');
        }
        final next = current[edit.index + 1];
        current = [
          ...current.sublist(0, edit.index),
          lap.copyWith(t1Ms: next.t1Ms, d1M: next.d1M),
          ...current.sublist(edit.index + 2),
        ];
        // The merged lap keeps lap `index`'s marks; `index + 1`'s vanish.
        Set<int> shift(Set<int> marks) => {
          for (final m in marks)
            if (m < edit.index + 1) m else if (m > edit.index + 1) m - 1,
        };
        kept = shift(kept);
        dropped = shift(dropped);
      case LapEditOp.split:
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
        // A mark on the split lap stays on its first half.
        Set<int> shift(Set<int> marks) => {
          for (final m in marks)
            if (m <= edit.index) m else m + 1,
        };
        kept = shift(kept);
        dropped = shift(dropped);
    }
  }
  return EditedLaps(
    laps: [
      for (var i = 0; i < current.length; i++) current[i].copyWith(index: i),
    ],
    kept: kept,
    dropped: dropped,
  );
}
