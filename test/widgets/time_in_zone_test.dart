import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/theme/theme.dart';
import 'package:run_solo/theme/zones.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Run detail "Time in zone, in colour".
void main() {
  final start = DateTime.utc(2026, 10, 2, 6);

  engine.RunFile runWith(int n, int? Function(int sec) hrAt) {
    final base = freeRunFile(n: n, start: start, seconds: 1200);
    return base.copyWith(
      samples: [
        for (final s in base.samples) s.copyWith(hr: hrAt(s.tMs ~/ 1000)),
      ],
    );
  }

  Future<void> open(WidgetTester tester, engine.RunFile run) async {
    await pumpApp(
      tester,
      fakeServices(files: [run]),
      home: RunDetailScreen(runId: run.id),
    );
    await pumpTimes(tester, 6);
  }

  double luminance(Color c) => c.computeLuminance();
  double contrast(Color a, Color b) {
    final hi = luminance(a) > luminance(b) ? a : b;
    final lo = identical(hi, a) ? b : a;
    return (luminance(hi) + 0.05) / (luminance(lo) + 0.05);
  }

  testWidgets('five rows in order, every zone named, zero zones dimmed', (
    tester,
  ) async {
    // Z2 for a quarter of the run, Z3 for the rest.
    await open(tester, runWith(71, (s) => s < 300 ? 120 : 140));
    await scrollTo(tester, find.text('TIME IN ZONE'));
    expect(find.byKey(const ValueKey('time-in-zone-max-hr')), findsOneWidget);
    expect(find.textContaining('Max HR 190'), findsOneWidget);
    expect(find.byKey(const ValueKey('time-in-zone-partial')), findsNothing);
    for (final name in [
      'Z1 · Easy',
      'Z2 · Steady',
      'Z3 · Tempo',
      'Z4 · Hard',
      'Z5 · Max',
    ]) {
      expect(find.text(name), findsOneWidget);
    }
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('Z1 · Easy'), lessThan(top('Z2 · Steady')));
    expect(top('Z2 · Steady'), lessThan(top('Z3 · Tempo')));
    expect(top('Z4 · Hard'), lessThan(top('Z5 · Max')));
    double opacity(int z) => tester
        .widget<Opacity>(find.byKey(ValueKey('time-in-zone-row-$z')))
        .opacity;
    expect(opacity(1), lessThan(1));
    expect(opacity(2), 1);
    expect(opacity(3), 1);
    expect(opacity(4), lessThan(1));
    expect(opacity(5), lessThan(1));
    // The stacked bar omits zero-width zones.
    expect(
      find.byKey(const ValueKey('time-in-zone-segment-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('time-in-zone-segment-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('time-in-zone-segment-1')), findsNothing);
    expect(find.byKey(const ValueKey('time-in-zone-segment-5')), findsNothing);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('partial HR says how much of the run has it', (tester) async {
    await open(tester, runWith(72, (s) => s < 216 ? null : 140));
    await scrollTo(tester, find.text('TIME IN ZONE'));
    expect(find.text('Heart rate for 82% of the run'), findsOneWidget);
  });

  testWidgets('no HR: no zone card', (tester) async {
    final run = freeRunFile(n: 73, start: start, hr: false);
    await open(tester, run);
    expect(find.text('TIME IN ZONE'), findsNothing);
  });

  test('zone hues are 3:1 against the surfaces in both themes', () {
    final dark = RunSoloTokens.dark;
    final light = RunSoloTokens.light;
    for (var z = 1; z <= 5; z++) {
      for (final bg in [dark.bgBase, dark.bgRaised, dark.bgSunken]) {
        expect(
          contrast(HrZones.distribution(z, Brightness.dark), bg),
          greaterThanOrEqualTo(3),
          reason: 'dark Z$z on $bg',
        );
      }
      for (final bg in [light.bgBase, light.bgRaised, light.bgSunken]) {
        expect(
          contrast(HrZones.distribution(z, Brightness.light), bg),
          greaterThanOrEqualTo(3),
          reason: 'light Z$z on $bg',
        );
      }
    }
  });
}
