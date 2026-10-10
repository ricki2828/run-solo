import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/gradient_legend.dart';
import 'package:run_solo/theme/theme.dart';

void main() {
  testWidgets('legend fits a 360 px screen on one line, not clipped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: const Scaffold(
          body: Stack(
            children: [
              Positioned(left: 8, bottom: 48, child: GradientLegend()),
            ],
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byKey(const ValueKey('gradient-legend')));
    expect(box.left, greaterThanOrEqualTo(8));
    expect(box.right, lessThanOrEqualTo(360 - 8));
    expect(box.height, lessThan(40));
    expect(tester.takeException(), isNull);
    for (final w in ['FLAT', 'UP', 'STEEP', 'DOWN']) {
      expect(find.text(w), findsOneWidget);
    }
  });
}
