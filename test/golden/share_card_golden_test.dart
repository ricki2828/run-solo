import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/route_builder.dart';
import 'package:run_solo/share/share_card.dart';
import 'package:run_solo/theme/theme.dart';

import '../helpers.dart';

/// The share card itself, at its real 360 x 450 layout size (captured at 3x).
void main() {
  const route = [
    GeoPoint(0, 0),
    GeoPoint(0.002, 0.001),
    GeoPoint(0.004, 0.005),
    GeoPoint(0.002, 0.009),
    GeoPoint(-0.001, 0.008),
    GeoPoint(-0.002, 0.004),
    GeoPoint(0, 0),
  ];
  final cards = <String, ShareCardData>{
    'run': const RunCardData(
      title: 'Morning Free',
      typeName: 'FREE',
      colour: AuroraRunType.free,
      date: 'Sat 12 Sep',
      distance: '5.00 km',
      time: '25:50',
      truePace: '5:10/km',
    ),
    'run_verdict_map': const RunCardData(
      title: 'Morning 4x4',
      typeName: 'NORWEGIAN 4X4',
      colour: AuroraRunType.intervals,
      date: 'Sat 12 Sep',
      distance: '6.80 km',
      time: '41:20',
      truePace: '4:58/km',
      verdict: 'FASTER',
      verdictBetter: true,
      route: route,
    ),
    'scores': const ScoresCardData(
      lanes: [
        ScoreLaneData(
          label: 'AEROBIC',
          value: '62',
          unit: 'nd percentile',
          change: 'Up 2 in 6 weeks',
        ),
        ScoreLaneData(label: 'SPEED', value: '--', unit: ''),
        ScoreLaneData(
          label: 'MID',
          value: '71',
          unit: 'st percentile',
          change: 'No change in 6 weeks',
        ),
        ScoreLaneData(
          label: 'LONG',
          value: '48',
          unit: 'th percentile',
          change: 'Down 3 in 6 weeks',
        ),
      ],
    ),
  };
  for (final e in cards.entries) {
    testWidgets('share card ${e.key}', (tester) async {
      await pumpApp(
        tester,
        fakeServices(),
        home: Scaffold(
          body: Center(child: ShareCard(data: e.value)),
        ),
      );
      tester.view.physicalSize = const Size(1080, 1350);
      await pumpTimes(tester, 2);
      expect(tester.takeException(), isNull);
      final name = 'share_card_${e.key}';
      expect(
        File('test/golden/goldens/$name.png').existsSync() ||
            autoUpdateGoldenFiles,
        isTrue,
      );
      await expectLater(
        find.byType(ShareCard),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
