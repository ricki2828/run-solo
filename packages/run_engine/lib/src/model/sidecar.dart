import 'dart:convert';

import '../run_mode.dart';
import 'run_file.dart';
import 'verdict.dart';

/// A fix-laps edit (plan §5): merge lap `index` with the one after it, or
/// split lap `index` at `atMs` (ms since run start). Applied in order to the
/// recorded laps before detection.
class LapEdit {
  const LapEdit.merge(this.index) : atMs = null;
  const LapEdit.split(this.index, int this.atMs);

  final int index;
  final int? atMs;

  bool get isMerge => atMs == null;

  Map<String, Object?> toJson() => {
    'op': isMerge ? 'merge' : 'split',
    'index': index,
    if (!isMerge) 'at': atMs,
  };

  factory LapEdit.fromJson(Map<String, Object?> json) {
    final op = readStringField(json, 'op');
    final index = readIntField(json, 'index');
    if (index < 0) throw RunFileFormatException('lap_edit.index < 0');
    switch (op) {
      case 'merge':
        return LapEdit.merge(index);
      case 'split':
        return LapEdit.split(index, readIntField(json, 'at'));
      default:
        throw RunFileFormatException('lap_edit.op must be merge|split');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LapEdit && other.index == index && other.atMs == atMs;

  @override
  int get hashCode => Object.hash(index, atMs);
}

/// `run-<uuid>.edits.json` (plan §4): every user-authored or frozen fact
/// about a run, so a rebuild reproduces history instead of recomputing it.
class RunSidecar {
  const RunSidecar({
    required this.runId,
    this.lapEdits = const [],
    this.runTypeOverride,
    this.notes,
    this.frozenVerdict,
    this.verdictHistory = const [],
  });

  static const int schema = 1;

  final String runId;
  final List<LapEdit> lapEdits;

  /// v1: only `fourByFour` <-> `free` flips.
  final RunMode? runTypeOverride;
  final String? notes;
  final Verdict? frozenVerdict;

  /// Earlier verdicts, oldest first: every verdict that was unfrozen by a
  /// fix-laps edit or override, or replaced by an engine bump (plan §5
  /// "previous text kept in verdict history"), so a rebuild from sidecars
  /// keeps the history the DB `verdict` table shows.
  final List<Verdict> verdictHistory;

  bool get isEmpty =>
      lapEdits.isEmpty &&
      runTypeOverride == null &&
      notes == null &&
      frozenVerdict == null &&
      verdictHistory.isEmpty;

  RunSidecar copyWith({
    List<LapEdit>? lapEdits,
    Object? runTypeOverride = _unset,
    Object? notes = _unset,
    Object? frozenVerdict = _unset,
    List<Verdict>? verdictHistory,
  }) => RunSidecar(
    runId: runId,
    verdictHistory: verdictHistory ?? this.verdictHistory,
    lapEdits: lapEdits ?? this.lapEdits,
    runTypeOverride: identical(runTypeOverride, _unset)
        ? this.runTypeOverride
        : runTypeOverride as RunMode?,
    notes: identical(notes, _unset) ? this.notes : notes as String?,
    frozenVerdict: identical(frozenVerdict, _unset)
        ? this.frozenVerdict
        : frozenVerdict as Verdict?,
  );

  /// Fix-laps: append an edit and drop the frozen verdict so the next
  /// analysis recomputes (plan §5: recompute only on fix-laps, override, or
  /// an engine bump). The old verdict text is the store's history to keep.
  RunSidecar withLapEdit(LapEdit edit) =>
      _unfrozen().copyWith(lapEdits: [...lapEdits, edit]);

  /// Override the run type; also unfreezes the verdict.
  RunSidecar withOverride(RunMode? mode) =>
      _unfrozen().copyWith(runTypeOverride: mode);

  /// Freeze [verdict]; a different verdict already frozen moves to history
  /// (an engine bump recomputed it).
  RunSidecar withFrozenVerdict(Verdict verdict) {
    final current = frozenVerdict;
    final replaced =
        current != null && current.engineVersion != verdict.engineVersion;
    return copyWith(
      frozenVerdict: verdict,
      verdictHistory: replaced ? [...verdictHistory, current] : verdictHistory,
    );
  }

  RunSidecar _unfrozen() => frozenVerdict == null
      ? this
      : copyWith(
          frozenVerdict: null,
          verdictHistory: [...verdictHistory, frozenVerdict!],
        );

  Map<String, Object?> toJson() => {
    'schema': schema,
    'run_id': runId,
    'lap_edits': lapEdits.map((e) => e.toJson()).toList(),
    'run_type_override': runTypeOverride?.name,
    'notes': notes,
    'frozen_verdict': frozenVerdict?.toJson(),
    'verdict_history': verdictHistory.map((v) => v.toJson()).toList(),
  };

  factory RunSidecar.fromJson(Map<String, Object?> json) {
    if (json['schema'] != schema) {
      throw RunFileFormatException('sidecar schema must be $schema');
    }
    final runId = readStringField(json, 'run_id');
    if (!RunFile.idPattern.hasMatch(runId)) {
      throw RunFileFormatException('sidecar run_id must be a uuid');
    }
    final overrideName = json['run_type_override'];
    RunMode? override;
    if (overrideName != null) {
      override = RunMode.values.cast<RunMode?>().firstWhere(
        (m) => m!.name == overrideName,
        orElse: () => null,
      );
      if (override == null) {
        throw RunFileFormatException('run_type_override must be a RunMode');
      }
    }
    final notes = json['notes'];
    if (notes != null && notes is! String) {
      throw RunFileFormatException('notes must be a string or null');
    }
    final frozen = json['frozen_verdict'];
    final history = json['verdict_history'] ?? const [];
    if (history is! List) {
      throw RunFileFormatException('verdict_history must be a list');
    }
    return RunSidecar(
      runId: runId,
      lapEdits: readListField(
        json,
        'lap_edits',
      ).map((e) => LapEdit.fromJson(asMapField(e, 'lap_edit'))).toList(),
      runTypeOverride: override,
      notes: notes as String?,
      frozenVerdict: frozen == null
          ? null
          : Verdict.fromJson(asMapField(frozen, 'frozen_verdict')),
      verdictHistory: history
          .map((v) => Verdict.fromJson(asMapField(v, 'verdict_history')))
          .toList(),
    );
  }
}

const _unset = Object();

class RunSidecarCodec {
  const RunSidecarCodec._();

  static String encode(RunSidecar sidecar) => jsonEncode(sidecar.toJson());

  static RunSidecar decode(String text) {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (e) {
      throw RunFileFormatException('sidecar not JSON: ${e.message}');
    }
    if (parsed is! Map<String, Object?>) {
      throw RunFileFormatException('sidecar top level must be an object');
    }
    return RunSidecar.fromJson(parsed);
  }
}
