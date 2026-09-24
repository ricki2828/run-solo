package app.runsolo.platform

/**
 * Phase 0 placeholders. They report an idle recorder and never start anything.
 * Real implementations (RecorderService, BleHrClient) land in Phase 1.
 */
class RecorderApiStub : RecorderApi {
    override fun start(mode: RecordMode, preset: Preset?, units: Units): StartResult =
        StartResult(runId = null, error = StartError.NO_FINE_PERMISSION)

    override fun pause() = Unit

    override fun resume() = Unit

    override fun lap(source: LapSource) = Unit

    override fun stop(): String? = null

    override fun status(): RecorderStatus =
        RecorderStatus(
            state = RecorderState.IDLE,
            runId = null,
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

    override fun finalise(runId: String) = Unit

    override fun setCues(enabled: Boolean) = Unit
}

class BleApiStub : BleApi {
    override fun bleScan(callback: (Result<List<BleDevice>>) -> Unit) {
        callback(Result.success(emptyList()))
    }

    override fun blePair(address: String) = Unit

    override fun bleForget() = Unit
}

/** Never emits; keeps the EventChannel registered so Dart can subscribe without an error. */
class RecorderEventsStub : RecorderEventsStreamHandler() {
    override fun onListen(p0: Any?, sink: PigeonEventSink<RecorderEvent>) = Unit

    override fun onCancel(p0: Any?) = Unit
}
