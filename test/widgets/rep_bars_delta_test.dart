import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/delta_glyph.dart';
import 'package:run_solo/widgets/rep_bars.dart';

// Reviewer P3 on #27: the rep bars follow the record screen's rule. Flat
// only when the delta AS SHOWN (whole seconds, display unit) is 0.
Future<void> _pump(WidgetTester tester, double delta, Units units) =>
    tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: Scaffold(
          body: RepBars(
            units: units,
            reps: [
              RepBarDatum(
                label: 'R1',
                paceSecPerKm: 285 + delta,
                ghostSecPerKm: 285,
              ),
            ],
          ),
        ),
      ),
    );

DeltaDirection? _glyph(WidgetTester tester) {
  final g = find.byType(DeltaGlyph);
  return g.evaluate().isEmpty ? null : tester.widget<DeltaGlyph>(g).direction;
}

void main() {
  testWidgets('0.6 s/km slower in km: "1" with the slower arrow, no dash', (
    tester,
  ) async {
    await _pump(tester, 0.6, Units.km);
    expect(find.text('1'), findsOneWidget);
    expect(_glyph(tester), DeltaDirection.down);
  });

  testWidgets('0.6 s/km faster in mi: "1" with the faster arrow', (
    tester,
  ) async {
    await _pump(tester, -0.6, Units.mi);
    expect(find.text('1'), findsOneWidget);
    expect(_glyph(tester), DeltaDirection.up);
  });

  testWidgets('0.4 s/km: ±0 and no glyph in km, "1" slower in mi', (
    tester,
  ) async {
    await _pump(tester, 0.4, Units.km);
    expect(find.text('±0'), findsOneWidget);
    expect(_glyph(tester), isNull);
    await _pump(tester, 0.4, Units.mi);
    expect(find.text('1'), findsOneWidget);
    expect(_glyph(tester), DeltaDirection.down);
  });
}
