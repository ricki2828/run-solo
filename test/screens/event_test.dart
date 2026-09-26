import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/event_names.dart';
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/app/services.dart';
import 'package:run_solo/screens/course_board_screen.dart';
import 'package:run_solo/screens/verdict_screen.dart';
import 'package:run_solo/state/courses.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// K1 app half on the verdict: course, official time, rank, board.
void main() {
  final day0 = DateTime.utc(2026, 8, 1, 22);
  DateTime week(int n) => day0.add(Duration(days: 7 * n));
  engine.RunFile event(int n, {double mps = 3.5, double shift = 0}) =>
      eventRunFile(
        n: n,
        start: week(n),
        eventName: kEventNames.parkrun,
        mps: mps,
        latShiftDeg: shift,
      );

  Future<AppServices> openVerdict(
    WidgetTester tester,
    List<engine.RunFile> files,
    String id, {
    Map<String, String> names = const {},
  }) async {
    final services = fakeServices(files: files, courseNames: names);
    await pumpApp(
      tester,
      services,
      pushRoute: Routes.verdict,
      pushArguments: id,
    );
    await pumpTimes(tester, 6);
    await tester.pump(const Duration(milliseconds: 1900));
    expect(find.byType(VerdictScreen), findsOneWidget);
    return services;
  }

  Future<void> tapRow(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find
          .descendant(
            of: find.byType(VerdictScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(f);
    await pumpTimes(tester, 2);
    await tester.pump(const Duration(milliseconds: 600)); // sheet in
  }

  testWidgets('first run: course row, official time row, board starts here', (
    tester,
  ) async {
    final a = event(1);
    await openVerdict(tester, [a], a.id);
    expect(find.byKey(const ValueKey('event-panel')), findsOneWidget);
    expect(find.text('Course 1'), findsOneWidget);
    expect(find.text('Enter official time'), findsOneWidget);
    expect(find.textContaining('The board starts here'), findsOneWidget);
    expect(find.byKey(const ValueKey('event-rank')), findsNothing);
  });

  testWidgets('official time: 20% off is refused with the reason, a good one '
      'saves and shows', (tester) async {
    final a = event(1);
    final services = await openVerdict(tester, [a], a.id);
    final gps = gpsFinishSeconds(
      (await services.history.load(a.id))!.analysis.intervals,
    )!;
    await tapRow(tester, 'event-official');
    await tester.enterText(
      find.byKey(const ValueKey('official-time')),
      '40:00',
    );
    await tester.tap(find.byKey(const ValueKey('official-save')));
    await pumpTimes(tester, 4);
    expect(find.textContaining('more than 20% off'), findsOneWidget);
    expect(
      (await services.history.load(a.id))!.sidecar.parkrun?.officialTimeSeconds,
      isNull,
    );
    final ok = (gps + 12).round();
    final text = '${ok ~/ 60}:${(ok % 60).toString().padLeft(2, '0')}';
    await tester.enterText(find.byKey(const ValueKey('official-time')), text);
    await tester.tap(find.byKey(const ValueKey('official-save')));
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      (await services.history.load(a.id))!.sidecar.parkrun?.officialTimeSeconds,
      ok,
    );
    expect(find.text('$text · Edit'), findsOneWidget);
  });

  testWidgets('course sheet: rename shows on the verdict; move to another '
      'course', (tester) async {
    final a = event(1);
    final b = event(2, shift: 0.002);
    final c = event(3);
    final services = await openVerdict(tester, [a, b, c], c.id);
    expect(find.text('Course 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('event-rank')), findsOneWidget);
    await tapRow(tester, 'event-course');
    await tester.enterText(
      find.byKey(const ValueKey('course-name')),
      'Albert Park',
    );
    await tester.tap(find.byKey(const ValueKey('course-save')));
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Albert Park'), findsOneWidget);

    await tapRow(tester, 'event-course');
    final other = engine.ParkrunCourses.newCourseId(b);
    await tester.tap(find.byKey(ValueKey('course-move-$other')));
    await pumpTimes(tester, 8);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      (await services.history.load(c.id))!.sidecar.parkrun?.courseId,
      other,
    );
    expect(find.text('Course 2'), findsOneWidget);
  });

  testWidgets('board: best, trend line, last 5 and the ranked table', (
    tester,
  ) async {
    final files = [for (var i = 1; i <= 5; i++) event(i, mps: 3.3 + 0.05 * i)];
    final services = fakeServices(files: files);
    final runs = await services.history.list();
    final course = runs.first.parkrun!.courseId!;
    await pumpApp(tester, services, home: CourseBoardScreen(courseId: course));
    await pumpTimes(tester, 6);
    expect(find.text('COURSE 1 · 5 RUNS'), findsOneWidget);
    expect(find.text('LAST 5'), findsOneWidget);
    expect(find.text('HEAT-ADJ'), findsOneWidget);
    expect(find.byKey(const ValueKey('board-trend')), findsOneWidget);
    final best = CourseBoard.fold(runs, course, now: services.now()).best!;
    expect(
      find.text(
        '${best.finishSeconds.round() ~/ 60}:'
        '${(best.finishSeconds.round() % 60).toString().padLeft(2, '0')}',
      ),
      findsWidgets,
    );
  });
}
