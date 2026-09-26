import 'run_file.dart';

/// A structured session (Phase 3 plan §3.3): a flat, already-expanded list of
/// steps plus an open or fixed warm-up and cool-down. Presets and custom
/// templates expand into this; the recorder, the run file and the engine
/// only ever see the expanded list, so they cannot disagree.
///
/// Wire shape (run file `session`, sidecar-free, journal header, Pigeon
/// `SessionSpec`): flat, canonical key order, see [toJson].
enum StepKind { work, recovery }

/// What ends a step: a duration ([value] seconds), a distance ([value]
/// metres), or, for a recovery, the measured time of the work step before it
/// (Yasso "equal time"; [value] 0).
enum TargetKind { time, distance, equalToPreviousWork }

/// Work steps are always [run]; recoveries jog, walk or stand.
enum RecoveryStyle { run, jog, walk, stand }

/// Cue density: [short] for steps under a minute (no halfway chatter),
/// [cooper] for the 12-minute test's projections.
enum CueProfile { standard, short, cooper }

class SessionStep {
  const SessionStep({
    required this.kind,
    required this.target,
    required this.value,
    required this.style,
    required this.rep,
  });

  const SessionStep.work(int seconds, {required this.rep})
    : kind = StepKind.work,
      target = TargetKind.time,
      value = seconds,
      style = RecoveryStyle.run;

  const SessionStep.workDistance(int metres, {required this.rep})
    : kind = StepKind.work,
      target = TargetKind.distance,
      value = metres,
      style = RecoveryStyle.run;

  const SessionStep.recovery(
    int seconds, {
    required this.rep,
    this.style = RecoveryStyle.jog,
  }) : kind = StepKind.recovery,
       target = TargetKind.time,
       value = seconds;

  const SessionStep.recoveryDistance(
    int metres, {
    required this.rep,
    this.style = RecoveryStyle.jog,
  }) : kind = StepKind.recovery,
       target = TargetKind.distance,
       value = metres;

  const SessionStep.recoveryEqualTime({
    required this.rep,
    this.style = RecoveryStyle.jog,
  }) : kind = StepKind.recovery,
       target = TargetKind.equalToPreviousWork,
       value = 0;

  final StepKind kind;
  final TargetKind target;

  /// Seconds for [TargetKind.time], metres for [TargetKind.distance], 0 for
  /// [TargetKind.equalToPreviousWork].
  final int value;
  final RecoveryStyle style;

  /// 1-based; a recovery carries the number of the rep before it.
  final int rep;

  bool get isWork => kind == StepKind.work;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'target': target.name,
    'value': value,
    'style': style.name,
    'rep': rep,
  };

  factory SessionStep.fromJson(Map<String, Object?> json) => SessionStep(
    kind: _enum(StepKind.values, json['kind'], 'step.kind'),
    target: _enum(TargetKind.values, json['target'], 'step.target'),
    value: readIntField(json, 'value'),
    style: _enum(RecoveryStyle.values, json['style'], 'step.style'),
    rep: readIntField(json, 'rep'),
  );

  @override
  bool operator ==(Object other) =>
      other is SessionStep &&
      other.kind == kind &&
      other.target == target &&
      other.value == value &&
      other.style == style &&
      other.rep == rep;

  @override
  int get hashCode => Object.hash(kind, target, value, style, rep);

  @override
  String toString() =>
      'SessionStep(${kind.name} ${target.name} $value ${style.name} #$rep)';
}

class SessionSpec {
  const SessionSpec({
    required this.templateId,
    required this.templateVersion,
    required this.name,
    this.warmupSeconds,
    this.cooldownSeconds,
    this.lapLockout = false,
    this.autoStop = false,
    this.cueProfile = CueProfile.standard,
    this.hrBandLow,
    this.hrBandHigh,
    required this.steps,
  });

  static const String norwegian4x4Id = 'norwegian-4x4';
  static const String cooperId = 'cooper';
  static const String fartlekId = 'fartlek';
  static const String parkrunId = 'parkrun'; // event-name-ok: data key
  static const String customPrefix = 'custom:';

  /// Most steps a session may expand to (40 reps + 39 recoveries).
  static const int maxSteps = 80;

  /// `norwegian-4x4`, a catalogue id, `custom:<uuid>`, `fartlek`, `cooper`.
  final String templateId;

  /// Custom edits bump it; presets bump only on a catalogue change.
  final int templateVersion;
  final String name;

  /// null = open ("tap START REPS when ready" / "stop when done").
  final int? warmupSeconds;
  final int? cooldownSeconds;

  /// Cooper: manual laps ignored during work.
  final bool lapLockout;

  /// The recording stops itself when the last timed part ends (after the
  /// last step, or after a fixed cool-down). Parkrun only (Phase 3 I2);
  /// a schema-3 file without the key reads as false.
  final bool autoStop;
  final CueProfile cueProfile;

  /// Fractions of max HR for time-in-zone (4x4: 0.85–0.95); both or neither.
  final double? hrBandLow;
  final double? hrBandHigh;

  /// Expanded: work, recovery, work, …, work (no recovery after the last
  /// rep). Empty only for fartlek.
  final List<SessionStep> steps;

  Iterable<SessionStep> get workSteps => steps.where((s) => s.isWork);
  int get repCount => workSteps.length;

  /// A schema ≤ 2 4x4 preset (or the v1 default when a by-feel run is
  /// overridden to a 4x4) as a schema-3 session (plan §3.8 mapping).
  factory SessionSpec.norwegian4x4({
    int reps = 4,
    int workSeconds = 240,
    int recoverySeconds = 180,
  }) => SessionSpec(
    templateId: norwegian4x4Id,
    templateVersion: 1,
    name: 'Norwegian 4x4',
    hrBandLow: 0.85,
    hrBandHigh: 0.95,
    steps: uniform(
      reps: reps,
      work: (rep) => SessionStep.work(workSeconds, rep: rep),
      recovery: (rep) => SessionStep.recovery(recoverySeconds, rep: rep),
    ),
  );

  factory SessionSpec.fromLegacyPreset(Preset p) => SessionSpec.norwegian4x4(
    reps: p.reps,
    workSeconds: p.workSeconds,
    recoverySeconds: p.recoverySeconds,
  );

  /// The 12-minute test: one 720 s work step, manual laps locked out.
  static const SessionSpec cooper = SessionSpec(
    templateId: cooperId,
    templateVersion: 1,
    name: '12-minute test',
    lapLockout: true,
    cueProfile: CueProfile.cooper,
    steps: [SessionStep.work(720, rep: 1)],
  );

  /// The Saturday 5 km time trial (K1): one 5000 m step from the Start
  /// press, auto-stop at 5.00 km. [name] is the flavour's event name
  /// (`EventNames.parkrun`), never a literal here.
  static SessionSpec parkrun(String name) => SessionSpec(
    templateId: parkrunId,
    templateVersion: 1,
    name: name,
    autoStop: true,
    steps: const [SessionStep.workDistance(5000, rep: 1)],
  );

  /// By-feel speed play, recorded as a Laps run: no steps, no timing.
  static const SessionSpec fartlek = SessionSpec(
    templateId: fartlekId,
    templateVersion: 1,
    name: 'Fartlek',
    steps: [],
  );

  /// `reps` work steps with `reps − 1` recoveries between them.
  static List<SessionStep> uniform({
    required int reps,
    required SessionStep Function(int rep) work,
    required SessionStep Function(int rep) recovery,
  }) => [
    for (var r = 1; r <= reps; r++) ...[work(r), if (r < reps) recovery(r)],
  ];

  /// The detector's legacy view (Phase 2 `Preset`): every work step the same
  /// time and every recovery the same time. Null for anything else; the
  /// generalised detector is Phase 3 I3.
  Preset? get legacyPreset {
    final work = workSteps.toList();
    final rec = steps.where((s) => !s.isWork).toList();
    if (work.isEmpty) return null;
    if (work.any((s) => s.target != TargetKind.time)) return null;
    if (work.any((s) => s.value != work.first.value)) return null;
    if (rec.any((s) => s.target != TargetKind.time)) return null;
    if (rec.any((s) => s.value != rec.first.value)) return null;
    // A 1-rep session has no recovery; a Preset needs one only to match
    // recovery laps, and there are none.
    return Preset(
      reps: work.length,
      workSeconds: work.first.value,
      recoverySeconds: rec.isEmpty ? 0 : rec.first.value,
    );
  }

  /// Comparison key (plan §3.3, §3.7): the work steps only. Rep count and
  /// recovery may differ between two runs of one key (D4).
  String get comparisonKey => ComparisonKey.of(this);

  /// Every rule in plan §3.3; returns the problems (empty = valid). The same
  /// table runs in Kotlin (`SessionSpec.validate`).
  List<String> validate() {
    final out = <String>[];
    if (templateId.isEmpty) out.add('templateId is empty');
    if (templateVersion < 1) out.add('templateVersion must be >= 1');
    if ((hrBandLow == null) != (hrBandHigh == null)) {
      out.add('hrBand needs both ends');
    } else if (hrBandLow != null &&
        !(hrBandLow! > 0 && hrBandLow! < hrBandHigh! && hrBandHigh! <= 1.2)) {
      out.add('hrBand must be 0 < low < high <= 1.2');
    }
    for (final (label, v) in [
      ('warmup', warmupSeconds),
      ('cooldown', cooldownSeconds),
    ]) {
      if (v != null && (v < 300 || v > 1200)) {
        out.add('$label must be open or 300..1200 s');
      }
    }
    if (steps.isEmpty) {
      if (templateId != fartlekId) out.add('only fartlek may have no steps');
      return out;
    }
    if (steps.length > maxSteps) out.add('more than $maxSteps steps');
    final reps = repCount;
    if (reps < 1 || reps > 40) out.add('reps must be 1..40');
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final expectWork = i.isEven;
      if (s.isWork != expectWork) {
        out.add('step $i: steps must alternate work, recovery, …, work');
        continue;
      }
      final rep = i ~/ 2 + 1;
      if (s.rep != rep) out.add('step $i: rep must be $rep, got ${s.rep}');
      if (s.isWork) {
        if (s.style != RecoveryStyle.run) out.add('step $i: work style is run');
        switch (s.target) {
          case TargetKind.time:
            if (s.value < 15 || s.value > 1200) {
              out.add('step $i: time work must be 15..1200 s');
            }
          case TargetKind.distance:
            if (s.value < 100 || s.value > 10000) {
              out.add('step $i: distance work must be 100..10000 m');
            }
          case TargetKind.equalToPreviousWork:
            out.add('step $i: only a recovery can be equal time');
        }
      } else {
        if (s.style == RecoveryStyle.run) {
          out.add('step $i: recovery style is jog, walk or stand');
        }
        switch (s.target) {
          case TargetKind.time:
            if (s.value < 0 || s.value > 600) {
              out.add('step $i: time recovery must be 0..600 s');
            }
          case TargetKind.distance:
            if (s.value < 50 || s.value > 2000) {
              out.add('step $i: distance recovery must be 50..2000 m');
            }
            if (s.style != RecoveryStyle.jog) {
              out.add('step $i: walk and stand recoveries must be timed');
            }
          case TargetKind.equalToPreviousWork:
            if (s.value != 0) out.add('step $i: equal time carries value 0');
        }
      }
    }
    if (!steps.last.isWork) out.add('the last step must be work');
    return out;
  }

  Map<String, Object?> toJson() => {
    'templateId': templateId,
    'templateVersion': templateVersion,
    'name': name,
    'warmupSeconds': warmupSeconds,
    'cooldownSeconds': cooldownSeconds,
    'lapLockout': lapLockout,
    'autoStop': autoStop,
    'cueProfile': cueProfile.name,
    'hrBand': hrBandLow == null ? null : [hrBandLow, hrBandHigh],
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  static const Set<String> _keys = {
    'templateId',
    'templateVersion',
    'name',
    'warmupSeconds',
    'cooldownSeconds',
    'lapLockout',
    'autoStop',
    'cueProfile',
    'hrBand',
    'steps',
  };

  /// Strict like the run file: an unknown key is a newer writer; an invalid
  /// spec (plan §3.3 table) is refused.
  factory SessionSpec.fromJson(Map<String, Object?> json) {
    for (final k in json.keys) {
      if (!_keys.contains(k)) {
        throw RunFileNewerVersionException('unknown session key "$k"');
      }
    }
    int? optInt(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! int) throw RunFileFormatException('session.$key must be int');
      return v;
    }

    final lockout = json['lapLockout'];
    if (lockout is! bool) {
      throw RunFileFormatException('session.lapLockout must be bool');
    }
    final autoStop = json['autoStop'] ?? false;
    if (autoStop is! bool) {
      throw RunFileFormatException('session.autoStop must be bool');
    }
    final band = json['hrBand'];
    double? low;
    double? high;
    if (band != null) {
      if (band is! List || band.length != 2 || band.any((e) => e is! num)) {
        throw RunFileFormatException('session.hrBand must be [low, high]');
      }
      low = (band[0] as num).toDouble();
      high = (band[1] as num).toDouble();
    }
    final spec = SessionSpec(
      templateId: readStringField(json, 'templateId'),
      templateVersion: readIntField(json, 'templateVersion'),
      name: readStringField(json, 'name'),
      warmupSeconds: optInt('warmupSeconds'),
      cooldownSeconds: optInt('cooldownSeconds'),
      lapLockout: lockout,
      autoStop: autoStop,
      cueProfile: _enum(
        CueProfile.values,
        json['cueProfile'],
        'session.cueProfile',
      ),
      hrBandLow: low,
      hrBandHigh: high,
      steps: readListField(
        json,
        'steps',
      ).map((s) => SessionStep.fromJson(asMapField(s, 'step'))).toList(),
    );
    final problems = spec.validate();
    if (problems.isNotEmpty) {
      throw RunFileFormatException('session invalid: ${problems.join('; ')}');
    }
    return spec;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionSpec &&
      other.templateId == templateId &&
      other.templateVersion == templateVersion &&
      other.name == name &&
      other.warmupSeconds == warmupSeconds &&
      other.cooldownSeconds == cooldownSeconds &&
      other.lapLockout == lapLockout &&
      other.autoStop == autoStop &&
      other.cueProfile == cueProfile &&
      other.hrBandLow == hrBandLow &&
      other.hrBandHigh == hrBandHigh &&
      _listEq(other.steps, steps);

  @override
  int get hashCode => Object.hash(
    templateId,
    templateVersion,
    name,
    warmupSeconds,
    cooldownSeconds,
    lapLockout,
    autoStop,
    cueProfile,
    hrBandLow,
    hrBandHigh,
    Object.hashAll(steps),
  );

  @override
  String toString() =>
      'SessionSpec($templateId v$templateVersion, $name, '
      '${steps.length} steps)';
}

/// Plan §3.3 / §3.7: which runs compare with which. Derived from the work
/// steps only, so rep count and recovery may differ (D4):
/// - every work step `T` seconds → `t{T}x*` (every 4x4 is `t240x*`);
/// - every work step `D` metres → `d{D}x*`;
/// - a time ladder → `pyr:60,120,…`; a distance ladder → `dpyr:400,800,…`;
/// - mixed time and distance → `mix:t60,d400,…`;
/// - fartlek → `fartlek`; Cooper → `cooper`;
/// - parkrun → `parkrun` by template, never the generic `d5000x*` a custom
///   1 × 5000 m gets (lead decision 26-Sep); K1 adds the course as
///   `parkrun:<courseId>` through [parkrunOf].
abstract final class ComparisonKey {
  static const String fartlek = 'fartlek';
  static const String cooper = 'cooper';
  static const String parkrun = 'parkrun'; // event-name-ok: data key
  static const String norwegian4x4 = 't240x*';

  /// `parkrun`, or `parkrun:<courseId>` once K1 knows the course.
  static String parkrunOf({String? courseId}) =>
      courseId == null || courseId.isEmpty ? parkrun : '$parkrun:$courseId';

  static bool isParkrun(String key) =>
      key == parkrun || key.startsWith('$parkrun:');

  static String of(SessionSpec spec) {
    if (spec.templateId == SessionSpec.fartlekId) return fartlek;
    if (spec.templateId == SessionSpec.cooperId) return cooper;
    if (spec.templateId == SessionSpec.parkrunId) return parkrunOf();
    final work = spec.workSteps.toList();
    if (work.isEmpty) return fartlek;
    final kinds = work.map((s) => s.target).toSet();
    if (kinds.length > 1) {
      return 'mix:${work.map((s) => '${s.target == TargetKind.time ? 't' : 'd'}${s.value}').join(',')}';
    }
    final isTime = kinds.single == TargetKind.time;
    final values = work.map((s) => s.value).toList();
    if (values.toSet().length == 1) {
      return '${isTime ? 't' : 'd'}${values.first}x*';
    }
    return '${isTime ? 'pyr' : 'dpyr'}:${values.join(',')}';
  }

  static bool isTime(String key) =>
      key.startsWith('t') || key.startsWith('pyr:');
  static bool isDistance(String key) =>
      key.startsWith('d') || key.startsWith('dpyr:');
}

T _enum<T extends Enum>(List<T> values, Object? name, String field) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw RunFileFormatException(
    '$field must be one of ${values.map((v) => v.name).join('|')}, got "$name"',
  );
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
