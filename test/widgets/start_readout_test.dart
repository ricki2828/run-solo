import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/widgets/start_readout.dart';

Widget _wrap({double? height, double? back, Units units = Units.km}) =>
    MaterialApp(
      home: Scaffold(
        body: StartReadout(
          heightVsStartM: height,
          backToStartM: back,
          units: units,
          labelColor: Colors.white70,
          valueColor: Colors.white,
        ),
      ),
    );

String _text(WidgetTester t, String key) =>
    (t.widget(find.byKey(ValueKey(key))) as Text).data!;

void main() {
  testWidgets('above the start: up arrow and a plus', (tester) async {
    await tester.pumpWidget(_wrap(height: 42.4));
    expect(find.byKey(const ValueKey('height-up')), findsOneWidget);
    expect(find.byKey(const ValueKey('height-down')), findsNothing);
    expect(_text(tester, 'height-vs-start'), '+42 m');
    expect(find.byKey(const ValueKey('start-readout')), findsOneWidget);
    expect(find.byKey(const ValueKey('back-to-start')), findsNothing);
  });

  testWidgets('below the start: down arrow and a minus sign', (tester) async {
    await tester.pumpWidget(_wrap(height: -18.2));
    expect(find.byKey(const ValueKey('height-down')), findsOneWidget);
    expect(_text(tester, 'height-vs-start'), '−18 m');
  });

  testWidgets('level reads LEVEL with no arrow, never -0', (tester) async {
    await tester.pumpWidget(_wrap(height: -0.3));
    expect(_text(tester, 'height-vs-start'), 'LEVEL');
    expect(find.byKey(const ValueKey('height-up')), findsNothing);
    expect(find.byKey(const ValueKey('height-down')), findsNothing);
  });

  testWidgets('feet for miles users', (tester) async {
    await tester.pumpWidget(_wrap(height: 10, units: Units.mi));
    expect(_text(tester, 'height-vs-start'), '+33 ft');
  });

  testWidgets('retracing: BACK TO START with the distance, plate on', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(height: -18, back: 2400));
    expect(find.byKey(const ValueKey('start-readout-retrace')), findsOneWidget);
    expect(find.text('BACK TO START'), findsOneWidget);
    expect(_text(tester, 'back-to-start'), '2.4 km');
    expect(_text(tester, 'height-vs-start'), '−18 m');
  });

  testWidgets('retracing without an elevation still says BACK TO START', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(back: 850));
    expect(_text(tester, 'back-to-start'), '0.9 km');
    expect(find.byKey(const ValueKey('height-vs-start')), findsNothing);
  });
}
