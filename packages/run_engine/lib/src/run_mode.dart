import 'model/run_file.dart' show RunFileFormatException;

/// The one mode enum shared by the file format, the index and the UI (plan
/// §2 rule 3, §18.2). Order and names mirror Pigeon `RecordMode` and core-jvm
/// `RunMode`; the Android shell maps by `name`.
///
/// - [fourByFour]: preset timer, cues, auto-laps, staged verdict.
/// - [laps]: count-up timer with a LAP button, lap table, no verdict word.
///   **This is what schema-1 files called `free`** (§18.7 B1).
/// - [free]: no lap input at all; summary only.
/// - [cooper]: reserved for the Phase 3 12-minute test (§18.4). Phase 2 reads
///   it as a summary-only run and never writes it.
enum RunMode {
  fourByFour,
  laps,
  free,
  cooper;

  /// Decodes a stored mode name. Schema-1 writers (run file, sidecar
  /// override, journal) used `free` for today's lap-capable mode, so under
  /// [schema] 1 that name maps to [laps], always (§18.7: simpler than "when
  /// laps > 1"). Throws [RunFileFormatException] for an unknown name.
  static RunMode decode(String name, {required int schema}) {
    if (schema <= 1) {
      // No v1 writer emitted anything else; a stray `laps`/`cooper` in a
      // schema-1 file is corruption, not a newer writer.
      return switch (name) {
        'free' => RunMode.laps,
        'fourByFour' => RunMode.fourByFour,
        _ => throw RunFileFormatException(
          'schema-1 mode must be fourByFour|free, got "$name"',
        ),
      };
    }
    final mode = RunMode.values.cast<RunMode?>().firstWhere(
      (m) => m!.name == name,
      orElse: () => null,
    );
    if (mode == null) {
      throw RunFileFormatException(
        'mode must be one of ${RunMode.values.map((m) => m.name).join('|')}, got "$name"',
      );
    }
    return mode;
  }

  /// Whether the recorder accepts LAP input in this mode (§18.2).
  bool get lapCapable => switch (this) {
    RunMode.fourByFour || RunMode.laps => true,
    RunMode.free || RunMode.cooper => false,
  };
}
