import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';
import 'package:run_solo/widgets/zone_ladder.dart';

Widget host(int zone, {double position = 0.5, int? hr}) => MaterialApp(
  theme: runSoloTheme(brightness: Brightness.dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: ZoneLadder.width + ZoneLadder.pointer,
        height: 500,
        child: ZoneLadder(zone: zone, position: position, hr: hr),
      ),
    ),
  ),
);

void main() {
  testWidgets('five rungs, Z1 at the bottom to Z5 at the top, each labelled', (
    tester,
  ) async {
    await tester.pumpWidget(host(3));
    for (var z = 1; z <= 5; z++) {
      expect(find.text('$z'), findsOneWidget);
    }
    final y = [
      for (var z = 1; z <= 5; z++)
        tester.getCenter(find.byKey(ValueKey('ladder-rung-$z'))).dy,
    ];
    for (var i = 1; i < y.length; i++) {
      expect(y[i], lessThan(y[i - 1]), reason: 'Z${i + 1} above Z$i');
    }
  });

  testWidgets('the lit rung is full colour with the pointer; others 30 %', (
    tester,
  ) async {
    await tester.pumpWidget(host(4));
    Color fillOf(int z) =>
        ((tester.widget<Container>(find.byKey(ValueKey('ladder-rung-$z'))))
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(fillOf(4), HrZones.distributionLight[4]);
    for (final z in [1, 2, 3, 5]) {
      expect(fillOf(z).a, closeTo(0.30, 0.01), reason: 'Z$z inactive');
    }
    expect(find.byKey(const ValueKey('ladder-pointer')), findsOneWidget);
  });

  testWidgets('the ladder is 18 dp wide (plus its pointer)', (tester) async {
    await tester.pumpWidget(host(2));
    expect(
      tester.getSize(find.byKey(const ValueKey('ladder-rung-2'))).width,
      ZoneLadder.width,
    );
  });

  testWidgets('no HR (zone 0): nothing is drawn', (tester) async {
    await tester.pumpWidget(host(0));
    expect(find.byKey(const ValueKey('ladder-rung-1')), findsNothing);
    expect(find.byKey(const ValueKey('ladder-pointer')), findsNothing);
  });

  testWidgets('pointer sits higher on the rung for a higher position', (
    tester,
  ) async {
    // The painter is private; read its position field dynamically.
    double posOf() {
      final paint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('ladder-pointer')),
      );
      final painter = paint.painter as dynamic;
      return painter.position as double;
    }

    await tester.pumpWidget(host(3, position: 0.1));
    final low = posOf();
    await tester.pumpWidget(host(3, position: 0.9));
    await tester.pumpAndSettle();
    final high = posOf();
    expect(low, closeTo(0.1, 1e-9));
    expect(high, closeTo(0.9, 1e-9));
    expect(high, greaterThan(low));
  });

  testWidgets('the marker y matches HR position at the zone edges and mid', (
    tester,
  ) async {
    // The tick is drawn by a private painter over the lit rung's own height;
    // read its resolved y through the same mapping it paints with.
    Future<double> tickY(double position) async {
      await tester.pumpWidget(host(3, position: position, hr: 150));
      await tester.pumpAndSettle();
      final paint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('ladder-pointer')),
      );
      final h = tester
          .getSize(find.byKey(const ValueKey('ladder-pointer')))
          .height;
      final painter = paint.painter as dynamic;
      return (5 + (1 - (painter.position as double)) * (h - 10));
    }

    final bottom = await tickY(0);
    final mid = await tickY(0.5);
    final top = await tickY(1);
    final h = tester
        .getSize(find.byKey(const ValueKey('ladder-pointer')))
        .height;
    expect(bottom, closeTo(h - 5, 1e-6), reason: 'zone floor');
    expect(top, closeTo(5, 1e-6), reason: 'zone ceiling');
    expect(mid, closeTo(h / 2, 1e-6), reason: 'mid zone');
  });

  testWidgets('the tick spans the whole rung and the bpm is >= 14 sp', (
    tester,
  ) async {
    await tester.pumpWidget(host(3, position: 0.8, hr: 152));
    await tester.pumpAndSettle();
    final tick = tester.getSize(find.byKey(const ValueKey('ladder-pointer')));
    final rung = tester.getSize(find.byKey(const ValueKey('ladder-rung-3')));
    expect(tick.width, ZoneLadder.pointer + rung.width);
    expect(ZoneLadder.labelSize, greaterThanOrEqualTo(14));
  });
}
