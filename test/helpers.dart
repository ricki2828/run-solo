import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_engine/run_engine.dart' as engine;
import 'package:run_solo/app/services.dart';
import 'package:run_solo/map/map_surface.dart';
import 'package:run_solo/main.dart';
import 'package:run_solo/platform/fake_gateway.dart';
import 'package:run_solo/platform/gateway.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/settings.dart';

/// Fixed test clock so timer interpolation is zero and "3 days ago" is stable.
final DateTime testNow = DateTime(2026, 9, 24, 10, 0);
DateTime now() => testNow;

Preset standardPreset() =>
    Preset(reps: 4, workSeconds: 240, recoverySeconds: 180);

AppServices fakeServices({
  FakeRecorderGateway? recorder,
  FakeBleGateway? ble,
  FakePermissionsGateway? permissions,
  AppSettings settings = const AppSettings(onboardingDone: true),
  List<RunSummary> runs = const [],
  List<engine.RunFile> files = const [],
  Map<String, engine.RunSidecar> sidecars = const {},
  MapSurfaceFactory? maps,
  FakeTransferGateway? transfer,
  FakeStorageGateway? storage,
}) => AppServices.fake(
  recorder: recorder ?? FakeRecorderGateway(now: now),
  ble: ble,
  permissions:
      permissions ??
      FakePermissionsGateway(
        snapshot: const PermissionSnapshot(
          fineLocation: true,
          notifications: true,
          bluetooth: true,
          batteryUnrestricted: true,
        ),
      ),
  settings: settings,
  runs: runs,
  files: files,
  sidecars: sidecars,
  maps: maps,
  transfer: transfer,
  storage: storage,
  now: now,
);

/// Mounts the app. With [pushRoute] the home is a launcher that pushes that
/// named route on first frame, so screens that pop can be tested.
bool _fontsLoaded = false;

/// Every family in the app's FontManifest (Barlow Condensed, Archivo and
/// MaterialIcons), so text metrics and icons match the phone; the default
/// test font is square-glyph and icons render as empty boxes.
Future<void> loadRunSoloFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final manifest = jsonDecode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<Object?>;
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final family = entry['family'] as String;
    final loader = FontLoader(family.replaceFirst('packages/', ''));
    for (final font
        in (entry['fonts'] as List<Object?>).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// A phone-shaped viewport (360 x 780 logical) instead of the 800 x 600 default.
void phoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(
  WidgetTester tester,
  AppServices services, {
  Widget? home,
  String? pushRoute,
  Object? pushArguments,
  bool checkRecoveryOnOpen = false,
}) async {
  await loadRunSoloFonts();
  phoneViewport(tester);
  // Tear the previous app down first: a second RunSoloApp at the same tree
  // position would keep the old Navigator (and its routes, bound to the old
  // services), so a golden would capture the previous screen.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    RunSoloApp(
      services: services,
      now: now,
      checkRecoveryOnOpen: checkRecoveryOnOpen,
      home: pushRoute != null
          ? _Launcher(route: pushRoute, arguments: pushArguments)
          : home,
    ),
  );
  await tester.pump();
  await tester.pump();
  if (pushRoute != null) {
    // Finish the push transition: a ModalRoute ignores pointers mid-flight.
    await tester.pump(const Duration(milliseconds: 400));
  }
}

class _Launcher extends StatefulWidget {
  const _Launcher({required this.route, this.arguments});
  final String route;
  final Object? arguments;

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context)
          .pushNamed(widget.route, arguments: widget.arguments);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('launcher')));
}

RunSummary summary({
  required String id,
  required DateTime start,
  bool fourByFour = true,
  RecordMode? mode,
  int durationMs = 32 * 60 * 1000,
  double distanceM = 6800,
  int laps = 8,
}) => RunSummary(
  id: id,
  mode: mode ?? (fourByFour ? RecordMode.fourByFour : RecordMode.free),
  start: start,
  durationMs: durationMs,
  distanceM: distanceM,
  laps: laps,
);

/// Drive route transitions / hold timers to completion. Two timed pumps: the
/// first frame only starts the ticker, the second one moves it.
Future<void> settleAnimations(
  WidgetTester tester, [
  Duration total = const Duration(milliseconds: 400),
]) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(total);
  await tester.pump(total);
}

/// Drag the first ListView until [finder] is built and on stage (ListView
/// children are lazy, so `scrollUntilVisible` cannot see them yet).
Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  int maxDrags = 12,
}) async {
  for (var i = 0; i < maxDrags; i++) {
    if (finder.evaluate().isNotEmpty) {
      await tester.ensureVisible(finder.first);
      await tester.pump();
      return;
    }
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump();
  }
  expect(finder, findsWidgets, reason: 'not found after scrolling');
}

/// Settle without `pumpAndSettle` (the record screen keeps a periodic timer).
Future<void> pumpTimes(WidgetTester tester, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump();
  }
}
