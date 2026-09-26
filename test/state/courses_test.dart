import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/state/courses.dart';
import 'package:run_solo/state/history_store.dart';

import '../run_fixtures.dart';

/// K1 app half: course tags after finalise/import, course names, official
/// time entry and the per-course board fold.
void main() {
  final day0 = DateTime.utc(2026, 8, 1, 22);
  DateTime week(int n) => day0.add(Duration(days: 7 * n));
  final name = kEventNames.parkrun;

  engine.RunFile event(
    int n, {
    double mps = 3.5,
    double shift = 0,
    bool indoor = false,
  }) => eventRunFile(
    n: n,
    start: week(n),
    eventName: name,
    mps: mps,
    latShiftDeg: shift,
    indoor: indoor,
  );

  group('course tags', () {
    test('oldest first: same start joins, 220 m away is a new course, no '
        'fix stays untagged', () {
      final runs = [
        event(3),
        event(1),
        event(2, shift: 0.002),
        event(4, indoor: true),
        freeRunFile(n: 5, start: week(5)),
      ];
      final tags = pendingCourseTags(runs, (_) => null);
      final first = engine.ParkrunCourses.newCourseId(runs[1]);
      final second = engine.ParkrunCourses.newCourseId(runs[2]);
      expect(tags, {
        eventRunId(1): first,
        eventRunId(3): first,
        eventRunId(2): second,
      });
    });

    test('a tagged run keeps its course and seeds the known starts', () {
      final a = event(1);
      final b = event(2);
      final tags = pendingCourseTags([
        a,
        b,
      ], (id) => id == a.id ? _withCourse(id, 'c-mine') : null);
      expect(tags, {b.id: 'c-mine'});
    });

    test('the transform never overwrites a course picked meanwhile', () {
      final picked = _withCourse('x', 'c-picked');
      expect(
        courseTagTransform('c-auto')(picked).parkrun?.courseId,
        'c-picked',
      );
    });

    test('list() tags once, keeps an official time, and keys the verdict by '
        'course', () async {
      final a = event(1);
      final store = MemoryRunStore(
        files: [a, event(2)],
        sidecars: {
          a.id: engine.RunSidecar(runId: a.id)
              .withParkrun(const engine.ParkrunInfo(officialTimeSeconds: 1430)),
        },
      );
      final runs = await store.list();
      final course = engine.ParkrunCourses.newCourseId(a);
      for (final r in runs) {
        expect(r.parkrun?.courseId, course);
        expect(r.analysis?.comparisonKey, 'parkrun:$course'); // event-name-ok
      }
      expect(
        runs.firstWhere((r) => r.id == a.id).parkrun?.officialTimeSeconds,
        1430,
      );
      final writes = store.written.length;
      await store.list();
      expect(
        store.written.length,
        writes,
        reason: 'tagged runs are never rewritten',
      );
    });
  });

  group('official time', () {
    test('parses mm:ss and h:mm:ss, refuses the rest', () {
      expect(parseFinishTime('23:20'), 1400);
      expect(parseFinishTime(' 23.20 '), 1400);
      expect(parseFinishTime('1:02:05'), 3725);
      for (final bad in ['', '23', '23:61', 'ab:cd', '0:00', '-1:00']) {
        expect(parseFinishTime(bad), isNull, reason: bad);
      }
    });

    test('the engine rule: 12:00 to 1:30:00 and within 20% of GPS', () {
      expect(officialTimeProblem(1400, 1400), isNull);
      expect(officialTimeProblem(1680, 1400), isNull); // +20%
      expect(officialTimeProblem(1681, 1400), contains('GPS time'));
      expect(officialTimeProblem(700, null), contains('12:00'));
      expect(officialTimeProblem(null, 1400), contains('23:20'));
      expect(officialTimeProblem(1400, null), isNull);
    });

    test(
      'setOfficialTime replaces the headline and keeps the course',
      () async {
        final a = event(1);
        final store = MemoryRunStore(files: [a]);
        await store.list();
        final gps = gpsFinishSeconds(
          (await store.load(a.id))!.analysis.intervals,
        )!;
        final official = (gps + 20).round();
        final d = await store.setOfficialTime(a.id, official);
        expect(d.sidecar.parkrun?.officialTimeSeconds, official);
        expect(d.sidecar.parkrun?.courseId, isNotNull);
        expect(d.analysis.intervals!.avgRepSeconds, closeTo(official, 0.01));
        expect(
          gpsFinishSeconds(d.analysis.intervals),
          closeTo(gps, 0.01),
          reason: 'the GPS finish is what the next entry is checked against',
        );
        final cleared = await store.setOfficialTime(a.id, null);
        expect(cleared.sidecar.parkrun?.officialTimeSeconds, isNull);
        expect(cleared.sidecar.parkrun?.courseId, isNotNull);
      },
    );

    test('setCourse moves a run and keeps its official time', () async {
      final a = event(1);
      final store = MemoryRunStore(files: [a]);
      await store.list();
      await store.setOfficialTime(a.id, 1430);
      final d = await store.setCourse(a.id, 'c-other');
      expect(d.sidecar.parkrun?.courseId, 'c-other');
      expect(d.sidecar.parkrun?.officialTimeSeconds, 1430);
    });
  });

  group('board', () {
    test('ranks fastest first, ties to the earlier date, marks official, '
        'last 5 newest first', () async {
      final files = [
        event(1, mps: 3.4),
        event(2, mps: 3.6),
        event(3, mps: 3.5),
        event(4, mps: 3.6),
        event(5, mps: 3.3),
        event(6, mps: 3.45),
        event(7, mps: 3.5, shift: 0.002), // another course
      ];
      final store = MemoryRunStore(files: files);
      final runs = await store.list();
      final course = runs
          .firstWhere((r) => r.id == eventRunId(1))
          .parkrun!
          .courseId!;
      final board = CourseBoard.fold(runs, course, now: week(7));
      expect(board.ranked, hasLength(6));
      expect(
        board.ranked.first.run.id,
        eventRunId(2),
        reason: 'tie: earlier date',
      );
      expect(board.ranked[1].run.id, eventRunId(4));
      expect(board.ranked.last.run.id, eventRunId(5));
      expect(board.last5.map((e) => e.run.id), [
        eventRunId(6),
        eventRunId(5),
        eventRunId(4),
        eventRunId(3),
        eventRunId(2),
      ]);
      expect(board.rankOf(eventRunId(7)), isNull);
      expect(board.ranked.any((e) => e.official), isFalse);

      final gps = board.ranked.last.finishSeconds;
      await store.setOfficialTime(eventRunId(5), (gps - 30).round());
      final again = CourseBoard.fold(await store.list(), course, now: week(7));
      final e5 = again.ranked.firstWhere((e) => e.run.id == eventRunId(5));
      expect(e5.official, isTrue);
      expect(e5.finishSeconds, closeTo(gps - 30, 1));
    });

    test('trend needs 4 runs in 90 days; quicker runs slope down', () async {
      final store = MemoryRunStore(
        files: [for (var i = 1; i <= 5; i++) event(i, mps: 3.3 + 0.05 * i)],
      );
      final runs = await store.list();
      final course = runs.first.parkrun!.courseId!;
      expect(
        CourseBoard.fold(runs, course, now: week(40)).trendSecPerMonth,
        isNull,
        reason: 'all older than 90 days',
      );
      final t = CourseBoard.fold(runs, course, now: week(6)).trendSecPerMonth;
      expect(t, isNotNull);
      expect(t!, lessThan(0));
    });
  });

  group('names', () {
    test('default labels follow each course\'s first run; names win', () async {
      final store = MemoryRunStore(
        files: [event(1), event(2, shift: 0.002), event(3)],
      );
      final runs = await store.list();
      final names = CourseNamesController(MemoryCourseNamesStore());
      final labels = CourseLabels(runs, names);
      final c1 = runs
          .firstWhere((r) => r.id == eventRunId(1))
          .parkrun!
          .courseId!;
      final c2 = runs
          .firstWhere((r) => r.id == eventRunId(2))
          .parkrun!
          .courseId!;
      expect(labels.courseIds, [c1, c2]);
      expect(labels.labelOf(c1), 'Course 1');
      expect(labels.labelOf(c2), 'Course 2');
      await names.rename(c2, '  Albert Park  ');
      expect(CourseLabels(runs, names).labelOf(c2), 'Albert Park');
      await names.rename(c2, ' ');
      expect(CourseLabels(runs, names).labelOf(c2), 'Course 2');
    });

    test('file round trip; a damaged file is no names', () async {
      final dir = Directory.systemTemp.createTempSync('courses');
      addTearDown(() => dir.deleteSync(recursive: true));
      final c = CourseNamesController(FileCourseNamesStore(dir));
      await c.load();
      await c.rename('c-1', 'Albert Park');
      final again = CourseNamesController(FileCourseNamesStore(dir));
      await again.load();
      expect(again.nameOf('c-1'), 'Albert Park');
      File('${dir.path}/courses.json').writeAsStringSync('{nope');
      final damaged = CourseNamesController(FileCourseNamesStore(dir));
      await damaged.load();
      expect(damaged.nameOf('c-1'), isNull);
    });
  });

  group('file store (W5b index)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('courses-w5b'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('import tags once, the index keys by course, a later list decodes '
        'nothing, and the board folds from index rows', () async {
      final runsDir = Directory('${dir.path}/runs');
      final store = FileRunStore(runsDir);
      // Run 2 starts ~100 m north of run 1 (0.0009° lat): same course.
      final files = [
        event(1, mps: 3.4),
        event(2, mps: 3.6, shift: 0.0009),
        event(3),
      ];
      await store.importBundles([
        for (final f in files) engine.RunBundle(run: f),
      ]);
      final runs = await store.list();
      final course = engine.ParkrunCourses.newCourseId(files.first);
      for (final r in runs) {
        expect(r.comparisonKey, 'parkrun:$course'); // event-name-ok
        expect(courseIdOf(r), course);
      }
      expect(store.decoded, hasLength(3), reason: 'each file decoded once');
      await store.derivedIdle;
      store.decoded.clear();
      final again = await store.list();
      expect(store.decoded, isEmpty, reason: 'tagged: nothing to decode');
      final board = CourseBoard.fold(again, course, now: week(4));
      expect(board.ranked, hasLength(3));
      expect(board.best!.run.id, files[1].id);

      final d = await store.setOfficialTime(files[0].id, 1400);
      expect(d.sidecar.parkrun?.courseId, course);
      final after = CourseBoard.fold(await store.list(), course, now: week(4));
      final e = after.ranked.firstWhere((x) => x.run.id == files[0].id);
      expect(e.official, isTrue);
      expect(e.finishSeconds, closeTo(1400, 0.5));
    });

    test('an event run with no fix is marked "no course (no fix)" and not '
        're-read on every list, until its sidecar changes', () async {
      final runsDir = Directory('${dir.path}/runs');
      final store = FileRunStore(runsDir);
      final indoor = event(1, indoor: true);
      await store.importBundles([engine.RunBundle(run: indoor)]);
      final first = await store.list();
      expect(courseIdOf(first.single), isNull);
      expect((await store.readIndex()).entries[indoor.id]!.courseNoFix, isTrue);
      await store.derivedIdle;
      store.decoded.clear();
      await store.list();
      await store.list();
      expect(store.decoded, isEmpty, reason: 'no fix: never decoded again');

      // A sidecar change rebuilds the entry once, still with no course.
      await store.setOfficialTime(indoor.id, 1400);
      await store.list();
      await store.derivedIdle;
      store.decoded.clear();
      await store.list();
      expect(store.decoded, isEmpty);
      expect((await store.readIndex()).entries[indoor.id]!.courseNoFix, isTrue);

      // A second event run with a fix still tags; the indoor one stays out.
      await store.importBundles([engine.RunBundle(run: event(2))]);
      final runs = await store.list();
      expect(
        courseIdOf(runs.firstWhere((r) => r.id == eventRunId(2))),
        isNotNull,
      );
      expect(courseIdOf(runs.firstWhere((r) => r.id == indoor.id)), isNull);
      final index = await store.readIndex();
      expect(index.entries[eventRunId(2)]!.courseNoFix, isFalse);
    });

    test('an index entry from before the no-fix mark is rebuilt once to '
        'carry it', () async {
      final runsDir = Directory('${dir.path}/runs');
      final store = FileRunStore(runsDir);
      final indoor = event(1, indoor: true);
      await store.importBundles([engine.RunBundle(run: indoor)]);
      await store.list();
      await store.derivedIdle;
      final f = store.indexFile;
      f.writeAsStringSync(
        f.readAsStringSync().replaceAll('"course_no_fix":true,', ''),
      );
      expect(
        (await store.readIndex()).entries[indoor.id]!.courseNoFix,
        isFalse,
      );
      store.decoded.clear();
      await store.list();
      expect(store.decoded, hasLength(1), reason: 'one decode to mark it');
      expect((await store.readIndex()).entries[indoor.id]!.courseNoFix, isTrue);
      await store.derivedIdle;
      store.decoded.clear();
      await store.list();
      expect(store.decoded, isEmpty);
    });
  });
}

engine.RunSidecar _withCourse(String id, String course) =>
    engine.RunSidecar(runId: id)
        .withParkrun(engine.ParkrunInfo(courseId: course));
