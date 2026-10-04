import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/watch_sheet.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/watch_guide.dart';

import '../helpers.dart';
import '../route_fixtures.dart';

/// Send to watch: the sheet for a workout and for a route, the Start entry.
void main() {
  engine.FitWorkout workout() => engine.FitWorkout.fromSession(
    engine.SessionSpec.norwegian4x4(),
    maxHr: 190,
  )!;

  Future<FakeTransferGateway> openWorkout(WidgetTester tester) async {
    final transfer = FakeTransferGateway();
    await pumpApp(
      tester,
      fakeServices(transfer: transfer),
      home: Scaffold(body: WatchSheet.workout(workout: workout())),
    );
    await pumpTimes(tester, 3);
    return transfer;
  }

  Future<List<String>> tapShare(
    WidgetTester tester,
    FakeTransferGateway transfer,
  ) async {
    late List<String> paths;
    await tester.runAsync(() async {
      final shared = transfer.nextShare();
      await tester.tap(find.byKey(const ValueKey('watch-share')));
      paths = await shared.timeout(const Duration(seconds: 20));
    });
    await settleAnimations(tester);
    return paths;
  }

  testWidgets('workout sheet: name, targets, and what works per brand', (
    tester,
  ) async {
    await openWorkout(tester);
    expect(find.text('SEND TO WATCH'), findsOneWidget);
    expect(find.text('Norwegian 4x4'), findsOneWidget);
    expect(
      find.textContaining('heart rate range of 162 to 181'),
      findsOneWidget,
    );
    expect(find.text('Share workout file'), findsOneWidget);
    for (final e in WatchGuide.entries) {
      expect(find.byKey(ValueKey('watch-${e.brand.name}')), findsOneWidget);
    }
    // Garmin is the only workout that lands, and it needs a computer.
    expect(find.textContaining('GARMIN/NewFiles'), findsOneWidget);
    expect(find.textContaining('Needs a computer'), findsOneWidget);
    expect(find.textContaining('Not supported'), findsNWidgets(4));
  });

  testWidgets('Share workout file hands a valid .fit to the share sheet', (
    tester,
  ) async {
    final transfer = await openWorkout(tester);
    final paths = await tapShare(tester, transfer);
    expect(paths.single, endsWith('.fit'));
    expect(transfer.sharedMimeTypes.single, 'application/octet-stream');
    final bytes = (await tester.runAsync(
      () => File(paths.single).readAsBytes(),
    ))!;
    final records = engine.FitDecoder.decode(bytes);
    expect(records.where((r) => r.mesgNum == 27).length, 6);
  });

  testWidgets('a failed share shows a plain error and stays open', (
    tester,
  ) async {
    final transfer = FakeTransferGateway()..failShare = true;
    await pumpApp(
      tester,
      fakeServices(transfer: transfer),
      home: Scaffold(body: WatchSheet.workout(workout: workout())),
    );
    await pumpTimes(tester, 3);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('watch-share')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await settleAnimations(tester);
    expect(find.byKey(const ValueKey('watch-error')), findsOneWidget);
    expect(find.text('Could not open the share sheet'), findsOneWidget);
  });

  testWidgets('route sheet shares a GPX course', (tester) async {
    final transfer = FakeTransferGateway();
    final route = testRoute();
    await pumpApp(
      tester,
      fakeServices(transfer: transfer),
      home: Scaffold(body: WatchSheet.route(route: route)),
    );
    await pumpTimes(tester, 3);
    expect(find.text(route.name), findsOneWidget);
    expect(find.text('Share course file'), findsOneWidget);
    expect(find.textContaining('Not supported'), findsNothing);
    final paths = await tapShare(tester, transfer);
    expect(paths.single, endsWith('.gpx'));
    expect(transfer.sharedMimeTypes.single, 'application/gpx+xml');
    final text = await tester.runAsync(() => File(paths.single).readAsString());
    expect(text, contains('<trk>'));
  });

  testWidgets('Start: Send to watch opens the sheet for the picked session', (
    tester,
  ) async {
    await pumpApp(
      tester,
      fakeServices(settings: const AppSettings(onboardingDone: true)),
      pushRoute: Routes.start,
    );
    await pumpTimes(tester, 4);
    const key = ValueKey('session-send-watch');
    await tester.ensureVisible(find.byKey(key));
    await tester.pump();
    await tester.tap(find.byKey(key));
    await settleAnimations(tester);
    expect(find.byType(WatchSheet), findsOneWidget);
    expect(find.text('Norwegian 4x4'), findsWidgets);
    expect(find.byKey(const ValueKey('watch-target')), findsOneWidget);
  });

  test('guide copy has no em dashes and says plainly what is unsupported', () {
    for (final e in WatchGuide.entries) {
      expect(e.workout, isNot(contains('—')));
      expect(e.route, isNot(contains('—')));
      expect(e.workoutWorks, e.brand == WatchBrand.garmin);
      if (!e.workoutWorks) expect(e.workout, startsWith('Not supported'));
    }
  });
}
