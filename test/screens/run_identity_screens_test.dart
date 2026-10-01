import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/history_screen.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/widgets/recent_activity.dart';
import 'package:run_solo/widgets/weather_chip.dart';
import 'package:run_solo/widgets/where_when_line.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Run identity on screen: title + place + date on Home's cards, History
/// rows and run detail; work pace on interval cards; no empty route box and
/// no stale "fetching" weather line.
void main() {
  final start = DateTime(2026, 9, 24, 6).toUtc();

  /// The where/when line showing exactly [text].
  Finder whereWhenLine(String text) => find.byWidgetPredicate(
    (w) =>
        w is WhereWhenLine &&
        whereWhen(
              w.place,
              w.start,
              utcOffsetMin: w.utcOffsetMin,
              street: w.street,
            ) ==
            text,
  );

  RunSummary row({
    String id = 'a',
    RecordMode mode = RecordMode.intervals,
    String? place = 'Albert Park',
    String? street,
    String? title,
    double? work = 262,
  }) => RunSummary(
    id: id,
    mode: mode,
    start: start,
    durationMs: 40 * 60 * 1000,
    distanceM: 6000,
    laps: 8,
    place: place,
    street: street,
    customTitle: title,
    row: IndexRow(
      lapCount: 8,
      workPaceSecPerKm: work,
      place: place,
      street: street,
      title: title,
    ),
  );

  Future<void> pumpCards(WidgetTester tester, List<RunSummary> runs) => pumpApp(
    tester,
    fakeServices(runs: runs),
    home: Scaffold(
      body: SingleChildScrollView(
        child: RecentActivity(runs: runs, units: Units.km, now: now()),
      ),
    ),
  );

  testWidgets('card: title, then place · day · time, then the stats', (
    tester,
  ) async {
    await pumpCards(tester, [row()]);
    expect(whereWhenLine('Albert Park · Thu 24 Sep · 6:00'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == 'Early Norwegian 4x4',
      ),
      findsOneWidget,
    );
    expect(find.text('4X4'), findsNothing);
  });

  testWidgets('card: street and area, and a long street keeps the date', (
    tester,
  ) async {
    await pumpCards(tester, [
      row(street: 'Lakeside Dr'),
      row(
        id: 'b',
        street: 'Avenida Presidente Juscelino Kubitschek de Oliveira Longname',
      ),
    ]);
    expect(
      whereWhenLine('Lakeside Dr, Albert Park · Thu 24 Sep · 6:00'),
      findsOneWidget,
    );
    // The long street ellipsizes; the day and time are still all there.
    expect(find.text(' · Thu 24 Sep · 6:00'), findsNWidgets(2));
    final lines = find.byKey(const ValueKey('activity-where-when'));
    for (final e in lines.evaluate()) {
      final box = tester.getRect(find.byWidget(e.widget));
      final when = tester.getRect(
        find.descendant(
          of: find.byWidget(e.widget),
          matching: find.text(' · Thu 24 Sep · 6:00'),
        ),
      );
      expect(when.right, lessThanOrEqualTo(box.right));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('card: no place known, no placeholder and no coordinate', (
    tester,
  ) async {
    await pumpCards(tester, [row(place: null)]);
    expect(whereWhenLine('Thu 24 Sep · 6:00'), findsOneWidget);
    expect(find.text('Thu 24 Sep · 6:00'), findsOneWidget);
    expect(find.textContaining('Albert'), findsNothing);
  });

  testWidgets('card: an interval run shows work pace, a free run avg pace', (
    tester,
  ) async {
    await pumpCards(tester, [row()]);
    expect(find.text('WORK PACE'), findsOneWidget);
    expect(find.text('AVG PACE'), findsNothing);
    expect(find.text('4:22/km', findRichText: true), findsOneWidget);
    await pumpCards(tester, [row(id: 'f', mode: RecordMode.free)]);
    expect(find.text('AVG PACE'), findsOneWidget);
    expect(find.text('WORK PACE'), findsNothing);
  });

  testWidgets('card: the runner\'s own title replaces the automatic one', (
    tester,
  ) async {
    await pumpCards(tester, [row(title: 'Hill day')]);
    expect(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == 'Hill day',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Norwegian'), findsNothing);
  });

  testWidgets('card: a 12-minute test says VO2 est. and 12-minute test', (
    tester,
  ) async {
    final r = RunSummary(
      id: 'c',
      mode: RecordMode.cooper,
      start: start,
      durationMs: 19 * 60 * 1000,
      distanceM: 3000,
      laps: 0,
      row: const IndexRow(
        lapCount: 0,
        cooper: CooperFigures(valid: true, testDistanceM: 2800, vo2: 48.2),
      ),
    );
    await pumpCards(tester, [r]);
    expect(find.text('48.2 VO2 est.'), findsOneWidget);
    expect(find.byTooltip('12-minute test info'), findsOneWidget);
  });

  group('History from a FileRunStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runsolo-hid-'));
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('rows show the title, place and date from the index', (
      tester,
    ) async {
      final r = freeRunFile(n: 1, start: start);
      final store = FileRunStore(Directory('${dir.path}/runs'));
      await tester.runAsync(() async {
        await store.importBundles([engine.RunBundle(run: r)]);
        await store.setPlace(r.id, 'Albert Park');
        await store.setTitle(r.id, 'Sunday easy');
        await store.list();
        await store.derivedIdle;
      });
      await pumpApp(
        tester,
        fakeServices(history: store),
        home: const HistoryScreen(),
      );
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('history-view-1')));
      await pumpTimes(tester);
      expect(find.byType(HistoryRow), findsOneWidget);
      expect(find.text('Sunday easy'), findsOneWidget);
      expect(whereWhenLine(whereWhen('Albert Park', start)), findsOneWidget);
      await tester.runAsync(() => store.derivedIdle);
    });
  });

  group('run detail', () {
    testWidgets('indoor: no empty route box and no placeholder', (
      tester,
    ) async {
      final r = fourByFourFile(
        n: 2,
        start: DateTime.utc(2026, 9, 10, 6),
        indoor: true,
      );
      await pumpApp(
        tester,
        fakeServices(files: [r]),
        home: RunDetailScreen(runId: r.id),
      );
      await pumpTimes(tester, 6);
      expect(find.text('Indoor run, no route'), findsNothing);
      expect(find.byKey(const ValueKey('fake-map')), findsNothing);
      expect(find.textContaining('fetching'), findsNothing);
      expect(find.byKey(const ValueKey('detail-title')), findsOneWidget);
    });

    testWidgets('header: title, place and date; rename keeps it', (
      tester,
    ) async {
      final r = freeRunFile(n: 3, start: start);
      final places = FakePlaceGateway(name: 'Albert Park');
      final services = fakeServices(files: [r], places: places);
      await pumpApp(tester, services, home: RunDetailScreen(runId: r.id));
      await pumpTimes(tester, 6);
      // An old run with no place: named lazily when the detail opens.
      expect(whereWhenLine(whereWhen('Albert Park', start)), findsOneWidget);
      expect(places.calls, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('rename-run')));
      await pumpTimes(tester, 4);
      await tester.enterText(
        find.byKey(const ValueKey('rename-field')),
        'Sunday easy',
      );
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await pumpTimes(tester, 6);
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('detail-title')),
      );
      expect(title.textSpan!.toPlainText(), 'Sunday easy');
      expect((await services.history.load(r.id))!.sidecar.title, 'Sunday easy');
    });

    test('weather: "fetching" only while a fetch can still be in flight', () {
      const pending = WeatherChipView(
        state: WeatherChipState.pending,
        note: kWeatherPending,
      );
      final end = DateTime.utc(2026, 9, 24, 7);
      expect(
        detailWeatherChip(
          pending,
          runEnd: end,
          now: end.add(const Duration(minutes: 5)),
        ),
        isNotNull,
      );
      expect(
        detailWeatherChip(
          pending,
          runEnd: end,
          now: end.add(const Duration(days: 8)),
        ),
        isNull,
      );
      const failed = WeatherChipView(
        state: WeatherChipState.unavailable,
        note: kWeatherUnavailable,
      );
      expect(
        detailWeatherChip(
          failed,
          runEnd: end,
          now: end.add(const Duration(days: 8)),
        ),
        isNotNull,
      );
    });
  });
}
