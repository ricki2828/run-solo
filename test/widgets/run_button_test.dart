import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/chrome.dart';

void main() {
  testWidgets('longest labels scale down at text scale 1.3, no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    const labels = ['Check for new maps', 'Save & ready up'];
    await tester.pumpWidget(
      MaterialApp(
        theme: runSoloTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final l in labels) ...[
                    RunButton(label: l, onPressed: () {}),
                    RunButton.secondary(label: l, onPressed: () {}),
                    RunButton.tertiary(label: l, onPressed: () {}),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FittedBox), findsWidgets);
  });
}
