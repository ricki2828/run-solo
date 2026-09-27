import 'package:run_engine/run_engine.dart';
import 'package:test/test.dart';

/// v1 plan §7 / design brief §4.10: plan templates, enrolment, schedule
/// placement, the auto-tick rule, and the week-grid adherence counts.
void main() {
  // 2026-09-28 is a Monday.
  final monday = DateTime(2026, 9, 28);

  PlanSession f4(int reps, int rec) =>
      PlanSession.fourByFour(reps: reps, recoverySeconds: rec);

  PlanTemplate template(List<List<PlanSession>> weeks) => PlanTemplate(
    id: 'test-plan',
    version: 1,
    name: 'Test plan',
    oneLiner: 'for tests',
    weeks: weeks,
  );

  group('PlanSession', () {
    test('fourByFour is an intervals session with a spec', () {
      final s = f4(3, 210);
      expect(s.mode, RunMode.intervals);
      expect(s.label, '4x4 · 3 reps');
      final spec = s.toSessionSpec()!;
      expect(spec.templateId, SessionSpec.norwegian4x4Id);
      expect(spec.repCount, 3);
      expect(spec.steps.first.value, 240);
      expect(spec.steps.firstWhere((st) => !st.isWork).value, 210);
    });

    test('easy is a free session with no spec', () {
      const s = PlanSession.easy(30);
      expect(s.mode, RunMode.free);
      expect(s.label, 'Easy · 30 min');
      expect(s.toSessionSpec(), isNull);
    });

    test('json roundtrip', () {
      for (final s in [f4(4, 180), const PlanSession.easy(45)]) {
        final back = PlanSession.fromJson(s.toJson());
        expect(back.kind, s.kind);
        expect(back.reps, s.reps);
        expect(back.recoverySeconds, s.recoverySeconds);
        expect(back.minutes, s.minutes);
      }
    });

    test('bad shapes are refused', () {
      expect(
        () => PlanSession.fromJson({'kind': 'tempo'}),
        throwsFormatException,
      );
      expect(
        () => PlanSession.fromJson({'kind': 'fourByFour', 'reps': 0}),
        throwsFormatException,
      );
      expect(
        () => PlanSession.fromJson({'kind': 'easy'}),
        throwsFormatException,
      );
    });
  });

  group('PlanTemplate codec', () {
    test('roundtrip', () {
      final t = template([
        [f4(3, 210), const PlanSession.easy(30)],
        [f4(4, 180), const PlanSession.easy(35)],
      ]);
      final back = PlanTemplate.fromJson(t.toJson());
      expect(back.id, 'test-plan');
      expect(back.weekCount, 2);
      expect(back.totalSessions, 4);
      expect(back.weeks[1][0].reps, 4);
    });

    test('bad shapes are refused', () {
      expect(() => PlanTemplate.fromJson({}), throwsFormatException);
      expect(
        () => PlanTemplate.fromJson({
          'id': 'x',
          'version': 1,
          'name': 'X',
          'weeks': [],
        }),
        throwsFormatException,
      );
    });
  });

  group('PlanEnrolment', () {
    test('weekdays are sorted and deduped', () {
      final e = PlanEnrolment(
        templateId: 't',
        templateVersion: 1,
        weekdays: [DateTime.saturday, DateTime.tuesday, DateTime.tuesday],
        startDate: monday,
        tzOffsetMinutes: 480,
      );
      expect(e.weekdays, [DateTime.tuesday, DateTime.saturday]);
    });

    test('empty or out-of-range weekdays are refused', () {
      expect(
        () => PlanEnrolment(
          templateId: 't',
          templateVersion: 1,
          weekdays: const [],
          startDate: monday,
          tzOffsetMinutes: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => PlanEnrolment(
          templateId: 't',
          templateVersion: 1,
          weekdays: const [8],
          startDate: monday,
          tzOffsetMinutes: 0,
        ),
        throwsFormatException,
      );
    });

    test('json roundtrip with reminder', () {
      final e = PlanEnrolment(
        templateId: 'norwegian-4x4-8wk',
        templateVersion: 1,
        weekdays: PlanEnrolment.defaultWeekdays,
        startDate: monday,
        tzOffsetMinutes: 480,
        reminderMinutesOfDay: 7 * 60,
      );
      final back = PlanEnrolment.fromJson(e.toJson());
      expect(back.templateId, 'norwegian-4x4-8wk');
      expect(back.weekdays, PlanEnrolment.defaultWeekdays);
      expect(back.startDate, monday);
      expect(back.tzOffsetMinutes, 480);
      expect(back.reminderMinutesOfDay, 420);
    });

    test('default pick is Tue/Thu/Sat', () {
      expect(PlanEnrolment.defaultWeekdays, [
        DateTime.tuesday,
        DateTime.thursday,
        DateTime.saturday,
      ]);
    });
  });

  group('planSchedule', () {
    final t = template([
      [f4(3, 210), const PlanSession.easy(30), f4(3, 210)],
      [f4(4, 195), const PlanSession.easy(35), f4(4, 195)],
    ]);

    PlanEnrolment enrol(List<int> days) => PlanEnrolment(
      templateId: 'test-plan',
      templateVersion: 1,
      weekdays: days,
      startDate: monday,
      tzOffsetMinutes: 480,
    );

    test('sessions land on the picked weekdays in order', () {
      final slots = planSchedule(t, enrol(PlanEnrolment.defaultWeekdays));
      expect(slots, hasLength(6));
      // Week 1: Tue 29 Sep, Thu 1 Oct, Sat 3 Oct.
      expect(slots[0].date, DateTime(2026, 9, 29));
      expect(slots[0].week, 1);
      expect(slots[0].sessionIndex, 0);
      expect(slots[1].date, DateTime(2026, 10, 1));
      expect(slots[2].date, DateTime(2026, 10, 3));
      // Week 2 starts the next Tuesday.
      expect(slots[3].date, DateTime(2026, 10, 6));
      expect(slots[3].week, 2);
      expect(slots[5].date, DateTime(2026, 10, 10));
    });

    test('starting on a picked day anchors there', () {
      final slots = planSchedule(
        t,
        PlanEnrolment(
          templateId: 'test-plan',
          templateVersion: 1,
          weekdays: const [DateTime.monday],
          startDate: monday,
          tzOffsetMinutes: 0,
        ),
      );
      expect(slots[0].date, monday);
    });

    test('fewer picked days than sessions: extras roll forward', () {
      final slots = planSchedule(
        t,
        enrol(const [DateTime.tuesday, DateTime.thursday]),
      );
      // Week 1 keeps ownership of its third session even though it lands
      // on the next picked day (the calendar week after).
      expect(slots[0].date, DateTime(2026, 9, 29));
      expect(slots[1].date, DateTime(2026, 10, 1));
      expect(slots[2].week, 1);
      expect(slots[2].date, DateTime(2026, 10, 6));
      expect(slots[3].week, 2);
      expect(slots[3].date, DateTime(2026, 10, 8));
    });
  });

  group('planTickForRun', () {
    // Week 1: 4x4 Tue 29 Sep, 4x4 Wed 30 Sep, easy Tue 6 Oct (the easy
    // rolls onto the next picked day because only two days were picked).
    final t = template([
      [f4(3, 210), f4(3, 210), const PlanSession.easy(30)],
    ]);
    final slots = planSchedule(
      t,
      PlanEnrolment(
        templateId: 'test-plan',
        templateVersion: 1,
        weekdays: const [DateTime.tuesday, DateTime.wednesday],
        startDate: monday,
        tzOffsetMinutes: 0,
      ),
    );
    final tuesday = DateTime(2026, 9, 29);
    final wednesday = DateTime(2026, 9, 30);
    final easyDay = DateTime(2026, 10, 6);

    PlanTick tick(PlanSessionSlot s, {String? runId, bool manual = false}) =>
        PlanTick(
          week: s.week,
          sessionIndex: s.sessionIndex,
          runId: runId,
          manual: manual,
          tickedAt: tuesday.add(const Duration(hours: 9)),
        );

    test('slots land where the group doc says', () {
      expect(slots[0].date, tuesday);
      expect(slots[0].planSession.mode, RunMode.intervals);
      expect(slots[1].date, wednesday);
      expect(slots[2].date, easyDay);
      expect(slots[2].planSession.mode, RunMode.free);
    });

    test("ticks today's first unticked session of that mode", () {
      final hit = planTickForRun(
        schedule: slots,
        ticks: const [],
        mode: RunMode.intervals,
        runLocalDate: tuesday.add(const Duration(hours: 18)),
      );
      expect(hit!.week, 1);
      expect(hit.sessionIndex, 0);
    });

    test('the next matching run takes the next unticked session', () {
      final first = slots[0];
      final second = planTickForRun(
        schedule: slots,
        ticks: [tick(first, runId: 'run-1')],
        mode: RunMode.intervals,
        runLocalDate: wednesday,
      )!;
      expect(second.sessionIndex, 1);
      final third = planTickForRun(
        schedule: slots,
        ticks: [
          tick(first, runId: 'run-1'),
          tick(second, runId: 'run-2'),
        ],
        mode: RunMode.intervals,
        runLocalDate: wednesday,
      );
      expect(third, isNull);
    });

    test('mode must match: an easy run never ticks a 4x4', () {
      final hit = planTickForRun(
        schedule: slots,
        ticks: const [],
        mode: RunMode.free,
        runLocalDate: tuesday,
      );
      expect(hit, isNull);
      final easy = planTickForRun(
        schedule: slots,
        ticks: const [],
        mode: RunMode.free,
        runLocalDate: easyDay,
      );
      expect(easy!.sessionIndex, 2);
    });

    test('nothing today means no tick', () {
      final hit = planTickForRun(
        schedule: slots,
        ticks: const [],
        mode: RunMode.intervals,
        runLocalDate: DateTime(2026, 10, 2),
      );
      expect(hit, isNull);
    });

    test('a missed session stays unticked by a later run', () {
      // Running intervals on the easy day does not rescue the missed
      // Wednesday 4x4; only a manual tick can mark it.
      final hit = planTickForRun(
        schedule: slots,
        ticks: const [],
        mode: RunMode.intervals,
        runLocalDate: easyDay,
      );
      expect(hit, isNull);
    });

    test('manual ticks count as ticked', () {
      final hit = planTickForRun(
        schedule: slots,
        ticks: [tick(slots[0], manual: true)],
        mode: RunMode.intervals,
        runLocalDate: tuesday,
      );
      expect(hit, isNull);
    });
  });

  group('planAdherence', () {
    test('counts ticks per week and ignores stray ticks', () {
      final t = template([
        [f4(3, 210), const PlanSession.easy(30)],
        [f4(4, 180), const PlanSession.easy(35)],
      ]);
      final ticks = [
        PlanTick(
          week: 1,
          sessionIndex: 0,
          runId: 'r1',
          manual: false,
          tickedAt: monday,
        ),
        PlanTick(
          week: 2,
          sessionIndex: 1,
          runId: null,
          manual: true,
          tickedAt: monday,
        ),
        // Out of range for this template: ignored.
        PlanTick(
          week: 3,
          sessionIndex: 0,
          runId: 'r2',
          manual: false,
          tickedAt: monday,
        ),
        PlanTick(
          week: 1,
          sessionIndex: 5,
          runId: 'r3',
          manual: false,
          tickedAt: monday,
        ),
      ];
      final grid = planAdherence(t, ticks);
      expect(grid, hasLength(2));
      expect(grid[0].planned, 2);
      expect(grid[0].ticked, 1);
      expect(grid[1].planned, 2);
      expect(grid[1].ticked, 1);
    });
  });

  group('PlanState codec', () {
    test('roundtrip with enrolment and ticks', () {
      final state = PlanState(
        enrolment: PlanEnrolment(
          templateId: 'base-4wk',
          templateVersion: 1,
          weekdays: PlanEnrolment.defaultWeekdays,
          startDate: monday,
          tzOffsetMinutes: 480,
        ),
        ticks: [
          PlanTick(
            week: 1,
            sessionIndex: 0,
            runId: 'run-9',
            manual: false,
            tickedAt: monday.add(const Duration(hours: 8)),
          ),
        ],
      );
      final back = PlanState.fromJson(state.toJson());
      expect(back.enrolment!.templateId, 'base-4wk');
      expect(back.ticks, hasLength(1));
      expect(back.ticks.single.runId, 'run-9');
    });

    test('empty state roundtrips', () {
      final back = PlanState.fromJson(const PlanState().toJson());
      expect(back.enrolment, isNull);
      expect(back.ticks, isEmpty);
    });

    test('a newer schema is refused', () {
      expect(
        () => PlanState.fromJson({'schema': 2, 'ticks': []}),
        throwsFormatException,
      );
    });
  });
}
