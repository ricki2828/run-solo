import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/share/share_card.dart';
import 'package:run_solo/share/share_card_sheet.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/state/run_index.dart';
import 'package:run_solo/state/settings.dart';

import '../helpers.dart';

RunSummary freeRun({double? truePace = 310, String? title}) => RunSummary(
  id: 'r1',
  mode: RecordMode.free,
  start: DateTime(2026, 9, 12, 7),
  durationMs: 1550000,
  distanceM: 5000,
  laps: 0,
  customTitle: title,
  place: 'Albert Park',
  street: 'Queens Road',
  startPoint: (lat: -37.84, lon: 144.97),
  row: IndexRow(lapCount: 0, truePaceSecPerKm: truePace),
);

List<GeoPoint> loop() => [
  for (var i = 0; i <= 60; i++)
    GeoPoint(
      -37.84 + 0.004 * (i / 60) * (i.isEven ? 1 : 1.05),
      144.97 + 0.006 * (1 - (i - 30).abs() / 30),
    ),
];

void main() {
  test('shared moment detail carries no day or month', () {
    expect(shareSafeMomentDetail('28:12 on Sunday, run 5.'), '28:12, run 5.');
    expect(
      shareSafeMomentDetail('1:14 faster than September.'),
      '1:14 faster.',
    );
    expect(
      shareSafeMomentDetail('Up from 12 a month ago.'),
      'Up from 12 a month ago.',
    );
  });

  testWidgets('scores card: pack hero says a band only, none unless given', (
    tester,
  ) async {
    const lanes = [
      ScoreLaneData(label: 'MID', value: '71', unit: 'st percentile'),
    ];
    for (final (data, want) in [
      (
        const ScoresCardData(
          lanes: lanes,
          pack: PackShareData(fasterThanInTen: 6, band: 'men 40-49'),
        ),
        ['FASTER THAN 6 IN 10', 'men 40-49, from published norms.'],
      ),
      (const ScoresCardData(lanes: lanes), ['MY FOUR SCORES']),
    ]) {
      await pumpApp(
        tester,
        fakeServices(),
        home: Scaffold(
          body: Center(child: ShareCard(data: data)),
        ),
      );
      await pumpTimes(tester, 2);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('share-pack-hero')), findsOneWidget);
      for (final w in want) {
        expect(find.text(w), findsOneWidget);
      }
      expect(
        find.textContaining('men '),
        data.pack == null ? findsNothing : findsOneWidget,
      );
    }
  });

  group('pack share', () {
    PackStanding standing(String band, int percentile) => PackStanding(
      band: band,
      lane: engine.IdentityLane.mid,
      percentile: percentile,
      histogram: const [0.2, 0.5, 1],
      youBin: 1,
    );

    test('a band only: faster than N in 10 and the age band', () {
      final d = packShareData(standing('M40-49', 63))!;
      expect(d.fasterThanInTen, 6);
      expect(d.band, 'men 40-49');
      expect(packShareData(standing('F30-39', 100))!.fasterThanInTen, 9);
      expect(packShareData(standing('F30-39', 88))!.band, 'women 30-39');
    });

    test('nothing to share without a pack or under 1 in 10', () {
      expect(packShareData(null), isNull);
      expect(packShareData(standing('M40-49', 7)), isNull);
      expect(packShareData(standing('weird', 60)), isNull);
    });
  });

  group('card data', () {
    test('a run: title, distance, time, true pace; no place anywhere', () {
      final d = runCardData(freeRun(title: 'Sunday long one'), Units.km);
      expect(d.title, 'Sunday long one');
      expect(d.distance, '5.00 km');
      expect(d.time, '25:50');
      expect(d.truePace, '5:10/km');
      expect(d.date, 'Sat 12 Sep');
      expect(d.hasRoute, isFalse);
      final everything = [
        d.title,
        d.typeName,
        d.date,
        d.distance,
        d.time,
        d.truePace,
        d.verdict,
      ].join(' ');
      expect(everything, isNot(contains('Albert')));
      expect(everything, isNot(contains('Queens')));
    });

    test('no true pace when the run has none', () {
      expect(runCardData(freeRun(truePace: null), Units.km).truePace, isNull);
    });

    test('scores: a lane not earned is left off, never printed as --', () {
      final d = scoresCardData(
        {
          engine.IdentityLane.mid: engine.IdentityScore(
            lane: engine.IdentityLane.mid,
            score: 62,
            vdot: 45,
            runId: 'a',
            date: DateTime(2026, 9, 12),
            source: '5K',
            boardKey: null,
            changeVs6Weeks: 2,
          ),
        },
        sex: ProfileSex.male,
        age: 40,
      );
      expect(d.lanes.map((l) => l.label), ['MID']);
      expect(d.lanes.any((l) => l.value == '--'), isFalse);
      expect(d.lanes.first.unit, endsWith('percentile'));
    });

    test('scores without a profile fall back to the score, labelled', () {
      final d = scoresCardData(
        {
          engine.IdentityLane.mid: engine.IdentityScore(
            lane: engine.IdentityLane.mid,
            score: 62,
            vdot: 45,
            runId: 'a',
            date: DateTime(2026, 9, 12),
            source: '5K',
            boardKey: null,
          ),
        },
        sex: ProfileSex.notSet,
        age: null,
      );
      expect(d.lanes.first.value, '62');
      expect(d.lanes.first.unit, 'score');
    });
  });

  group('sheet', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('runsolo-share-'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<FakeTransferGateway> open(
      WidgetTester tester,
      ShareCardData data, {
      List<GeoPoint> route = const [],
    }) async {
      final transfer = FakeTransferGateway();
      await pumpApp(
        tester,
        fakeServices(transfer: transfer),
        home: Scaffold(
          body: ShareCardSheet(
            data: data,
            route: route,
            tempDir: () async => dir,
          ),
        ),
      );
      await pumpTimes(tester, 2);
      return transfer;
    }

    testWidgets('map is off by default and only offered with a route', (
      tester,
    ) async {
      await open(tester, runCardData(freeRun(), Units.km));
      expect(find.byKey(const ValueKey('share-show-map')), findsNothing);
      await open(tester, runCardData(freeRun(), Units.km), route: loop());
      expect(find.byKey(const ValueKey('share-show-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('share-route')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('share-show-map')));
      await pumpTimes(tester, 2);
      expect(find.byKey(const ValueKey('share-route')), findsOneWidget);
    });

    testWidgets('SHARE renders a 1080 x 1350 PNG and hands it to the sheet', (
      tester,
    ) async {
      final transfer = await open(tester, runCardData(freeRun(), Units.km));
      final shared = transfer.nextShare();
      await tester.tap(find.byKey(const ValueKey('share-card-go')));
      await tester.pump();
      // toImage and the file write finish on real time; their continuations
      // run in the test's fake zone, so alternate real waits with pumps.
      var done = false;
      List<String>? paths;
      shared.then((p) {
        done = true;
        paths = p;
      });
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(paths, hasLength(1));
      expect(transfer.sharedMimeTypes.single, 'image/png');
      final bytes = File(paths!.single).readAsBytesSync();
      expect(bytes.sublist(1, 4), [0x50, 0x4e, 0x47]);
      final data = ByteData.sublistView(bytes);
      expect(data.getUint32(16), 1080);
      expect(data.getUint32(20), 1350);
      await tester.pump(const Duration(milliseconds: 50));
    });
  });
}
