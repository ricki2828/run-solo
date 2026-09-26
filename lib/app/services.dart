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
import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';
import '../platform/pigeon_gateway.dart';
import '../platform/transfer_gateway.dart';
import '../state/history_store.dart';
import '../state/live_context.dart';
import '../state/max_hr.dart';
import '../state/recording_controller.dart';
import '../state/sessions.dart';
import '../state/settings.dart';
import '../state/weather.dart';
import '../state/zone_memento.dart';

const bool kFakePlatform = bool.fromEnvironment('RUN_SOLO_FAKE');

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
    SessionsController? sessions,
    RecordingController? recording,
    DateTime Function()? now,
    ZoneMementoStore? zoneMemento,
    this.weather,
    this.live,
  }) : now = now ?? DateTime.now,
       sessions = sessions ?? SessionsController(MemorySessionsStore()),
       recording =
           recording ??
           RecordingController(
             recorder,
             now: now,
             zoneMemento: zoneMemento,
             maxHr: () => MaxHr.resolve(
               settings.settings,
               (now ?? DateTime.now)(),
             ).maxHr,
           );

  final RecorderGateway recorder;
  final BleGateway ble;
  final PermissionsGateway permissions;
  final SettingsController settings;
  final RunStore history;
  final MapSurfaceFactory maps;
  final TransferGateway transfer;
  final StorageGateway storage;
  final RecordingController recording;
  final DateTime Function() now;

  /// Weather per finished run (W1); null in tests and the fake APK.
  final WeatherQueue? weather;

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
      unawaited(_weatherPass(() => w.enqueue(id)));
    });
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

  /// Saved custom Intervals templates (`state/sessions.json`, plan §3.4).
  final SessionsController sessions;

  /// The session Start would run now (A8 session card).
  engine.SessionSpec get pickedSession =>
      settings.settings.session(sessions.sessions);

  /// The engine profile from settings (plan D3 `maxHrFor` inputs).
  engine.UserProfile get profile => MaxHr.profileFor(settings.settings, now());

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
    FakeStorageGateway? storage,
    DateTime Function()? now,
    List<CustomSession> customSessions = const [],
  }) {
    final rec = recorder ?? FakeRecorderGateway(autoTick: true, now: now);
    final settingsCtl = SettingsController(
      MemorySettingsStore(settings),
      settings,
    );
    final clock = now ?? DateTime.now;
    return AppServices(
      recorder: rec,
      ble: ble ?? FakeBleGateway(),
      permissions: permissions ?? FakePermissionsGateway(),
      settings: settingsCtl,
      history: MemoryRunStore(
        runs: List.of(runs),
        files: List.of(files),
        sidecars: Map.of(sidecars),
        fake: rec,
        profile: () => MaxHr.profileFor(settingsCtl.settings, clock()),
        now: clock,
      ),
      maps: maps ?? const FakeMapSurfaceFactory(),
      transfer: transfer ?? FakeTransferGateway(),
      storage: storage ?? FakeStorageGateway(),
      now: now,
      sessions: SessionsController(
        MemorySessionsStore(customSessions),
        now: now,
      )..preload(customSessions),
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
    final history = FileRunStore(
      Directory('${support.path}/runs'),
      profile: () => MaxHr.profileFor(settings.settings, DateTime.now()),
    );
    final services = AppServices(
      recorder: PigeonRecorderGateway(),
      ble: PigeonBleGateway(),
      permissions: PigeonPermissionsGateway(),
      settings: settings,
      history: history,
      maps: const GoogleMapSurfaceFactory(),
      transfer: const ShareSheetTransferGateway(),
      storage: PigeonStorageGateway(),
      zoneMemento: FileZoneMementoStore(Directory('${support.path}/state')),
      live: LiveContextSource(indexFile: history.indexFile),
      weather: WeatherQueue(
        file: File('${support.path}/state/weather-queue.json'),
        store: history,
        provider: const OpenMeteoProvider(),
        enabled: () => settings.settings.weatherPerRun,
      ),
      sessions: sessions,
    );
    services.startWeather();
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
