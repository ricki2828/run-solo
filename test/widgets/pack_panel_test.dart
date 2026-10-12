import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/state/progress_snapshot.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/pack_panel.dart';

Future<void> _pump(
  WidgetTester tester,
  Units units, {
  String stage = 'month3',
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: runSoloTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: PackPanel(
            snapshot: ProgressSnapshot.sample(stage),
            units: units,
          ),
        ),
      ),
    ),
  );
}

Iterable<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');

void main() {
  testWidgets('km: paces read per km', (tester) async {
    await _pump(tester, Units.km);
    expect(_texts(tester).any((s) => s.endsWith('/km')), isTrue);
    expect(_texts(tester).any((s) => s.endsWith('/KM')), isTrue);
    expect(_texts(tester).any((s) => s.contains('/mi')), isFalse);
  });

  testWidgets('miles: pace axis, table and distance chart convert', (
    tester,
  ) async {
    await _pump(tester, Units.mi);
    final texts = _texts(tester).toList();
    expect(texts.any((s) => s.endsWith('/mi')), isTrue);
    expect(texts.any((s) => s.endsWith('/MI')), isTrue);
    expect(texts.any((s) => s.contains('/km') || s.contains('/KM')), isFalse);
    // The table keeps the per-km norm internally: 6:18/km = 10:08/mi.
    expect(texts, contains('10:08/mi'));

    await tester.tap(find.byKey(const ValueKey('pack-chip-2')));
    await tester.pump();
    final story = ProgressSnapshot.sample('month3').story!;
    final headline = tester
        .widget<Text>(find.byKey(const ValueKey('pack-statement')))
        .data!;
    expect(headline, contains(' MI IN '));
    expect(headline, isNot(contains(' KM ')));
    expect(headline, startsWith((story.km / 1.609344).toStringAsFixed(1)));
    // Value label per day, in miles.
    final biggest = story.dailyKm.reduce((a, b) => a > b ? a : b);
    expect(_texts(tester), contains((biggest / 1.609344).toStringAsFixed(1)));
  });

  testWidgets('distance bars carry a km label per run day', (tester) async {
    await _pump(tester, Units.km);
    await tester.tap(find.byKey(const ValueKey('pack-chip-2')));
    await tester.pump();
    final story = ProgressSnapshot.sample('month3').story!;
    for (final km in story.dailyKm.where((k) => k > 0)) {
      expect(_texts(tester), contains(km.toStringAsFixed(1)));
    }
  });

  testWidgets('consistency bars carry a per-week label', (tester) async {
    await _pump(tester, Units.km);
    await tester.tap(find.byKey(const ValueKey('pack-chip-1')));
    await tester.pump();
    final labels = tester.widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('pack-week-labels')),
        matching: find.byType(Text),
      ),
    );
    expect(labels.length, 8);
    expect(labels.last.data, 'NOW\nRAN');
    expect(labels.first.data, startsWith('-7W'));
  });
}
