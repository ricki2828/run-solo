import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_engine/testing.dart' as synth;
import 'package:run_solo/state/boards.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/widgets/board_chips.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// #71 review P1 at the widget: the result screen opens before the new
/// run's best efforts are built. The chips claim no PB, say "Checking your
/// boards" only after 4 s, and re-fold when the data lands however late,
/// playing M5 then if the screen is still open. The store half (a real
/// FileRunStore batch landing late) is in test/state/boards_test.dart.
void main() {
  final d1 = DateTime.utc(2026, 9, 1, 6);

  engine.RunFile steady(int n, DateTime start, int secPerKm) => generator
      .generate(
        synth.SyntheticSpec(
          name: 'chips_$n',
          id: runId(n),
          mode: engine.RunMode.free,
          lapStyle: synth.LapStyle.none,
          start: start,
          segments: [synth.Segment.free(2400, speedFor(secPerKm))],
        ),
      )
      .run;

  final prior = steady(1, d1, 330);
  final fresh = steady(2, d1.add(const Duration(days: 2)), 300); // 5K PB

  List<String> mockHaptics(WidgetTester tester) {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') calls.add('$call');
        return null;
      },
    );
    return calls;
  }

  Future<MemoryRunStore> open(WidgetTester tester) async {
    final store = MemoryRunStore(files: [prior, fresh])
      ..underived.add(fresh.id);
    await pumpApp(
      tester,
      fakeServices(history: store),
      home: Scaffold(body: BoardChips(runId: fresh.id, justFinished: true)),
    );
    await pumpTimes(tester, 4);
    return store;
  }

  final pb = find.byKey(const ValueKey('pb-chip'));

  testWidgets('late landing: silent, then pending, then the PB with M5', (
    tester,
  ) async {
    final haptics = mockHaptics(tester);
    final store = await open(tester);
    expect(find.text(BoardChip.pendingLabel), findsNothing, reason: '< 4 s');
    expect(pb, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text(BoardChip.pendingLabel), findsOneWidget);
    await tester.pump(const Duration(seconds: 30)); // a slow phone
    expect(pb, findsNothing, reason: 'never a PB from a half-built board');
    expect(haptics, isEmpty);

    store.landDerived();
    await pumpTimes(tester, 4);
    expect(find.text(BoardChip.pendingLabel), findsNothing);
    expect(pb, findsWidgets);
    expect(find.textContaining('New best 5K · '), findsOneWidget);
    expect(haptics, isNotEmpty, reason: 'M5 plays while the screen is open');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('lands inside 4 s: no pending text at all', (tester) async {
    mockHaptics(tester);
    final store = await open(tester);
    await tester.pump(const Duration(seconds: 1));
    store.landDerived();
    await pumpTimes(tester, 4);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text(BoardChip.pendingLabel), findsNothing);
    expect(find.textContaining('New best 5K · '), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('seen later (not just finished): the PB without M5', (
    tester,
  ) async {
    final haptics = mockHaptics(tester);
    await pumpApp(
      tester,
      fakeServices(history: MemoryRunStore(files: [prior, fresh])),
      home: Scaffold(body: BoardChips(runId: fresh.id)),
    );
    await pumpTimes(tester, 4);
    expect(find.textContaining('New best 5K · '), findsOneWidget);
    expect(haptics, isEmpty);
  });
}
