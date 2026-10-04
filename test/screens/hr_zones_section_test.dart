import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/widgets/hr_zones_section.dart';

import '../helpers.dart';

/// Pumps the section against a live settings value; edits write back to it.
Future<ValueNotifier<AppSettings>> pumpSection(
  WidgetTester tester,
  AppSettings initial, {
  int? suggestion,
}) async {
  final settings = ValueNotifier(initial);
  await loadRunSoloFonts();
  tester.view.physicalSize = const Size(360 * 3, 640 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: runSoloTheme(),
      home: Scaffold(
        body: ValueListenableBuilder<AppSettings>(
          valueListenable: settings,
          builder: (_, s, _) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: Space.screenGutter),
            child: HrZonesSection(
              settings: s,
              now: now(),
              restingSuggestion: suggestion,
              onChange: (f) async => settings.value = f(settings.value),
            ),
          ),
        ),
      ),
    ),
  );
  return settings;
}

void main() {
  const whoop = AppSettings(typedMaxHr: 188, restingHr: 54);

  testWidgets('% of max shows today\'s ranges', (tester) async {
    await pumpSection(tester, const AppSettings(typedMaxHr: 190));
    expect(find.text('114–132 bpm'), findsOneWidget); // Z2
    expect(find.text('171–190 bpm'), findsOneWidget); // Z5
  });

  testWidgets('reserve shows the Whoop ranges', (tester) async {
    await pumpSection(
      tester,
      whoop.copyWith(hrZoneMethod: engine.HrZoneMethod.reserve),
    );
    for (final r in [
      '108–135 bpm',
      '136–148 bpm',
      '149–161 bpm',
      '162–175 bpm',
      '176–188 bpm',
    ]) {
      expect(find.text(r), findsOneWidget, reason: r);
    }
  });

  testWidgets('reserve without resting HR prompts, suggestion fills it', (
    tester,
  ) async {
    final s = await pumpSection(
      tester,
      const AppSettings(
        typedMaxHr: 188,
        hrZoneMethod: engine.HrZoneMethod.reserve,
      ),
      suggestion: 56,
    );
    expect(find.byKey(const ValueKey('hr-reserve-prompt')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hr-resting-suggest')));
    await tester.pump();
    expect(s.value.restingHr, 56);
    expect(find.byKey(const ValueKey('hr-reserve-prompt')), findsNothing);
  });

  testWidgets('picking Custom prefills from the current method', (
    tester,
  ) async {
    final s = await pumpSection(
      tester,
      whoop.copyWith(hrZoneMethod: engine.HrZoneMethod.reserve),
    );
    await tester.tap(find.byKey(const ValueKey('hr-method-custom')));
    await tester.pump();
    expect(s.value.hrZoneMethod, engine.HrZoneMethod.custom);
    expect(s.value.customZones, [108, 136, 149, 162, 176]);
    expect(find.text(' – 135'), findsOneWidget);
  });

  testWidgets('custom: non-ascending shows an error and is not saved', (
    tester,
  ) async {
    final s = await pumpSection(
      tester,
      whoop.copyWith(
        hrZoneMethod: engine.HrZoneMethod.custom,
        customZones: [108, 136, 149, 162, 176],
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('hr-custom-3')), '130');
    await tester.pump();
    expect(find.byKey(const ValueKey('hr-custom-error')), findsOneWidget);
    expect(s.value.customZones, [108, 136, 149, 162, 176]);
    await tester.enterText(find.byKey(const ValueKey('hr-custom-3')), '150');
    await tester.pump();
    expect(find.byKey(const ValueKey('hr-custom-error')), findsNothing);
    expect(s.value.customZones, [108, 136, 150, 162, 176]);
  });
}
