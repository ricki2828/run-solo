import 'dart:convert';

import '../run_mode.dart';
import 'run_file.dart';
import 'verdict.dart';

enum LapEditOp { merge, split, keep, drop }

/// A fix-laps edit (plan §5, §6 "Keep it, merge it, or drop it?"), indexed
/// against `RepDetection.laps` and applied in order before detection:
/// - `merge`: join lap `index` with the one after it;
/// - `split`: cut lap `index` at `atMs` (ms since run start);
/// - `keep`: accept lap `index` as its phase even outside the preset window
///   (a 3:20 last rep stays a rep; it is marked `outsideWindow`);
/// - `drop`: accept it as its phase but exclude it from every metric and
///   from the verdict, like an interrupted rep the runner chose to discard.
class LapEdit {
  const LapEdit.merge(this.index) : op = LapEditOp.merge, atMs = null;
  const LapEdit.split(this.index, int this.atMs) : op = LapEditOp.split;
  const LapEdit.keep(this.index) : op = LapEditOp.keep, atMs = null;
  const LapEdit.drop(this.index) : op = LapEditOp.drop, atMs = null;

  final LapEditOp op;
  final int index;
  final int? atMs;

  bool get isMerge => op == LapEditOp.merge;
  bool get isSplit => op == LapEditOp.split;
  bool get isKeep => op == LapEditOp.keep;
  bool get isDrop => op == LapEditOp.drop;

  Map<String, Object?> toJson() => {
    'op': op.name,
    'index': index,
    if (isSplit) 'at': atMs,
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
      case 'keep':
        return LapEdit.keep(index);
      case 'drop':
        return LapEdit.drop(index);
      default:
        throw RunFileFormatException(
          'lap_edit.op must be merge|split|keep|drop',
        );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LapEdit &&
      other.op == op &&
      other.index == index &&
      other.atMs == atMs;

  @override
  int get hashCode => Object.hash(op, index, atMs);
}

/// `run-<uuid>.edits.json` (plan §4): every user-authored or frozen fact
/// about a run, so a rebuild reproduces history instead of recomputing it.
///
/// Schema history (§18.7):
/// - 1: lap edits, override (`fourByFour|free`, `free` meaning today's
///   [RunMode.laps]), notes, frozen verdict, history.
/// - 2: adds optional `weather` and `cooper` objects (Phase 3 fills them;
///   this build carries them opaquely so a rewrite never drops them).
///   Missing keys read as absent; a v1 sidecar is re-encoded as v2.
/// - 3 (Phase 3 §3.8): `run_type_override` uses the schema-3 vocabulary
///   (`fourByFour` → `intervals`, mapped on read); adds `comparison_key`, a
///   cache of the run's comparison key for the index (never an input).
///   K1 adds an optional `parkrun` object (course id, official time); an
///   older schema-3 reader ignores it.
class RunSidecar {
  const RunSidecar({
    required this.runId,
    this.lapEdits = const [],
    this.runTypeOverride,
    this.notes,
    this.frozenVerdict,
    this.verdictHistory = const [],
    this.weather,
    this.cooper,
    this.comparisonKey,
    this.parkrun,
    this.readSchema = schema,
  });

  static const int schema = 3;
  static const int minReadSchema = 1;

  /// The schema the decoded bytes carried; not serialised.
  final int readSchema;

  final String runId;
  final List<LapEdit> lapEdits;

  /// Any of the run types (§18.2); a 4x4 override on a Laps file runs the
  /// by-feel detector.
  final RunMode? runTypeOverride;

  /// Reserved (§18.5, §18.4): opaque JSON objects owned by Phase 3. Kept
  /// byte-for-byte through decode → encode.
  final Map<String, Object?>? weather;
  final Map<String, Object?>? cooper;
  final String? notes;
  final Verdict? frozenVerdict;

  /// Cache only (the index groups by it); the engine derives the key from
  /// the run file and override, never from here.
  final String? comparisonKey;

  /// K1: the course and the runner's official time. An input: both feed
  /// the verdict (key and headline), so changing either unfreezes it.
  final ParkrunInfo? parkrun;

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
      verdictHistory.isEmpty &&
      weather == null &&
      cooper == null &&
      comparisonKey == null &&
      parkrun == null;

  RunSidecar copyWith({
    List<LapEdit>? lapEdits,
    Object? runTypeOverride = _unset,
    Object? notes = _unset,
    Object? frozenVerdict = _unset,
    List<Verdict>? verdictHistory,
    Object? weather = _unset,
    Object? cooper = _unset,
    Object? comparisonKey = _unset,
    Object? parkrun = _unset,
  }) => RunSidecar(
    runId: runId,
    parkrun: identical(parkrun, _unset)
        ? this.parkrun
        : parkrun as ParkrunInfo?,
    comparisonKey: identical(comparisonKey, _unset)
        ? this.comparisonKey
        : comparisonKey as String?,
    weather: identical(weather, _unset)
        ? this.weather
        : weather as Map<String, Object?>?,
    cooper: identical(cooper, _unset)
        ? this.cooper
        : cooper as Map<String, Object?>?,
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

  /// What the verdict was computed from ([Verdict.inputsKey]): edits,
  /// override and (K1, only when set) the parkrun course and official time.
  String get inputsKey => Verdict.inputsKeyFor(
    lapEdits,
    runTypeOverride,
    parkrun: parkrun?.toJson(),
  );

  /// Set the course or the official time (K1); unfreezes the verdict, which
  /// moves to history, like an override.
  RunSidecar withParkrun(ParkrunInfo? info) =>
      _unfrozen().copyWith(parkrun: info == null || info.isEmpty ? null : info);

  /// Freeze [verdict]; a different verdict already frozen moves to history
  /// (an engine bump recomputed it). An engine bump that leaves the headline
  /// and text unchanged adds no history line (Phase 3 eng-review INFO).
  RunSidecar withFrozenVerdict(Verdict verdict) {
    final current = frozenVerdict;
    final replaced =
        current != null &&
        current.engineVersion != verdict.engineVersion &&
        !current.sameText(verdict);
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
    'weather': weather,
    'cooper': cooper,
    'comparison_key': comparisonKey,
    _parkrunKey: ?parkrun?.toJson(),
  };

  /// Newer than this build (W6): the app must treat the run as read-only and
  /// never rewrite the sidecar, rather than call it damaged.
  factory RunSidecar.fromJson(Map<String, Object?> json) {
    final schemaValue = json['schema'];
    if (schemaValue is int && schemaValue > schema) {
      throw RunFileNewerVersionException(
        'sidecar schema $schemaValue is newer than $schema',
      );
    }
    if (schemaValue is! int || schemaValue < minReadSchema) {
      throw RunFileFormatException(
        'sidecar schema must be $minReadSchema..$schema',
      );
    }
    final runId = readStringField(json, 'run_id');
    if (!RunFile.idPattern.hasMatch(runId)) {
      throw RunFileFormatException('sidecar run_id must be a uuid');
    }
    final overrideName = json['run_type_override'];
    if (overrideName != null && overrideName is! String) {
      throw RunFileFormatException('run_type_override must be a string');
    }
    final override = overrideName == null
        ? null
        : RunMode.decode(overrideName as String, schema: schemaValue);
    Map<String, Object?>? optObject(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! Map<String, Object?>) {
        throw RunFileFormatException('$key must be an object or null');
      }
      return v;
    }

    final notes = json['notes'];
    if (notes != null && notes is! String) {
      throw RunFileFormatException('notes must be a string or null');
    }
    final key = json['comparison_key'];
    if (key != null && key is! String) {
      throw RunFileFormatException('comparison_key must be a string or null');
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
      weather: optObject('weather'),
      cooper: optObject('cooper'),
      comparisonKey: key as String?,
      parkrun: ParkrunInfo.fromJson(optObject(_parkrunKey)),
      readSchema: schemaValue,
    );
  }
}

/// A parkrun's course and official time (K1), both optional.
class ParkrunInfo {
  const ParkrunInfo({this.courseId, this.officialTimeSeconds});

  /// Auto-tagged by start point (ParkrunCourses) or picked by the runner.
  final String? courseId;

  /// The runner's official time, whole seconds; replaces the GPS finish.
  final int? officialTimeSeconds;

  bool get isEmpty => courseId == null && officialTimeSeconds == null;

  /// An official time more than this far from the GPS finish is taken as a
  /// typo (2:43 for 24:03): the entry UI refuses it and the engine ignores
  /// it, so it can never become a PB.
  static const double maxOfficialDeviation = 0.20;

  /// A 5 km finish outside 12:00 to 1:30:00 is not a real time.
  static const int minOfficialSeconds = 12 * 60;
  static const int maxOfficialSeconds = 90 * 60;

  /// True when [officialSeconds] is a real 5 km time (12:00 to 1:30:00)
  /// and within ±[maxOfficialDeviation] of the GPS finish ([gpsSeconds]).
  static bool plausibleOfficial(int officialSeconds, double gpsSeconds) =>
      officialTimeProblem(officialSeconds, gpsSeconds: gpsSeconds) == null;

  /// Why the entry screen refuses [officialSeconds], or null when it is
  /// fine. Same rule the engine applies, so the UI and a written sidecar
  /// never disagree.
  static String? officialTimeProblem(
    int officialSeconds, {
    double? gpsSeconds,
  }) {
    if (officialSeconds < minOfficialSeconds ||
        officialSeconds > maxOfficialSeconds) {
      return 'That time looks off. Enter it as mm:ss, between 12:00 and '
          '1:30:00.';
    }
    if (gpsSeconds != null &&
        gpsSeconds > 0 &&
        (officialSeconds - gpsSeconds).abs() >
            maxOfficialDeviation * gpsSeconds) {
      return 'That is a long way from your watch time. Check it and try '
          'again.';
    }
    return null;
  }

  ParkrunInfo copyWith({
    Object? courseId = _unset,
    Object? officialTimeSeconds = _unset,
  }) => ParkrunInfo(
    courseId: identical(courseId, _unset) ? this.courseId : courseId as String?,
    officialTimeSeconds: identical(officialTimeSeconds, _unset)
        ? this.officialTimeSeconds
        : officialTimeSeconds as int?,
  );

  Map<String, Object?> toJson() => {
    'course_id': ?courseId,
    'official_time_s': ?officialTimeSeconds,
  };

  static ParkrunInfo? fromJson(Map<String, Object?>? j) {
    if (j == null) return null;
    final course = j['course_id'];
    final official = j['official_time_s'];
    if (course != null && (course is! String || course.isEmpty)) {
      throw RunFileFormatException('course_id must be a string');
    }
    if (official != null && (official is! int || official <= 0)) {
      throw RunFileFormatException('official_time_s must be a positive int');
    }
    final info = ParkrunInfo(
      courseId: course as String?,
      officialTimeSeconds: official as int?,
    );
    return info.isEmpty ? null : info;
  }

  @override
  bool operator ==(Object other) =>
      other is ParkrunInfo &&
      other.courseId == courseId &&
      other.officialTimeSeconds == officialTimeSeconds;

  @override
  int get hashCode => Object.hash(courseId, officialTimeSeconds);
}

const _unset = Object();

const _parkrunKey = 'parkrun'; // event-name-ok: data key

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
