import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/screens/run_detail_screen.dart';
import 'package:run_solo/widgets/hold_button.dart';

import '../helpers.dart';
import '../run_fixtures.dart';

/// Run detail (brief §4.7, addendum A4) against the fake map surface.
void main() {
  final d1 = DateTime.utc(2026, 9, 10, 6);

  testWidgets('4x4: header, map, rep table, recoveries collapsed, zone strip', (
    tester,
  ) async {
    final r = fourByFourFile(n: 1, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r]),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('NORWEGIAN 4X4'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(find.text('Rep 1'), findsOneWidget);
    expect(find.text('Rep 4'), findsOneWidget);
    expect(find.text('Rec 1'), findsNothing);
    await scrollTo(tester, find.text('RECOVERIES'));
    await tester.tap(find.text('RECOVERIES'));
    await pumpTimes(tester, 2);
    await scrollTo(tester, find.text('Rec 1'));
    expect(find.text('Rec 1'), findsOneWidget);
    await scrollTo(tester, find.textContaining('TIME IN ZONE'));
    expect(find.textContaining('TIME IN ZONE'), findsOneWidget);
    await scrollTo(tester, find.text('HOLD TO DELETE'));
    expect(find.text('Fix laps'), findsOneWidget);
    expect(find.text('HOLD TO DELETE'), findsOneWidget);
    // Phase 3: no weather chip anywhere.
    expect(find.textContaining('°'), findsNothing);
  });

  testWidgets('indoor: "Indoor run, no route", no map', (tester) async {
    final r = fourByFourFile(n: 2, start: d1, indoor: true);
    await pumpApp(
      tester,
      fakeServices(files: [r]),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('Indoor run, no route'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-map')), findsNothing);
  });

  testWidgets('map failed to load: message over the route shape', (
    tester,
  ) async {
    final r = freeRunFile(n: 3, start: d1);
    await pumpApp(
      tester,
      fakeServices(
        files: [r],
        maps: const FakeMapSurfaceFactory(available: true, failLoad: true),
      ),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('Map failed to load'), findsOneWidget);
    expect(find.byType(RouteShape), findsOneWidget);
  });

  testWidgets('no Google Play services: message, route still drawn', (
    tester,
  ) async {
    final r = freeRunFile(n: 3, start: d1);
    await pumpApp(
      tester,
      fakeServices(
        files: [r],
        maps: const FakeMapSurfaceFactory(available: true),
        permissions: FakePermissionsGateway(
          snapshot: const PermissionSnapshot(
            fineLocation: true,
            gmsAvailable: false,
          ),
        ),
      ),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('Map needs Google Play services'), findsOneWidget);
    expect(find.byType(RouteShape), findsOneWidget);
  });

  testWidgets('tap the map card → full-screen map with a close button', (
    tester,
  ) async {
    final r = freeRunFile(n: 3, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r]),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    await tester.tap(find.byKey(const ValueKey('fake-map')));
    await settleAnimations(tester);
    expect(find.byType(FullScreenMap), findsOneWidget);
    await tester.tap(find.byTooltip('Close map'));
    await settleAnimations(tester);
    expect(find.byType(FullScreenMap), findsNothing);
  });

  testWidgets('Laps run: lap table with fastest lap', (tester) async {
    final r = lapsRunFile(n: 4, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r]),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('LAPS RUN'), findsOneWidget);
    await scrollTo(tester, find.text('LAP SPREAD'));
    expect(find.text('Lap 2'), findsOneWidget, reason: 'fastest lap tile');
    expect(find.text('LAP SPREAD'), findsOneWidget);
    expect(find.text('Fix laps', skipOffstage: false), findsNothing);
  });

  testWidgets('Free run: splits, no fix laps', (tester) async {
    final r = freeRunFile(n: 5, start: d1);
    await pumpApp(
      tester,
      fakeServices(files: [r]),
      home: RunDetailScreen(runId: r.id),
    );
    await pumpTimes(tester, 6);
    expect(find.text('FREE RUN'), findsOneWidget);
    await scrollTo(tester, find.text('AVG PACE'));
    expect(find.text('AVG PACE'), findsOneWidget);
    expect(find.text('Fix laps', skipOffstage: false), findsNothing);
  });

  testWidgets('hold to delete removes the run', (tester) async {
    final r = freeRunFile(n: 6, start: d1);
    final services = fakeServices(files: [r]);
    await pumpApp(tester, services, home: RunDetailScreen(runId: r.id));
    await pumpTimes(tester, 6);
    await scrollTo(tester, find.byType(HoldButton));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldButton)),
    );
    await settleAnimations(tester, const Duration(seconds: 2));
    await gesture.up();
    await pumpTimes(tester, 3);
    expect(await services.history.load(r.id), isNull);
  });

  testWidgets('missing file: says so, never crashes', (tester) async {
    await pumpApp(
      tester,
      fakeServices(),
      home: const RunDetailScreen(runId: 'nope'),
    );
    await pumpTimes(tester, 4);
    expect(find.textContaining('File missing'), findsOneWidget);
  });
}
