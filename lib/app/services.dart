/// Composition root. `AppServices.of(context)` is the only way screens reach
/// the gateways, so tests inject fakes and the APK can run on
/// `--dart-define=RUN_SOLO_FAKE=true` before the Kotlin service lands.
library;

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
import '../state/max_hr.dart';
import '../state/recording_controller.dart';
import '../state/settings.dart';

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
    RecordingController? recording,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       recording =
           recording ??
           RecordingController(
             recorder,
             now: now,
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
  final RecordingController recording;
  final DateTime Function() now;

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
    DateTime Function()? now,
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
      now: now,
    );
  }

  static Future<AppServices> production() async {
    final support = await getApplicationSupportDirectory();
    final settings = SettingsController(
      FileSettingsStore(Directory('${support.path}/state')),
    );
    await settings.load();
    return AppServices(
      recorder: PigeonRecorderGateway(),
      ble: PigeonBleGateway(),
      permissions: PigeonPermissionsGateway(),
      settings: settings,
      history: FileRunStore(
        Directory('${support.path}/runs'),
        profile: () => MaxHr.profileFor(settings.settings, DateTime.now()),
      ),
      maps: const GoogleMapSurfaceFactory(),
      transfer: const ShareSheetTransferGateway(),
    );
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
