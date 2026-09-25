package app.runsolo.platform

/**
 * Phase 0 placeholders. They report an idle recorder and never start anything.
 * Real implementations (RecorderService, BleHrClient) land in Phase 1.
 */
class RecorderApiStub : RecorderApi {
    override fun start(mode: RecordMode, preset: Preset?, units: Units): StartResult =
        StartResult(runId = null, error = StartError.NO_FINE_PERMISSION)

    override fun startReplay(mode: RecordMode, preset: Preset?, units: Units, replay: ReplayConfig): StartResult =
        StartResult(runId = null, error = StartError.REPLAY_UNAVAILABLE)

    override fun resumeRecovered(runId: String): StartResult =
        StartResult(runId = null, error = StartError.NO_SUCH_JOURNAL)

    override fun pause() = Unit

    override fun resume() = Unit

    override fun lap(source: LapSource) = Unit

    override fun startReps() = Unit

    override fun stop(): String? = null

    override fun status(): RecorderStatus =
        RecorderStatus(
            state = RecorderState.IDLE,
            runId = null,
            mode = RecordMode.FREE,
            laps = emptyList(),
            elapsedMs = 0,
            lapIndex = 0,
            gpsFix = false,
            hrConnected = false,
            phase = Phase.NONE,
            repIndex = 0,
            phaseRemainingMs = 0,
            preset = null,
            journalOk = true,
        )

    override fun recover(): List<OrphanJournal> = emptyList()

    override fun finalise(runId: String): String? = null

    override fun discardJournal(runId: String) = Unit

    override fun setCues(enabled: Boolean) = Unit
    override fun setVolumeKeyLaps(enabled: Boolean) = Unit

    override fun listRunFiles(): Map<String, String> = emptyMap()

    override fun exitDiagnosis(runId: String): ExitDiagnosis =
        ExitDiagnosis(runId = runId, reason = ExitReason.NONE, timestampMs = 0, description = null, manufacturer = "")
}

class StorageApiStub : StorageApi {
    override fun backupStatus(): BackupStatus =
        BackupStatus(backedUpBytes = 0, budgetBytes = 15L * 1024 * 1024, quotaBytes = 25L * 1024 * 1024, archivedRunCount = 0, overBudget = false)

    override fun enforceBackupBudget(): List<String> = emptyList()
}

class PermissionsApiStub : PermissionsApi {
    override fun permissionStatus(): PermissionStatus =
        PermissionStatus(
            fineLocation = false,
            approximateOnly = false,
            locationEnabled = false,
            notifications = false,
            bluetooth = false,
            batteryUnrestricted = false,
            gmsAvailable = false,
        )

    override fun requestPermission(kind: PermissionKind, callback: (Result<Boolean>) -> Unit) {
        callback(Result.success(false))
    }

    override fun openBatterySettings() = Unit

    override fun openAppSettings() = Unit

    override fun setKeepScreenOn(enabled: Boolean) = Unit

    override fun volumeKeyLapsSupported() = true
}

class BleApiStub : BleApi {
    override fun bleScan(callback: (Result<List<BleDevice>>) -> Unit) {
        callback(Result.success(emptyList()))
    }

    override fun blePair(address: String) = Unit

    override fun bleForget() = Unit

    override fun bleStatus(): BleStatus = BleStatus(connected = false, address = null, name = null, lastHr = null, adapterOn = false)
}

/** Never emits; keeps the EventChannel registered so Dart can subscribe without an error. */
class RecorderEventsStub : RecorderEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<RecorderEvent>) = Unit

    override fun onCancel(p0: Any?) = Unit
}
