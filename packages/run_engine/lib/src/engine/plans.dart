import '../model/session_spec.dart';
import '../run_mode.dart';

/// Training plans (v1 plan §7; design brief §4.10). Three bundled templates
/// (`assets/plans/*.json`, versioned), one active enrolment, and a tick
/// ledger. Pure data and date logic: the app owns storage (plans.json beside
/// index.json), rendering, and reminders.
///
/// The enrolment + tick JSON shape is frozen with the first closed-track
/// build, like the run-file schema: [PlanState.schema] is the version gate.

/// A session kind inside a plan template. v1 has exactly two: a structured
/// 4x4 (intervals mode) and an easy free run.
enum PlanSessionKind { fourByFour, easy }

/// One session in a plan week: either `fourByFour` (reps + recoverySeconds)
/// or `easy` (minutes). The other parameter set is null.
class PlanSession {
  const PlanSession.fourByFour({
    required this.reps,
    required this.recoverySeconds,
  }) : kind = PlanSessionKind.fourByFour,
       minutes = null;

  const PlanSession.easy(this.minutes)
    : kind = PlanSessionKind.easy,
      reps = null,
      recoverySeconds = null;

  final PlanSessionKind kind;
  final int? reps;
  final int? recoverySeconds;
  final int? minutes;

  /// The run mode a finished run must have to tick this session.
  RunMode get mode =>
      kind == PlanSessionKind.fourByFour ? RunMode.intervals : RunMode.free;

  /// Card and row label, e.g. `4x4 · 4 reps` / `Easy · 30 min`.
  String get label => switch (kind) {
    PlanSessionKind.fourByFour => '4x4 · $reps reps',
    PlanSessionKind.easy => 'Easy · $minutes min',
  };

  /// The structured session the start screen pre-fills with, or null for an
  /// easy run (free mode has no session spec; the duration is copy only).
  SessionSpec? toSessionSpec() => kind == PlanSessionKind.fourByFour
      ? SessionSpec.norwegian4x4(reps: reps!, recoverySeconds: recoverySeconds!)
      : null;

  Map<String, Object?> toJson() => switch (kind) {
    PlanSessionKind.fourByFour => {
      'kind': 'fourByFour',
      'reps': reps,
      'recoverySeconds': recoverySeconds,
    },
    PlanSessionKind.easy => {'kind': 'easy', 'minutes': minutes},
  };

  static PlanSession fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind == 'fourByFour') {
      final reps = json['reps'];
      final recovery = json['recoverySeconds'];
      if (reps is! int || reps <= 0) {
        throw const FormatException('fourByFour session needs reps > 0');
      }
      if (recovery is! int || recovery <= 0) {
        throw const FormatException(
          'fourByFour session needs recoverySeconds > 0',
        );
      }
      return PlanSession.fourByFour(reps: reps, recoverySeconds: recovery);
    }
    if (kind == 'easy') {
      final minutes = json['minutes'];
      if (minutes is! int || minutes <= 0) {
        throw const FormatException('easy session needs minutes > 0');
      }
      return PlanSession.easy(minutes);
    }
    throw FormatException('unknown plan session kind: $kind');
  }
}

/// A bundled plan template: a fixed sequence of weeks, each an ordered list
/// of sessions. Loaded from `assets/plans/<id>.json`; [version] bumps when
/// the content changes, and enrolments record the version they took.
class PlanTemplate {
  const PlanTemplate({
    required this.id,
    required this.version,
    required this.name,
    required this.oneLiner,
    required this.weeks,
  });

  final String id;
  final int version;
  final String name;
  final String oneLiner;

  /// weeks[w] is the ordered session list for plan week w + 1.
  final List<List<PlanSession>> weeks;

  int get weekCount => weeks.length;
  int get totalSessions => weeks.fold(0, (n, w) => n + w.length);

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'name': name,
    'oneLiner': oneLiner,
    'weeks': [
      for (final w in weeks) [for (final s in w) s.toJson()],
    ],
  };

  static PlanTemplate fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final version = json['version'];
    final name = json['name'];
    final oneLiner = json['oneLiner'];
    final weeks = json['weeks'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('plan template needs an id');
    }
    if (version is! int || version <= 0) {
      throw const FormatException('plan template needs version >= 1');
    }
    if (name is! String || name.isEmpty) {
      throw const FormatException('plan template needs a name');
    }
    if (weeks is! List || weeks.isEmpty) {
      throw const FormatException('plan template needs at least one week');
    }
    final parsed = <List<PlanSession>>[
      for (final week in weeks)
        [
          for (final s in (week as List))
            PlanSession.fromJson((s as Map).cast<String, Object?>()),
        ],
    ];
    if (parsed.any((w) => w.isEmpty)) {
      throw const FormatException('plan weeks must not be empty');
    }
    return PlanTemplate(
      id: id,
      version: version,
      name: name,
      oneLiner: oneLiner is String ? oneLiner : '',
      weeks: parsed,
    );
  }
}

/// The enrolment written when the user starts a plan (design brief §4.10:
/// weekday pick, optional single reminder time, plan time zone stored).
class PlanEnrolment {
  PlanEnrolment({
    required this.templateId,
    required this.templateVersion,
    required List<int> weekdays,
    required this.startDate,
    required this.tzOffsetMinutes,
    this.reminderMinutesOfDay,
  }) : weekdays = _normaliseWeekdays(weekdays);

  /// Default pick: Tuesday, Thursday, Saturday (design brief §4.10).
  static const List<int> defaultWeekdays = [
    DateTime.tuesday,
    DateTime.thursday,
    DateTime.saturday,
  ];

  final String templateId;
  final int templateVersion;

  /// DateTime weekday numbers (Monday = 1 … Sunday = 7), sorted, unique.
  final List<int> weekdays;

  /// The local date the plan starts. The first session lands on the first
  /// picked weekday on or after this date.
  final DateTime startDate;

  /// Minutes offset from UTC at enrolment; plan dates stay in this zone even
  /// if the user travels (v1 plan §7).
  final int tzOffsetMinutes;

  /// One reminder time as minutes after midnight, or null for none.
  final int? reminderMinutesOfDay;

  static List<int> _normaliseWeekdays(List<int> days) {
    if (days.isEmpty) {
      throw const FormatException('enrolment needs at least one weekday');
    }
    final set = <int>{};
    for (final d in days) {
      if (d < DateTime.monday || d > DateTime.sunday) {
        throw FormatException('weekday out of range: $d');
      }
      set.add(d);
    }
    return set.toList()..sort();
  }

  Map<String, Object?> toJson() => {
    'templateId': templateId,
    'templateVersion': templateVersion,
    'weekdays': weekdays,
    'startDate': _dateString(startDate),
    'tzOffsetMinutes': tzOffsetMinutes,
    if (reminderMinutesOfDay != null)
      'reminderMinutesOfDay': reminderMinutesOfDay,
  };

  static PlanEnrolment fromJson(Map<String, Object?> json) {
    final templateId = json['templateId'];
    final templateVersion = json['templateVersion'];
    final weekdays = json['weekdays'];
    final startDate = json['startDate'];
    final tzOffset = json['tzOffsetMinutes'];
    final reminder = json['reminderMinutesOfDay'];
    if (templateId is! String || templateId.isEmpty) {
      throw const FormatException('enrolment needs a templateId');
    }
    if (templateVersion is! int || templateVersion <= 0) {
      throw const FormatException('enrolment needs templateVersion >= 1');
    }
    if (weekdays is! List) {
      throw const FormatException('enrolment needs weekdays');
    }
    if (startDate is! String) {
      throw const FormatException('enrolment needs a startDate');
    }
    if (tzOffset is! int) {
      throw const FormatException('enrolment needs tzOffsetMinutes');
    }
    if (reminder != null &&
        (reminder is! int || reminder < 0 || reminder >= 24 * 60)) {
      throw const FormatException('reminderMinutesOfDay out of range');
    }
    return PlanEnrolment(
      templateId: templateId,
      templateVersion: templateVersion,
      weekdays: [for (final d in weekdays) d as int],
      startDate: _parseDate(startDate),
      tzOffsetMinutes: tzOffset,
      reminderMinutesOfDay: reminder as int?,
    );
  }
}

/// One ticked plan session. [runId] is null exactly when [manual] is true:
/// manual ticks exist so the user can keep marks honest (v1 plan §7).
class PlanTick {
  const PlanTick({
    required this.week,
    required this.sessionIndex,
    required this.runId,
    required this.manual,
    required this.tickedAt,
  });

  /// 1-based plan week and 0-based session index within the week.
  final int week;
  final int sessionIndex;
  final String? runId;
  final bool manual;
  final DateTime tickedAt;

  Map<String, Object?> toJson() => {
    'week': week,
    'session': sessionIndex,
    if (runId != null) 'runId': runId,
    'manual': manual,
    'tickedAt': tickedAt.toIso8601String(),
  };

  static PlanTick fromJson(Map<String, Object?> json) {
    final week = json['week'];
    final session = json['session'];
    final manual = json['manual'];
    final tickedAt = json['tickedAt'];
    if (week is! int || week <= 0) {
      throw const FormatException('tick needs week >= 1');
    }
    if (session is! int || session < 0) {
      throw const FormatException('tick needs session >= 0');
    }
    if (manual is! bool) {
      throw const FormatException('tick needs manual');
    }
    if (tickedAt is! String) {
      throw const FormatException('tick needs tickedAt');
    }
    return PlanTick(
      week: week,
      sessionIndex: session,
      runId: json['runId'] as String?,
      manual: manual,
      tickedAt: DateTime.parse(tickedAt),
    );
  }
}

/// The on-disk plans.json shape (v1 plan §7: "stored as plan_enrolment +
/// generated plan_tick rows", one active plan). Null [enrolment] means no
/// active plan; ticks then must be empty.
class PlanState {
  const PlanState({this.enrolment, this.ticks = const []});

  static const int schema = 1;

  final PlanEnrolment? enrolment;
  final List<PlanTick> ticks;

  Map<String, Object?> toJson() => {
    'schema': schema,
    'enrolment': enrolment?.toJson(),
    'ticks': [for (final t in ticks) t.toJson()],
  };

  static PlanState fromJson(Map<String, Object?> json) {
    if (json['schema'] != schema) {
      throw FormatException('plans.json schema must be $schema');
    }
    final enrolment = json['enrolment'];
    final ticks = json['ticks'];
    if (ticks is! List) {
      throw const FormatException('plans.json needs ticks');
    }
    return PlanState(
      enrolment: enrolment == null
          ? null
          : PlanEnrolment.fromJson((enrolment as Map).cast<String, Object?>()),
      ticks: [
        for (final t in ticks)
          PlanTick.fromJson((t as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// A plan session placed on a concrete local date.
class PlanSessionSlot {
  const PlanSessionSlot({
    required this.week,
    required this.sessionIndex,
    required this.date,
    required this.planSession,
  });

  /// 1-based plan week and 0-based session index within the week.
  final int week;
  final int sessionIndex;

  /// Local date (midnight) in the enrolment's stored zone.
  final DateTime date;
  final PlanSession planSession;
}

/// Places every session on a calendar date. Sessions go on the picked
/// weekdays in order starting from the first picked weekday on or after
/// [PlanEnrolment.startDate]. When the user picked fewer days than a week
/// has sessions, the extra sessions roll onto the following picked days; the
/// plan week still owns them (they tick into their own week, not the
/// calendar week they land in).
List<PlanSessionSlot> planSchedule(PlanTemplate template, PlanEnrolment e) {
  final days = e.weekdays;
  var anchor = _dateOnly(e.startDate);
  while (!days.contains(anchor.weekday)) {
    // Constructor arithmetic, not Duration: a day added across a DST
    // transition must stay a local midnight (v1 plan §7 stores plan dates).
    anchor = DateTime(anchor.year, anchor.month, anchor.day + 1);
  }
  final pickedDates = <DateTime>[];
  var d = anchor;
  while (pickedDates.length < template.totalSessions) {
    if (days.contains(d.weekday)) pickedDates.add(d);
    d = DateTime(d.year, d.month, d.day + 1);
  }
  final slots = <PlanSessionSlot>[];
  var k = 0;
  for (var w = 0; w < template.weeks.length; w++) {
    for (var i = 0; i < template.weeks[w].length; i++) {
      slots.add(
        PlanSessionSlot(
          week: w + 1,
          sessionIndex: i,
          date: pickedDates[k++],
          planSession: template.weeks[w][i],
        ),
      );
    }
  }
  return slots;
}

/// The auto-tick rule (v1 plan §7): when a run lands, tick "today's first
/// unticked session of that mode, else none". Yesterday's missed session is
/// never ticked by a later run; only a manual tick can mark it.
PlanSessionSlot? planTickForRun({
  required List<PlanSessionSlot> schedule,
  required List<PlanTick> ticks,
  required RunMode mode,
  required DateTime runLocalDate,
}) {
  final ticked = {for (final t in ticks) (t.week, t.sessionIndex)};
  final today = _dateOnly(runLocalDate);
  PlanSessionSlot? best;
  for (final slot in schedule) {
    if (slot.date != today || slot.planSession.mode != mode) continue;
    if (ticked.contains((slot.week, slot.sessionIndex))) continue;
    if (best == null ||
        slot.week < best.week ||
        (slot.week == best.week && slot.sessionIndex < best.sessionIndex)) {
      best = slot;
    }
  }
  return best;
}

/// One row of the week grid (design brief §4.10): sessions ticked out of
/// sessions planned. Empty rings are missed sessions, never red.
class PlanWeekAdherence {
  const PlanWeekAdherence({
    required this.week,
    required this.planned,
    required this.ticked,
  });

  final int week;
  final int planned;
  final int ticked;
}

/// Per-week adherence for the week grid. Ticks that name a session the
/// (current version of the) template no longer has are ignored.
List<PlanWeekAdherence> planAdherence(
  PlanTemplate template,
  List<PlanTick> ticks,
) {
  final counts = <int, int>{};
  for (final t in ticks) {
    if (t.week < 1 || t.week > template.weeks.length) continue;
    if (t.sessionIndex < 0 ||
        t.sessionIndex >= template.weeks[t.week - 1].length) {
      continue;
    }
    counts[t.week] = (counts[t.week] ?? 0) + 1;
  }
  return [
    for (var w = 1; w <= template.weeks.length; w++)
      PlanWeekAdherence(
        week: w,
        planned: template.weeks[w - 1].length,
        ticked: counts[w] ?? 0,
      ),
  ];
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dateString(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _parseDate(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (m == null) throw FormatException('bad date: $s');
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
  );
}
