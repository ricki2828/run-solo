import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/theme/theme.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<engine.TreadmillMark> marks,
    Units units,
  ) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: [RunSoloTokens.dark]),
      home: Scaffold(
        body: MarkerSplits(marks: marks, units: units),
      ),
    ),
  );

  testWidgets('one row per mark: distance, moving time, belt speed', (
    tester,
  ) async {
    await pump(tester, const [
      engine.TreadmillMark(180000, 500),
      engine.TreadmillMark(330000, 1000),
      engine.TreadmillMark(690000, 2000), // 1.5 skipped: one long stretch
    ], Units.km);
    expect(find.byKey(const ValueKey('run-marker-splits')), findsOneWidget);
    expect(find.text('KM/H'), findsOneWidget);
    // 0.5 km in 3:00 = 10.0, 0.5 km in 2:30 = 12.0, 1.0 km in 6:00 = 10.0
    for (final cell in [
      '0.50', '3:00', '10.0', //
      '1.00', '2:30', '12.0',
      '2.00', '6:00',
    ]) {
      expect(find.text(cell), findsWidgets, reason: cell);
    }
    expect(find.text('10.0'), findsNWidgets(2));
  });

  testWidgets('miles show mph and miles', (tester) async {
    await pump(tester, const [engine.TreadmillMark(150000, 402.336)], Units.mi);
    expect(find.text('MPH'), findsOneWidget);
    expect(find.text('0.25'), findsOneWidget);
    expect(find.text('2:30'), findsOneWidget);
    expect(find.text('6.0'), findsOneWidget); // 0.25 mi in 2:30
  });
}
