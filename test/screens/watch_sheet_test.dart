import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/routes.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/screens/watch_sheet.dart';
import 'package:run_solo/state/intervals_icu.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/watch_guide.dart';

import '../helpers.dart';
import '../route_fixtures.dart';

/// Send to watch: the sheet for a workout and for a route, the Start entry.
class _RecordingHttp implements IntervalsHttp {
  _RecordingHttp([this.status = 200]);
  final int status;
  final List<IntervalsRequest> sent = [];

  @override
  Future<IntervalsResponse> send(IntervalsRequest req) async {
    sent.add(req);
    return IntervalsResponse(status, '[]');
  }
}

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

  Future<_RecordingHttp> openConnected(
    WidgetTester tester, {
    int status = 200,
    bool connected = true,
  }) async {
    final http = _RecordingHttp(status);
    final store = MemorySecretStore();
    if (connected) {
      await store.write(IntervalsIcuTarget.keyName, 'k3y');
      await store.write(IntervalsIcuTarget.athleteName, 'i99');
    }
    final target = IntervalsIcuTarget(store: store, http: http);
    await target.load();
    await pumpApp(
      tester,
      fakeServices(exportTargets: [target]),
      home: Scaffold(body: WatchSheet.workout(workout: workout(), maxHr: 190)),
    );
    await pumpTimes(tester, 3);
    return http;
  }

  testWidgets('Intervals.icu: Add for today posts a WORKOUT event', (
    tester,
  ) async {
    final http = await openConnected(tester);
    expect(find.byKey(const ValueKey('watch-intervals-blurb')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('watch-intervals-today')));
    await pumpTimes(tester, 4);
    final r = http.sent.single;
    expect(r.method, 'POST');
    expect(r.uri.path, '/api/v1/athlete/i99/events/bulk');
    expect(r.uri.queryParameters['upsert'], 'true');
    final event = (jsonDecode(utf8.decode(r.body!)) as List).single as Map;
    expect(event['category'], 'WORKOUT');
    expect(event['type'], 'Run');
    expect(event['start_date_local'], '2026-09-24T00:00:00');
    expect(event['external_id'], 'runsupreme-norwegian-4x4-2026-09-24');
    expect(event['description'], contains('3x\n- Work 4m 85-95% HR'));
    expect(find.byKey(const ValueKey('watch-intervals-added')), findsOneWidget);
  });

  testWidgets('Intervals.icu: tomorrow uses the next date', (tester) async {
    final http = await openConnected(tester);
    await tester.tap(find.byKey(const ValueKey('watch-intervals-tomorrow')));
    await pumpTimes(tester, 4);
    final event =
        (jsonDecode(utf8.decode(http.sent.single.body!)) as List).single as Map;
    expect(event['start_date_local'], '2026-09-25T00:00:00');
  });

  testWidgets('Intervals.icu: a refused key shows a plain error', (
    tester,
  ) async {
    await openConnected(tester, status: 401);
    await tester.tap(find.byKey(const ValueKey('watch-intervals-today')));
    await pumpTimes(tester, 4);
    expect(find.text('Key not accepted'), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-intervals-added')), findsNothing);
  });

  testWidgets('Intervals.icu: not connected says where to connect', (
    tester,
  ) async {
    final http = await openConnected(tester, connected: false);
    expect(
      find.byKey(const ValueKey('watch-intervals-connect')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('watch-intervals-today')), findsNothing);
    expect(http.sent, isEmpty);
    expect(find.byKey(const ValueKey('watch-share')), findsOneWidget);
  });
}
