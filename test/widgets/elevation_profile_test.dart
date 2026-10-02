import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/elevation_profile.dart';

import '../run_fixtures.dart';

void main() {
  final start = DateTime.utc(2026, 10, 2, 6);

  Future<engine.RunElevation> pump(
    WidgetTester tester, {
    engine.ElevSource src = engine.ElevSource.baro,
    Units units = Units.km,
    ValueChanged<engine.ElevPoint?>? onScrub,
  }) async {
    final run = withElevation(
      freeRunFile(n: 70, start: start, seconds: 1800),
      src: src,
    );
    final e = engine.RunElevation.of(run)!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [RunSoloTokens.dark]),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ElevationProfile(
              elevation: e,
              units: units,
              onScrub: onScrub,
            ),
          ),
        ),
      ),
    );
    return e;
  }

  testWidgets('shows climb, descent, GAP as an estimate and the source', (
    tester,
  ) async {
    final e = await pump(tester);
    expect(find.text('ELEVATION'), findsOneWidget);
    expect(find.text('${e.ascentM.round()} m'), findsOneWidget);
    expect(find.text('${e.descentM.round()} m'), findsOneWidget);
    expect(
      find.textContaining('GRADE-ADJUSTED PACE (ESTIMATE)'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('elevation-gap')), findsOneWidget);
    expect(find.textContaining('barometer'), findsOneWidget);
  });

  testWidgets('a GPS-only run says it is rougher', (tester) async {
    await pump(tester, src: engine.ElevSource.gps);
    expect(find.textContaining('no barometer'), findsOneWidget);
  });

  testWidgets('miles show feet', (tester) async {
    final e = await pump(tester, units: Units.mi);
    expect(find.text('${(e.ascentM * 3.28084).round()} ft'), findsOneWidget);
  });

  testWidgets('tap reads a point, tap again clears; drag scrubs', (
    tester,
  ) async {
    final heard = <engine.ElevPoint?>[];
    await pump(tester, onScrub: heard.add);
    final callout = find.byKey(const ValueKey('elevation-callout'));
    expect(
      tester.widget<Text>(callout).data,
      'Tap or drag the profile to read a point.',
    );
    final chart = find.byKey(const ValueKey('elevation-chart'));
    final box = tester.getRect(chart);
    await tester.tapAt(Offset(box.left + 60, box.center.dy));
    await tester.pump();
    final text = tester.widget<Text>(callout).data!;
    expect(text, contains(' km · '));
    expect(text, contains('grade '));
    expect(heard.single, isNotNull);
    final first = heard.single!;
    await tester.tapAt(Offset(box.left + 60, box.center.dy));
    await tester.pump();
    expect(heard.last, isNull);
    // Dragging walks the point along the run.
    final g = await tester.startGesture(Offset(box.left + 20, box.center.dy));
    await g.moveBy(const Offset(120, 0));
    await tester.pump();
    await g.moveBy(const Offset(120, 0));
    await tester.pump();
    await g.up();
    final last = heard.last!;
    expect(last.distM, greaterThan(first.distM));
  });
}
