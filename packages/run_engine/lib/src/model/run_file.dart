import 'dart:convert';

import '../run_mode.dart';

/// Thrown by the codec when a run file or sidecar does not match schema 1.
class RunFileFormatException implements Exception {
  RunFileFormatException(this.message);
  final String message;

  @override
  String toString() => 'RunFileFormatException: $message';
}

/// The file was written by a newer app (schema above 1 or a key this
/// version does not know). The import screen should say "made by a newer
/// version", not "malformed".
class RunFileNewerVersionException extends RunFileFormatException {
  RunFileNewerVersionException(super.message);
}

/// Distance units chosen at Start; only affects display, never storage.
enum Units { km, mi }

/// The 4x4 preset written into the file header (plan §6). Drives the cues in
/// Kotlin and the detector's expected pattern here, so they cannot disagree.
class Preset {
  const Preset({
    required this.reps,
    required this.workSeconds,
    required this.recoverySeconds,
  });

  final int reps;
  final int workSeconds;
  final int recoverySeconds;

  /// The v1 default: 4 x 4:00 work / 3:00 recovery.
  static const Preset standard = Preset(
    reps: 4,
    workSeconds: 240,
    recoverySeconds: 180,
  );

  Map<String, Object?> toJson() => {
    'reps': reps,
    'workSeconds': workSeconds,
    'recoverySeconds': recoverySeconds,
  };

  factory Preset.fromJson(Map<String, Object?> json) {
    final reps = _readInt(json, 'reps');
    final work = _readInt(json, 'workSeconds');
    final recovery = _readInt(json, 'recoverySeconds');
    if (reps < 3 || reps > 6) {
      throw RunFileFormatException('preset.reps must be 3..6, got $reps');
    }
    if (work <= 0 || recovery <= 0) {
      throw RunFileFormatException('preset durations must be positive');
    }
    return Preset(reps: reps, workSeconds: work, recoverySeconds: recovery);
  }

  @override
  bool operator ==(Object other) =>
      other is Preset &&
      other.reps == reps &&
      other.workSeconds == workSeconds &&
      other.recoverySeconds == recoverySeconds;

  @override
  int get hashCode => Object.hash(reps, workSeconds, recoverySeconds);

  @override
  String toString() => 'Preset($reps x ${workSeconds}s/${recoverySeconds}s)';
}

/// How a lap boundary came to exist. `pause` laps are the recorder's bookkeeping
/// around a pause and are dropped by the detector (plan §5).
enum LapKind { manual, auto, pause }

/// One lap as recorded: `[t0, t1)` in ms since run start, `[d0, d1]` in metres.
class Lap {
  const Lap({
    required this.index,
    required this.t0Ms,
    required this.t1Ms,
    required this.d0M,
    required this.d1M,
    required this.kind,
  });

  final int index;
  final int t0Ms;
  final int t1Ms;
  final double d0M;
  final double d1M;
  final LapKind kind;

  int get durationMs => t1Ms - t0Ms;
  double get distanceM => d1M - d0M;

  Lap copyWith({
    int? index,
    int? t0Ms,
    int? t1Ms,
    double? d0M,
    double? d1M,
    LapKind? kind,
  }) => Lap(
    index: index ?? this.index,
    t0Ms: t0Ms ?? this.t0Ms,
    t1Ms: t1Ms ?? this.t1Ms,
    d0M: d0M ?? this.d0M,
    d1M: d1M ?? this.d1M,
    kind: kind ?? this.kind,
  );

  Map<String, Object?> toJson() => {
    'i': index,
    't0': t0Ms,
    't1': t1Ms,
    'd0': _num(d0M),
    'd1': _num(d1M),
    'kind': kind.name,
  };

  factory Lap.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    final kind = LapKind.values.cast<LapKind?>().firstWhere(
      (k) => k!.name == kindName,
      orElse: () => null,
    );
    if (kind == null) {
      throw RunFileFormatException('lap.kind must be manual|auto|pause');
    }
    final lap = Lap(
      index: _readInt(json, 'i'),
      t0Ms: _readInt(json, 't0'),
      t1Ms: _readInt(json, 't1'),
      d0M: _readDouble(json, 'd0'),
      d1M: _readDouble(json, 'd1'),
      kind: kind,
    );
    if (lap.t1Ms < lap.t0Ms) {
      throw RunFileFormatException('lap ${lap.index}: t1 < t0');
    }
    if (lap.d1M < lap.d0M) {
      throw RunFileFormatException('lap ${lap.index}: d1 < d0');
    }
    return lap;
  }
}

/// A closed time span in ms since run start. Used for `pauses[]` and `gaps[]`.
class Span {
  const Span(this.t0Ms, this.t1Ms);
  final int t0Ms;
  final int t1Ms;

  int get durationMs => t1Ms - t0Ms;

  bool overlaps(int aMs, int bMs) => t0Ms < bMs && t1Ms > aMs;

  List<int> toJson() => [t0Ms, t1Ms];

  factory Span.fromJson(Object? json) {
    if (json is! List || json.length != 2 || json.any((e) => e is! int)) {
      throw RunFileFormatException('span must be [t0, t1] ints');
    }
    final s = Span(json[0] as int, json[1] as int);
    if (s.t1Ms < s.t0Ms) throw RunFileFormatException('span t1 < t0');
    return s;
  }

  @override
  bool operator ==(Object other) =>
      other is Span && other.t0Ms == t0Ms && other.t1Ms == t1Ms;

  @override
  int get hashCode => Object.hash(t0Ms, t1Ms);
}

/// One 1 Hz sample: `[t, lat, lon, alt, acc, speed, dist, hr]`. `lat`/`lon`
/// are null when there is no fix; `hr` is null when no strap (never 0).
/// `distM` is the recorder's cumulative distance over accepted points.
class Sample {
  const Sample({
    required this.tMs,
    this.lat,
    this.lon,
    this.altM,
    this.accM,
    this.speedMps,
    required this.distM,
    this.hr,
  });

  final int tMs;
  final double? lat;
  final double? lon;
  final double? altM;
  final double? accM;
  final double? speedMps;
  final double distM;
  final int? hr;

  bool get hasFix => lat != null && lon != null;

  Sample copyWith({
    int? tMs,
    Object? lat = _unset,
    Object? lon = _unset,
    Object? altM = _unset,
    Object? accM = _unset,
    Object? speedMps = _unset,
    double? distM,
    Object? hr = _unset,
  }) => Sample(
    tMs: tMs ?? this.tMs,
    lat: identical(lat, _unset) ? this.lat : lat as double?,
    lon: identical(lon, _unset) ? this.lon : lon as double?,
    altM: identical(altM, _unset) ? this.altM : altM as double?,
    accM: identical(accM, _unset) ? this.accM : accM as double?,
    speedMps: identical(speedMps, _unset) ? this.speedMps : speedMps as double?,
    distM: distM ?? this.distM,
    hr: identical(hr, _unset) ? this.hr : hr as int?,
  );

  List<Object?> toJson() => [
    tMs,
    _numOrNull(lat, 6),
    _numOrNull(lon, 6),
    _numOrNull(altM, 1),
    _numOrNull(accM, 1),
    _numOrNull(speedMps, 2),
    _num(distM),
    hr,
  ];

  factory Sample.fromJson(Object? json) {
    if (json is! List || json.length != 8) {
      throw RunFileFormatException('sample must have 8 fields');
    }
    final t = json[0];
    if (t is! int) throw RunFileFormatException('sample.t must be int');
    final dist = json[6];
    if (dist is! num) throw RunFileFormatException('sample.dist must be num');
    final hr = json[7];
    if (hr != null && hr is! int) {
      throw RunFileFormatException('sample.hr must be int or null');
    }
    if (hr is int && hr <= 0) {
      throw RunFileFormatException('sample.hr must be > 0 or null');
    }
    double? optNum(int i, String name) {
      final v = json[i];
      if (v == null) return null;
      if (v is! num) throw RunFileFormatException('sample.$name must be num');
      return v.toDouble();
    }

    final lat = optNum(1, 'lat');
    final lon = optNum(2, 'lon');
    if ((lat == null) != (lon == null)) {
      throw RunFileFormatException('sample lat/lon must both be set or null');
    }
    return Sample(
      tMs: t,
      lat: lat,
      lon: lon,
      altM: optNum(3, 'alt'),
      accM: optNum(4, 'acc'),
      speedMps: optNum(5, 'speed'),
      distM: dist.toDouble(),
      hr: hr as int?,
    );
  }
}

const _unset = Object();

/// The run file, schema 1 (plan §4). Written by Kotlin at `stop()`, read here.
class RunFile {
  RunFile({
    required this.id,
    required this.device,
    required this.app,
    required this.start,
    required this.end,
    required this.tz,
    required this.mode,
    this.preset,
    required this.units,
    required this.laps,
    this.pauses = const [],
    this.gaps = const [],
    required this.samples,
  });

  static const int schema = 1;

  final String id;
  final String device;
  final String app;
  final DateTime start;
  final DateTime end;
  final String tz;
  final RunMode mode;
  final Preset? preset;
  final Units units;
  final List<Lap> laps;
  final List<Span> pauses;
  final List<Span> gaps;
  final List<Sample> samples;

  int get elapsedMs => samples.isEmpty ? 0 : samples.last.tMs;

  double get distanceM => samples.isEmpty ? 0 : samples.last.distM;

  bool get hasHr => samples.any((s) => s.hr != null);

  RunFile copyWith({
    String? id,
    RunMode? mode,
    Object? preset = _unset,
    List<Lap>? laps,
    List<Span>? pauses,
    List<Span>? gaps,
    List<Sample>? samples,
  }) => RunFile(
    id: id ?? this.id,
    device: device,
    app: app,
    start: start,
    end: end,
    tz: tz,
    mode: mode ?? this.mode,
    preset: identical(preset, _unset) ? this.preset : preset as Preset?,
    units: units,
    laps: laps ?? this.laps,
    pauses: pauses ?? this.pauses,
    gaps: gaps ?? this.gaps,
    samples: samples ?? this.samples,
  );

  Map<String, Object?> toJson() => {
    'schema': schema,
    'id': id,
    'device': device,
    'app': app,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'tz': tz,
    'mode': mode.name,
    'preset': preset?.toJson(),
    'units': units.name,
    'laps': laps.map((l) => l.toJson()).toList(),
    'pauses': pauses.map((p) => p.toJson()).toList(),
    'gaps': gaps.map((g) => g.toJson()).toList(),
    'samples': samples.map((s) => s.toJson()).toList(),
  };

  /// Strict: unknown schema, unknown or missing keys, wrong types, naive
  /// timestamps, unordered samples or overlapping laps all throw
  /// [RunFileFormatException]. Laps past the last sample are allowed (an
  /// imported watch file may end its last lap after its last trackpoint).
  static const Set<String> _keys = {
    'schema',
    'id',
    'device',
    'app',
    'start',
    'end',
    'tz',
    'mode',
    'preset',
    'units',
    'laps',
    'pauses',
    'gaps',
    'samples',
  };

  factory RunFile.fromJson(Map<String, Object?> json) {
    final schemaValue = json['schema'];
    if (schemaValue is int && schemaValue > schema) {
      throw RunFileNewerVersionException(
        'schema $schemaValue is newer than $schema',
      );
    }
    if (schemaValue != schema) {
      throw RunFileFormatException('schema must be $schema');
    }
    // Strict: an unknown key means a newer writer; refuse rather than drop
    // it silently (the store keeps the original bytes for export anyway).
    for (final k in json.keys) {
      if (!_keys.contains(k)) {
        throw RunFileNewerVersionException('unknown key "$k"');
      }
    }
    final id = _readString(json, 'id');
    if (!idPattern.hasMatch(id)) {
      throw RunFileFormatException('id must be a filename-safe token');
    }
    final modeName = _readString(json, 'mode');
    final mode = RunMode.values.cast<RunMode?>().firstWhere(
      (m) => m!.name == modeName,
      orElse: () => null,
    );
    if (mode == null) throw RunFileFormatException('mode must be a RunMode');
    final unitsName = _readString(json, 'units');
    final units = Units.values.cast<Units?>().firstWhere(
      (u) => u!.name == unitsName,
      orElse: () => null,
    );
    if (units == null) throw RunFileFormatException('units must be km|mi');
    final presetJson = json['preset'];
    if (presetJson != null && presetJson is! Map<String, Object?>) {
      throw RunFileFormatException('preset must be an object or null');
    }
    // A repeated or out-of-order `t` is one bad line from the writer, not a
    // reason to make the whole run unreadable: drop it and keep the first.
    final samples = <Sample>[];
    for (final raw in _readList(json, 'samples')) {
      final sample = Sample.fromJson(raw);
      if (samples.isNotEmpty && sample.tMs <= samples.last.tMs) continue;
      if (samples.isNotEmpty && sample.distM < samples.last.distM) {
        throw RunFileFormatException('sample dist must be non-decreasing');
      }
      samples.add(sample);
    }
    final laps = _readList(
      json,
      'laps',
    ).map((l) => Lap.fromJson(_asMap(l, 'lap'))).toList();
    for (var i = 0; i < laps.length; i++) {
      if (laps[i].index != i) {
        throw RunFileFormatException('laps must be indexed 0..n-1 in order');
      }
      if (i > 0 && laps[i].t0Ms < laps[i - 1].t1Ms) {
        throw RunFileFormatException('laps must not overlap');
      }
    }
    return RunFile(
      id: id,
      device: _readString(json, 'device'),
      app: _readString(json, 'app'),
      start: _readDateTime(json, 'start'),
      end: _readDateTime(json, 'end'),
      tz: _readString(json, 'tz'),
      mode: mode,
      preset: presetJson == null
          ? null
          : Preset.fromJson(presetJson as Map<String, Object?>),
      units: units,
      laps: laps,
      pauses: _readList(json, 'pauses').map(Span.fromJson).toList(),
      gaps: _readList(json, 'gaps').map(Span.fromJson).toList(),
      samples: samples,
    );
  }

  /// The app writes uuids; any filename-safe token (`run-<id>.json.gz`) is
  /// accepted so test fixtures and future writers stay readable.
  static final RegExp idPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

  static final RegExp uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// Canonical JSON: fixed key order and number formatting, so a decode → encode
/// round trip is byte-identical (plan §12 import/export).
class RunFileCodec {
  const RunFileCodec._();

  static String encode(RunFile run) => jsonEncode(run.toJson());

  static RunFile decode(String text) {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException catch (e) {
      throw RunFileFormatException('not JSON: ${e.message}');
    }
    if (parsed is! Map<String, Object?>) {
      throw RunFileFormatException('top level must be an object');
    }
    return RunFile.fromJson(parsed);
  }
}

// Helpers shared with the sidecar codec.

int _readInt(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is! int) throw RunFileFormatException('$key must be an int');
  return v;
}

double _readDouble(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is! num) throw RunFileFormatException('$key must be a number');
  return v.toDouble();
}

String _readString(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is! String) throw RunFileFormatException('$key must be a string');
  return v;
}

/// ISO 8601 with an explicit `Z` or offset: a naive timestamp would parse
/// in the phone's local zone and shift with travel.
final RegExp _isoWithOffset = RegExp(r'(Z|[+-]\d\d:?\d\d)$');

DateTime _readDateTime(Map<String, Object?> json, String key) {
  final v = _readString(json, key);
  final parsed = DateTime.tryParse(v);
  if (parsed == null || !_isoWithOffset.hasMatch(v)) {
    throw RunFileFormatException('$key must be ISO 8601 with Z or an offset');
  }
  return parsed.toUtc();
}

List<Object?> _readList(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is! List) throw RunFileFormatException('$key must be a list');
  return v;
}

Map<String, Object?> _asMap(Object? v, String what) {
  if (v is! Map<String, Object?>) {
    throw RunFileFormatException('$what must be an object');
  }
  return v;
}

/// Metres and similar are stored with 2 dp so encode(decode(x)) is stable.
num _num(double v) {
  final r = (v * 100).round() / 100;
  return r == r.truncateToDouble() ? r.toInt() : r;
}

num? _numOrNull(double? v, int dp) {
  if (v == null) return null;
  final f = _pow10[dp];
  final r = (v * f).round() / f;
  return r == r.truncateToDouble() ? r.toInt() : r;
}

const _pow10 = [1, 10, 100, 1000, 10000, 100000, 1000000];

// Exposed for the sidecar codec in the same library group.
int readIntField(Map<String, Object?> json, String key) => _readInt(json, key);
double readDoubleField(Map<String, Object?> json, String key) =>
    _readDouble(json, key);
String readStringField(Map<String, Object?> json, String key) =>
    _readString(json, key);
DateTime readDateTimeField(Map<String, Object?> json, String key) =>
    _readDateTime(json, key);
List<Object?> readListField(Map<String, Object?> json, String key) =>
    _readList(json, key);
Map<String, Object?> asMapField(Object? v, String what) => _asMap(v, what);
