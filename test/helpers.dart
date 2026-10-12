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
import 'package:run_solo/platform/health_gateway.dart';
import 'package:run_solo/platform/session_codec.dart';
import 'package:run_solo/platform/transfer_gateway.dart';
import 'package:run_solo/splash/intro_gate.dart';
import 'package:run_solo/state/companion.dart';
import 'package:run_solo/state/history_store.dart';
import 'package:run_solo/state/live_context.dart';
import 'package:run_solo/state/send_runs.dart';
import 'package:run_solo/state/sessions.dart';
import 'package:run_solo/state/settings.dart';
import 'package:run_solo/state/weather.dart';
import 'package:run_solo/topo/pack_manager.dart';

/// Fixed test clock so timer interpolation is zero and "3 days ago" is stable.
final DateTime testNow = DateTime(2026, 9, 24, 10, 0);
DateTime now() => testNow;

/// The default Norwegian 4x4 (4 × 4:00, 3:00 recoveries) as the recorder
/// receives it, expanded by the engine catalogue.
SessionSpec standardPreset() => fourByFourSpec();

SessionSpec fourByFourSpec({int reps = 4, int recoverySeconds = 180}) =>
    engine.SessionCatalogue.expand(
      engine.SessionSpec.norwegian4x4Id,
      reps: reps,
      recovery: engine.SessionStep.recovery(recoverySeconds, rep: 1),
    ).toPigeon();

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
  FakeHealthGateway? health,
  FakeStorageGateway? storage,
  List<CustomSession> customSessions = const [],
  Map<String, String> courseNames = const {},
  engine.BlockPlan? plan,
  List<engine.SavedRoute> routes = const [],
  LiveContextSource? live,
  WeatherQueue? weather,
  PackManager? topo,
  RunStore? history,
  FakePlaceGateway? places,
  List<ExportTarget>? exportTargets,
  CompanionController? companion,
}) => AppServices.fake(
  companion: companion,
  places: places,
  exportTargets: exportTargets,
  live: live,
  weather: weather,
  topo: topo,
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
  health: health,
  storage: storage,
  now: now,
  customSessions: customSessions,
  courseNames: courseNames,
  plan: plan,
  routes: routes,
  history: history,
);

/// A catalogue preset expanded as the recorder receives it.
SessionSpec presetSpec(String id, {int? reps}) =>
    engine.SessionCatalogue.expand(id, reps: reps).toPigeon();

/// Mounts the app. With [pushRoute] the home is a launcher that pushes that
/// named route on first frame, so screens that pop can be tested.
bool _fontsLoaded = false;

/// Every family in the app's FontManifest (Saira Extra Condensed, Schibsted Grotesk and
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
  IntroKind intro = IntroKind.none,
  bool onboarding = false,
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
      intro: intro,
      onboarding: onboarding,
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
  mode: mode ?? (fourByFour ? RecordMode.intervals : RecordMode.free),
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

/// Tap a mounted control after scrolling it into the visible viewport.
/// Aurora Start keeps the long form mounted for accessibility, but a runner
/// must scroll to its lower choices before tapping them on a phone.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder);
}

/// A phone-width view tall enough that a long scrolling page builds every
/// section: `find` skips list children outside the viewport, so a test of a
/// section below the fold needs this (360 x 3000 logical). Call it after
/// [pumpApp], which resets the view to a phone.
Future<void> useTallPhoneView(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 9000);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pump();
}

/// Settle without `pumpAndSettle` (the record screen keeps a periodic timer).
Future<void> pumpTimes(WidgetTester tester, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump();
  }
}

/// Ready screen to GO: taps its START, runs the 3 s countdown (the default)
/// and lets the GO hold finish, so the recorder has started and the
/// recording screen is up.
Future<void> goFromReady(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ready-start')));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 3));
  await tester.pump(const Duration(seconds: 1));
  await pumpTimes(tester, 4);
  await settleAnimations(tester);
}

/// The picker's READY UP, then [goFromReady].
Future<void> readyAndGo(WidgetTester tester) async {
  final up = find.byKey(const ValueKey('start-ready-up'));
  await tester.ensureVisible(up);
  await tester.tap(up);
  await pumpTimes(tester, 3);
  await settleAnimations(tester);
  await goFromReady(tester);
}
