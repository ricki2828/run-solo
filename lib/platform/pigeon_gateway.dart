/// Real wiring: the gateways over the Pigeon-generated `RecorderApi`,
/// `PermissionsApi` and `BleApi`. Thin on purpose; the Kotlin side owns
/// recording state (plan §2 rule 2).
library;

import 'gateway.dart';
import 'platform.dart';

class PigeonRecorderGateway implements RecorderGateway {
  PigeonRecorderGateway({RecorderApi? api}) : _api = api ?? RecorderApi();
  final RecorderApi _api;

  @override
  Stream<RecorderEvent> get events => recorderEventStream();

  @override
  Future<StartResult> start(
    RecordMode mode,
    SessionSpec? spec,
    Units units, {
    LiveContext? liveContext,
  }) => _api.start(mode, spec, units, liveContext);

  @override
  Future<void> pause() => _api.pause();

  @override
  Future<void> resume() => _api.resume();

  @override
  Future<void> lap(LapSource source) => _api.lap(source);

  @override
  Future<void> startReps() => _api.startReps();

  @override
  Future<String?> stop() => _api.stop();

  @override
  Future<RecorderStatus> status() => _api.status();

  @override
  Future<List<OrphanJournal>> recover() => _api.recover();

  @override
  Future<StartResult> resumeRecovered(String runId) =>
      _api.resumeRecovered(runId);

  @override
  Future<String?> finalise(String runId) => _api.finalise(runId);

  @override
  Future<void> discardJournal(String runId) => _api.discardJournal(runId);

  @override
  Future<bool> discard() => _api.discardRun();

  @override
  Future<void> setCues(bool enabled) => _api.setCues(enabled);

  @override
  Future<void> startGpsProbe() => _api.startGpsProbe();

  @override
  Future<void> stopGpsProbe() => _api.stopGpsProbe();

  @override
  Future<void> setKmSplits(bool enabled) => _api.setKmSplits(enabled);

  @override
  Future<void> muteTips() => _api.muteTips();

  @override
  Future<void> setVolumeKeyLaps(bool enabled) => _api.setVolumeKeyLaps(enabled);
}

class PigeonBleGateway implements BleGateway {
  PigeonBleGateway({BleApi? api}) : _api = api ?? BleApi();
  final BleApi _api;

  @override
  Future<List<BleDevice>> scan() => _api.bleScan();

  @override
  Future<void> pair(BleDevice device) => _api.blePair(device.address);

  @override
  Future<void> forget() => _api.bleForget();

  @override
  Future<BleStatus> status() => _api.bleStatus();
}

class PigeonStorageGateway implements StorageGateway {
  PigeonStorageGateway({StorageApi? api}) : _api = api ?? StorageApi();
  final StorageApi _api;

  @override
  Future<BackupStatus> backupStatus() => _api.backupStatus();

  @override
  Future<List<String>> enforceBackupBudget() => _api.enforceBackupBudget();
}

class PigeonPermissionsGateway implements PermissionsGateway {
  PigeonPermissionsGateway({PermissionsApi? api})
    : _api = api ?? PermissionsApi();
  final PermissionsApi _api;

  @override
  Future<PermissionSnapshot> status() async =>
      PermissionSnapshot.fromStatus(await _api.permissionStatus());

  @override
  Future<bool> request(PermissionKind kind) => _api.requestPermission(kind);

  @override
  Future<void> openBatterySettings() => _api.openBatterySettings();

  /// The direct `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` dialog is Play-
  /// restricted and was dropped from the contract (24-Sep review); plan
  /// §10's path stands: open the battery settings page and re-read.
  @override
  Future<bool> requestBatteryExemption() async {
    await _api.openBatterySettings();
    return (await _api.permissionStatus()).batteryUnrestricted;
  }

  @override
  Future<void> openAppSettings() => _api.openAppSettings();

  @override
  Future<bool> volumeKeyLapsSupported() => _api.volumeKeyLapsSupported();

  @override
  Future<void> setKeepScreenOn(bool enabled) => _api.setKeepScreenOn(enabled);
}
