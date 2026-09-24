/// Composition root. `AppServices.of(context)` is the only way screens reach
/// the gateways, so tests inject fakes and the APK can run on
/// `--dart-define=RUN_SOLO_FAKE=true` before the Kotlin service lands.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/fake_gateway.dart';
import '../platform/gateway.dart';
import '../platform/pigeon_gateway.dart';
import '../state/history_store.dart';
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
    RecordingController? recording,
  }) : recording = recording ?? RecordingController(recorder);

  final RecorderGateway recorder;
  final BleGateway ble;
  final PermissionsGateway permissions;
  final SettingsController settings;
  final HistoryStore history;
  final RecordingController recording;

  /// Everything in-process; used by tests and the fake APK.
  factory AppServices.fake({
    FakeRecorderGateway? recorder,
    FakeBleGateway? ble,
    FakePermissionsGateway? permissions,
    AppSettings settings = const AppSettings(),
    List<RunSummary> runs = const [],
    DateTime Function()? now,
  }) {
    final rec = recorder ?? FakeRecorderGateway(autoTick: true, now: now);
    return AppServices(
      recorder: rec,
      ble: ble ?? FakeBleGateway(),
      permissions: permissions ?? FakePermissionsGateway(),
      settings: SettingsController(MemorySettingsStore(settings), settings),
      history: MemoryHistoryStore(List.of(runs), rec),
      recording: RecordingController(rec, now: now),
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
      history: FileHistoryStore(Directory('${support.path}/runs')),
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
