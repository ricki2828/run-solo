/// Composition root. `AppServices.of(context)` is the only way screens reach
/// the gateways, so tests inject fakes and the APK can run on
/// `--dart-define=RUN_SOLO_FAKE=true` before the Kotlin service lands.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:run_engine/run_engine.dart' as engine;

import '../map/google_map_surface.dart';
import '../map/map_surface.dart';
import '../map/topo_map_surface.dart';
import '../map/topo_maplibre.dart';
import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';
import '../platform/health_gateway.dart';
import '../platform/pigeon_gateway.dart';
import '../platform/transfer_gateway.dart';
import '../state/block_plan.dart';
import '../state/companion.dart';
import '../state/courses.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/hr_zone_choice.dart';
import '../state/max_hr.dart';
import '../state/places.dart';
import '../state/route_library.dart';
import '../state/recording_controller.dart';
import '../state/intervals_icu.dart';
import '../state/load_guard.dart';
import '../state/send_runs.dart';
import '../state/watch_export.dart';
import '../state/sessions.dart';
import '../state/settings.dart';
import '../state/weather.dart';
import '../state/zone_memento.dart';
import '../topo/pack_manager.dart';
import '../topo/topo_files.dart';

const bool kFakePlatform = bool.fromEnvironment('RUN_SOLO_FAKE');

/// Where offline map packs are hosted (the bucket root holding regions.json).
/// Public Cloudflare R2 bucket; override with `--dart-define=TOPO_BASE_URL=`
/// (empty turns Offline maps off: no PackManager, no Settings row).
const String kTopoBaseUrl = String.fromEnvironment(
  'TOPO_BASE_URL',
  defaultValue: 'https://pub-b1d26357d23144f8a9c96f35588be8fe.r2.dev',
);

class AppServices {
  AppServices({
    required this.recorder,
    required this.ble,
    required this.permissions,
    required this.settings,
    required this.history,
    required this.maps,
    required this.transfer,
    required this.storage,
    required this.health,
    SessionsController? sessions,
    CourseNamesController? courseNames,
    BlockPlanController? plans,
    RouteLibrary? routes,
    RecordingController? recording,
    DateTime Function()? now,
    ZoneMementoStore? zoneMemento,
    this.weather,
    this.live,
    this.topo,
    this.companion,
    PlaceGateway? placeGateway,
    List<ExportTarget>? exportTargets,
    Future<Directory> Function()? tempDir,
  }) : places = PlaceResolver(
         store: history,
         gateway: placeGateway ?? FakePlaceGateway(),
       ),
       sender = SendCoordinator(
         history: history,
         settings: settings,
         targets:
             exportTargets ??
             defaultExportTargets(
               transfer,
               health,
               now: now,
               companion: companion == null
                   ? null
                   : CompanionTarget(
                       controller: companion,
                       now: now,
                       zones: () => HrZoneChoice.resolve(
                         settings.settings,
                         (now ?? DateTime.now)(),
                       ),
                     ),
             ),
         now: now,
       ),
       watch = WatchExporter(transfer: transfer, tempDir: tempDir, now: now),
       now = now ?? DateTime.now,
       sessions = sessions ?? SessionsController(MemorySessionsStore()),
       courseNames =
           courseNames ?? CourseNamesController(MemoryCourseNamesStore()),
       plans = plans ?? BlockPlanController(MemoryBlockPlanStore()),
       routes = routes ?? RouteLibrary(MemoryRouteStore(), now: now),
       recording =
           recording ??
           RecordingController(
             recorder,
             now: now,
             zoneMemento: zoneMemento,
             zones: () => HrZoneChoice.resolve(
               settings.settings,
               (now ?? DateTime.now)(),
             ),
           ) {
    // The companion reads the stored plan through this object, which the
    // initializer list cannot reach.
    for (final t in sender.targets) {
      if (t is CompanionTarget) t.planFacts ??= planFactsFor;
    }
  }

  /// The plan's facts for a run's companion summary: the stored block, judged
  /// against History's index rows exactly as Home shows it. Empty with no plan.
  Future<Map<String, Object?>> planFactsFor(String runId) async {
    final plan = plans.plan;
    if (plan == null) return const {};
    var scores = const <engine.IdentityLane, engine.IdentityScore>{};
    try {
      scores = live?.identityScores() ?? scores;
    } catch (_) {}
    final at = now();
    final ctx = PlanContext(
      runs: await history.list(),
      scores: scores,
      now: at,
      maxHr: maxHr.maxHr,
    );
    return companionPlanFacts(
      ctx.view(
        plan,
        loadDismissed: LoadDismissal.dismissed(settings.settings, at),
      ),
      runId,
    );
  }

  final RecorderGateway recorder;
  final BleGateway ble;
  final PermissionsGateway permissions;
  final SettingsController settings;
  final RunStore history;
  final MapSurfaceFactory maps;
  final TransferGateway transfer;
  final HealthGateway health;
  final StorageGateway storage;
  final RecordingController recording;

  /// Follow a route: the routes kept on the phone.
  final RouteLibrary routes;
  final DateTime Function() now;

  /// Names a run's start point once it is finished (and lazily for old runs
  /// when their detail opens).
  final PlaceResolver places;

  /// Send runs: the Send button and the automatic after-run sends.
  final SendCoordinator sender;

  /// Send to watch: a session as a FIT workout, a route as a GPX course.
  final WatchExporter watch;

  /// Weather per finished run (W1); null in tests and the fake APK.
  final WeatherQueue? weather;

  /// Offline map packs; null when no hosting is configured (and in most
  /// tests), which hides Settings > Offline maps.
  final PackManager? topo;

  /// The run companion; null unless the build has `COMPANION=1` (dogfood
  /// only), which hides every companion surface.
  final CompanionController? companion;

  /// The live compare's context at Start (LC1); null in tests and the fake
  /// APK. Only used when `kLiveCompare` is on.
  final LiveContextSource? live;
  String? _lastFinishedRunId;

  /// Queues and drains weather: once on open (runs finished or imported
  /// while the app was closed) and whenever a recording finishes. Never
  /// during a run; failures only log.
  void startWeather() {
    final w = weather;
    if (w == null) return;
    unawaited(_weatherPass(w.reconcile));
    recording.addListener(() {
      final s = recording.snapshot;
      if (s.state != RecorderState.idle || s.runId == null) return;
      if (s.runId == _lastFinishedRunId) return;
      _lastFinishedRunId = s.runId;
      final id = s.runId!;
      // Hold first scoring before any asynchronous work can let Home or the
      // result screen freeze a verdict without its heat. Non-intervals and
      // an off weather setting have no heat-adjusted verdict to await.
      if (s.mode == RecordMode.intervals &&
          settings.settings.weatherPerRun &&
          history is FileRunStore) {
        (history as FileRunStore).holdFirstVerdictForWeather(id);
        unawaited(_weatherForNewVerdict(w, id));
      } else {
        unawaited(_weatherPass(() => w.enqueue(id)));
      }
    });
  }

  String? _lastPlacedRunId;

  /// Names each finished run's start point once, off the run's critical
  /// path (never during a run). A failure only logs; the run's detail
  /// retries when it opens.
  void startPlaces() {
    recording.addListener(() {
      final s = recording.snapshot;
      if (s.state != RecorderState.idle || s.runId == null) return;
      if (s.runId == _lastPlacedRunId) return;
      _lastPlacedRunId = s.runId;
      unawaited(places.onFinished(s.runId!, now: now()));
    });
  }

  String? _lastSentRunId;

  /// Sends each finished run to the automatic targets the runner switched on
  /// (none by default), and retries what an offline run left behind once on
  /// open. Off the run's critical path; a failure only logs.
  void startSends() {
    for (final t in sender.targets) {
      if (t is ShareFileTarget) unawaited(t.sweep());
      if (t is IntervalsIcuTarget) unawaited(t.load());
    }
    unawaited(
      _sendPass(() async {
        // Token first, or the first open after a restart finds the
        // companion off and skips it.
        await companion?.load();
        await sender.reconcile();
        if (companion != null) await flushCompanionFeels(history, companion!);
      }),
    );
    recording.addListener(() {
      final s = recording.snapshot;
      if (s.state != RecorderState.idle || s.runId == null) return;
      if (s.runId == _lastSentRunId) return;
      _lastSentRunId = s.runId;
      final id = s.runId!;
      unawaited(_sendPass(() => sender.sendAuto(id)));
    });
  }

  Future<void> _sendPass(Future<void> Function() pass) async {
    try {
      await pass();
    } catch (e) {
      debugPrint('send: pass failed ($e)');
    }
  }

  Future<void> _weatherForNewVerdict(WeatherQueue w, String id) async {
    final store = history as FileRunStore;
    try {
      if (await store.hasFrozenVerdict(id)) return;
      await w.fetchForVerdict(id).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      await store.freezeWithoutWeather(id);
      return;
    } catch (e) {
      debugPrint('weather: fetch failed for $id ($e)');
    } finally {
      store.releaseFirstVerdictForWeather(id);
    }
  }

  Future<void> _weatherPass(Future<void> Function() before) async {
    final w = weather!;
    try {
      await before();
      final r = await w.drain();
      // "Retried ... after any successful fetch" (§18.5): a success means
      // the network is back, so give the runs left behind one more go.
      if (r.ok.isNotEmpty && !r.stoppedEarly) await w.drain();
    } catch (e) {
      debugPrint('weather: pass failed ($e)');
    }
  }

  /// K1: the runner's names for event courses (`state/courses.json`).
  final CourseNamesController courseNames;

  /// The 4-week progress block (`state/plan.json`), if one is running.
  final BlockPlanController plans;

  /// Saved custom Intervals templates (`state/sessions.json`, plan §3.4).
  final SessionsController sessions;

  /// The session Start would run now (A8 session card).
  engine.SessionSpec get pickedSession =>
      settings.settings.session(sessions.sessions);

  /// The engine profile from settings (plan D3 `maxHrFor` inputs).
  engine.UserProfile get profile => MaxHr.profileFor(settings.settings, now());

  /// The runner's chosen HR zones (Settings → Heart rate zones).
  engine.HrZones get hrZones => HrZoneChoice.resolve(settings.settings, now());

  MaxHrResolution get maxHr => MaxHr.resolve(settings.settings, now());

  /// Everything in-process; used by tests and the fake APK.
  factory AppServices.fake({
    FakeRecorderGateway? recorder,
    FakeBleGateway? ble,
    FakePermissionsGateway? permissions,
    AppSettings settings = const AppSettings(),
    List<RunSummary> runs = const [],
    List<engine.RunFile> files = const [],
    Map<String, engine.RunSidecar> sidecars = const {},
    MapSurfaceFactory? maps,
    FakeTransferGateway? transfer,
    FakeHealthGateway? health,
    FakeStorageGateway? storage,
    DateTime Function()? now,
    List<CustomSession> customSessions = const [],
    Map<String, String> courseNames = const {},
    engine.BlockPlan? plan,
    List<engine.SavedRoute> routes = const [],
    LiveContextSource? live,
    WeatherQueue? weather,
    PackManager? topo,
    RunStore? history,
    PlaceGateway? places,
    List<ExportTarget>? exportTargets,
    CompanionController? companion,
  }) {
    final rec = recorder ?? FakeRecorderGateway(autoTick: true, now: now);
    final settingsCtl = SettingsController(
      MemorySettingsStore(settings),
      settings,
    );
    final clock = now ?? DateTime.now;
    final xfer = transfer ?? FakeTransferGateway();
    final fakeHealth = health ?? FakeHealthGateway();
    return AppServices(
      recorder: rec,
      ble: ble ?? FakeBleGateway(),
      permissions: permissions ?? FakePermissionsGateway(),
      settings: settingsCtl,
      history:
          history ??
          MemoryRunStore(
            runs: List.of(runs),
            files: List.of(files),
            sidecars: Map.of(sidecars),
            fake: rec,
            profile: () => MaxHr.profileFor(settingsCtl.settings, clock()),
            now: clock,
          ),
      maps: maps ?? const FakeMapSurfaceFactory(),
      transfer: xfer,
      health: fakeHealth,
      storage: storage ?? FakeStorageGateway(),
      now: now,
      sessions: SessionsController(
        MemorySessionsStore(customSessions),
        now: now,
      )..preload(customSessions),
      courseNames: CourseNamesController(MemoryCourseNamesStore(courseNames))
        ..preload(courseNames),
      plans: BlockPlanController(MemoryBlockPlanStore(plan))..preload(plan),
      routes: RouteLibrary(
        MemoryRouteStore(routes),
        now: now,
        offIsolate: false,
      )..preload(routes),
      live: live,
      weather: weather,
      topo: topo,
      companion: companion,
      placeGateway: places,
      tempDir: () async => Directory.systemTemp,
      exportTargets:
          exportTargets ??
          defaultExportTargets(
            xfer,
            fakeHealth,
            tempDir: () async => Directory.systemTemp,
            now: now,
            secrets: MemorySecretStore(),
            companion: companion == null
                ? null
                : CompanionTarget(controller: companion, now: now),
          ),
    );
  }

  static Future<AppServices> production() async {
    final support = await getApplicationSupportDirectory();
    final settings = SettingsController(
      FileSettingsStore(Directory('${support.path}/state')),
    );
    await settings.load();
    final sessions = SessionsController(
      FileSessionsStore(Directory('${support.path}/state')),
    );
    await sessions.load();
    final courseNames = CourseNamesController(
      FileCourseNamesStore(Directory('${support.path}/state')),
    );
    await courseNames.load();
    final plans = BlockPlanController(
      FileBlockPlanStore(Directory('${support.path}/state')),
    );
    await plans.load();
    final routes = RouteLibrary(
      FileRouteStore(Directory('${support.path}/state')),
    );
    await routes.load();
    final history = FileRunStore(
      Directory('${support.path}/runs'),
      profile: () => MaxHr.profileFor(settings.settings, DateTime.now()),
    );
    PackManager? topo;
    if (kTopoBaseUrl.isNotEmpty) {
      topo = PackManager(
        root: Directory('${support.path}/topo'),
        baseUrl: Uri.parse(kTopoBaseUrl),
      );
      await topo.load();
    }
    const transfer = ShareSheetTransferGateway();
    final companion = kCompanion
        ? CompanionController(
            store: SecureSecretStore(),
            transfer: transfer,
            // Only runs that finish after "Turn on" are sent.
            onEnrolled: (now) => settings.update(
              (x) => x.withAutoSend(CompanionTarget.targetId, true, now),
            ),
          )
        : null;
    final services = AppServices(
      recorder: PigeonRecorderGateway(),
      ble: PigeonBleGateway(),
      permissions: PigeonPermissionsGateway(),
      settings: settings,
      history: history,
      maps: topo == null
          ? const GoogleMapSurfaceFactory()
          : TopoMapSurfaceFactory(
              packs: topo,
              settings: settings,
              fallback: const GoogleMapSurfaceFactory(),
              engine: MapLibreTopoEngine(TopoFiles(packsRoot: topo.root)),
            ),
      transfer: transfer,
      companion: companion,
      health: PigeonHealthGateway(),
      storage: PigeonStorageGateway(),
      placeGateway: PigeonPlaceGateway(),
      zoneMemento: FileZoneMementoStore(Directory('${support.path}/state')),
      live: LiveContextSource(indexFile: history.indexFile),
      weather: WeatherQueue(
        file: File('${support.path}/state/weather-queue.json'),
        store: history,
        provider: const OpenMeteoProvider(),
        enabled: () => settings.settings.weatherPerRun,
      ),
      topo: topo,
      sessions: sessions,
      courseNames: courseNames,
      plans: plans,
      routes: routes,
    );
    services.startWeather();
    services.startPlaces();
    services.startSends();
    return services;
  }

  static AppServices of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppServicesScope>();
    assert(scope != null, 'No AppServicesScope above this widget');
    return scope!.services;
  }
}

class AppServicesScope extends InheritedWidget {
  const AppServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  @override
  bool updateShouldNotify(AppServicesScope old) => old.services != services;
}
