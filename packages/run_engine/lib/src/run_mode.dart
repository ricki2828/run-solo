import 'model/run_file.dart' show RunFileFormatException;

/// The one mode enum shared by the file format, the index and the UI (plan
/// §2 rule 3, §18.2; Phase 3 §3.8). Order and names mirror Pigeon
/// `RecordMode` and core-jvm `RunMode`; the Android shell maps by `name`.
///
/// - [intervals]: a structured session (`RunFile.session`): step timer,
///   cues, auto-laps, staged verdict per comparison key. Schema ≤ 2 called
///   it `fourByFour`; an `intervals` run with no session is a by-feel 4x4.
/// - [laps]: count-up timer with a LAP button, lap table, no verdict word.
///   **This is what schema-1 files called `free`** (§18.7 B1). Fartlek is a
///   Laps run with the fartlek session.
/// - [free]: no lap input at all; summary only.
/// - [cooper]: the 12-minute test (§18.4).
enum RunMode {
  intervals,
  laps,
  free,
  cooper;

  /// Decodes a stored mode name written under [schema]:
  /// - 1: `free` → [laps] (§18.7 B1), `fourByFour` → [intervals];
  /// - 2: `fourByFour` → [intervals], `laps|free|cooper` as named;
  /// - 3: the names above; `fourByFour` is retired and refused.
  /// Throws [RunFileFormatException] for a name that schema never wrote.
  static RunMode decode(String name, {required int schema}) {
    if (schema <= 1) {
      // No v1 writer emitted anything else; a stray `laps`/`cooper` in a
      // schema-1 file is corruption, not a newer writer.
      return switch (name) {
        'free' => RunMode.laps,
        'fourByFour' => RunMode.intervals,
        _ => throw RunFileFormatException(
          'schema-1 mode must be fourByFour|free, got "$name"',
        ),
      };
    }
    if (schema == 2) {
      return switch (name) {
        'fourByFour' => RunMode.intervals,
        'laps' => RunMode.laps,
        'free' => RunMode.free,
        'cooper' => RunMode.cooper,
        _ => throw RunFileFormatException(
          'schema-2 mode must be fourByFour|laps|free|cooper, got "$name"',
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
    RunMode.intervals || RunMode.laps => true,
    RunMode.free || RunMode.cooper => false,
  };
}
