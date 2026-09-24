package app.runsolo.record

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import app.runsolo.ble.BleHolder
import app.runsolo.ble.BleHrClient
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.gps.LivePace
import app.runsolo.core.gps.MovingDetector
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalWriter
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.journal.Replay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.LocationFix
import app.runsolo.core.run.RunPaths
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.HrReading
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.run.Finaliser
import app.runsolo.platform.CueEvent
import app.runsolo.platform.FaultEvent
import app.runsolo.platform.FaultKind
import app.runsolo.platform.LapEvent
import app.runsolo.platform.LapSummary
import app.runsolo.platform.PhaseEvent
import app.runsolo.platform.RecorderEventBus
import app.runsolo.platform.RecorderStatus
import app.runsolo.platform.StateEvent
import app.runsolo.platform.TickEvent
import app.runsolo.platform.toPigeon

/**
 * One run in progress: the core-jvm pieces wired to the device (plan §2 rule 2 — recording
 * state lives here, not in Dart). Created by `RecorderApi.start`/`resumeRecovered` from the
 * visible Activity, adopted by [RecorderService] which supplies the foreground context, the
 * wake lock and the sensors. Everything runs on the main thread; the work is 1 Hz.
 *
 * Clock: `SystemClock.elapsedRealtime()`, or the replay's virtual clock in replay mode.
 */
class RecordingSession(
    context: Context,
    val runId: String,
    val mode: RunMode,
    val preset: Preset?,
    val units: Units,
    private val replay: ReplayRunner?,
    volumeKeyLaps: Boolean,
) {
    // Application context: the session outlives the Activity (swipe from Recents keeps the
    // service alive; an Activity context would unbind TTS and leak the Activity).
    private val context: Context = context.applicationContext
    private val fs = JvmFileSystem(this.context.filesDir.toPath())
    private val writer = JournalWriter(fs, runId, onWriteFailed = { e ->
        Log.w(TAG, "journal write failed: $e")
        fault(FaultKind.JOURNAL_WRITE_FAILED, "Could not write to storage: ${e.message}")
    })
    private val ticker = SampleTicker(wall = { System.currentTimeMillis() })
    private val livePace = LivePace()
    private val moving = MovingDetector()
    private val handler = Handler(Looper.getMainLooper())
    private val cues = CuePlayer(this.context)
    private val lapInput = LapInput(this.context) { lap(LapSource.volumeKey) }
    private val volumeKeyLapsEnabled = volumeKeyLaps
    private lateinit var core: RecorderCore
    private var location: LocationSource? = null
    private var ble: BleHrClient? = null
    private var tickRunnable: Runnable? = null
    private var attached = false
    private var finished = false

    /** Wall time the run started (from the header; survives a resume). */
    var startWallMs: Long = 0
        private set
    private var lapCount = 0
    private val laps = ArrayList<LapSummary>()
    private var lapStartT = 0L
    private var lapStartActive = 0L
    private var lapStartDist = 0.0
    private var lastTickEventWall = 0L
    private var lastNotificationRefreshWall = 0L
    private var gpsLostReported = false
    private var replayLapsPressed = 0
    private var hrConnected = false
    private var lastHr: Int? = null

    var onNotificationChanged: (() -> Unit)? = null
    var onReplayFinished: (() -> Unit)? = null

    val cuesEnabled: Boolean get() = cues.enabled
    val isReplay: Boolean get() = replay != null

    private fun clock(): Long = replay?.now() ?: SystemClock.elapsedRealtime()

    // ---- lifecycle ----

    /** Fresh run: header line, state machine at warmup/none. */
    fun startNew(device: String, app: String, tz: String) {
        val t = clock()
        startWallMs = System.currentTimeMillis()
        writer.open()
        writer.append(JournalLine.Header(t, startWallMs, runId, device, app, tz, mode, preset, units))
        core = RecorderCore(mode, preset, RecorderCore.Config(volumeKeyLaps = volumeKeyLapsEnabled))
        handle(core.start(t), t)
        lapStartT = t
        ExitDiagnostics.noteStart(context, runId, startWallMs)
        emitState()
    }

    /** Continue an orphaned journal after a kill (plan §3, W12): gap line, phase rebuilt from the journal. */
    fun startResumed(orphan: Replay) {
        val t = clock()
        val nowWall = System.currentTimeMillis()
        startWallMs = orphan.header.w
        writer.open() // drops a torn tail first
        val gap = (nowWall - orphan.lastWallMs).coerceAtLeast(0)
        writer.append(JournalLine.Gap(t, nowWall, gap))
        // Restore from the journal WITH the gap line, so elapsed time includes the dark span
        // exactly as the finalised file's timeline will (and a second kill cannot shift it).
        val replayed = try {
            JournalReplay.read(fs.readBytes(RunPaths.journal(runId)))
        } catch (_: Exception) {
            orphan
        }
        core = RecorderCore.restore(replayed, t, RecorderCore.Config(volumeKeyLaps = volumeKeyLapsEnabled))
        lapCount = core.lapCount
        lapStartT = t
        // Laps from the journal, with active time (pauses and gaps excluded) per lap.
        var lapT = 0L
        var inactive = 0L
        var pauseStart: Long? = null
        var prevActive = 0L
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Pause -> if (pauseStart == null) pauseStart = e.t
                is RunEvent.Resume -> pauseStart?.let { inactive += e.t - it; pauseStart = null }
                is RunEvent.Gap -> inactive += e.endT - e.t
                is RunEvent.Lap -> {
                    val active = e.t - inactive
                    laps.add(LapSummary(index = laps.size.toLong(), tMs = e.t, activeMs = active - prevActive, distanceM = 0.0, source = e.source.toPigeon()))
                    prevActive = active
                    lapT = e.t
                }
                else -> Unit
            }
        }
        if (laps.isNotEmpty()) lapStartT = t - (replayed.endT - lapT)
        lapStartActive = prevActive
        // Seed the live distance from the journal (same pause rule as the finaliser) so the
        // tick totals continue instead of restarting from zero; lap distance from the last marker.
        var paused = false
        var lastLapDist = 0.0
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Sample -> if (e.hasFix && !paused) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                is RunEvent.Pause -> paused = true
                is RunEvent.Resume -> { paused = false; ticker.filter.reanchor() }
                is RunEvent.Lap -> {
                    lastLapDist = ticker.filter.totalM
                    laps.indexOfFirst { it.tMs == e.t }.takeIf { it >= 0 }?.let { i -> laps[i] = laps[i].copy(distanceM = lastLapDist) }
                }
                else -> Unit
            }
        }
        ticker.filter.reanchor() // the runner moved during the dark span; do not count the jump
        lapStartDist = lastLapDist
        if (core.state == RecorderState.paused) ticker.onPause()
        ExitDiagnostics.noteResume(context, runId, nowWall)
        Log.i(TAG, "resumed $runId after ${gap / 1000}s gap; phase=${core.phase} rep=${core.repIndex} paused=${core.state == RecorderState.paused}")
        emitState()
    }

    /** Called by the service once it is in the foreground: sensors, cues, tick loop. */
    fun attachSensors(preferRawGps: Boolean, cuesEnabled: Boolean) {
        if (attached || finished) return
        attached = true
        cues.enabled = cuesEnabled
        cues.init()
        if (volumeKeyLapsEnabled) lapInput.enable()
        val r = replay
        if (r != null) {
            // One clock, one tick per delivered fix (see ReplaySource): no timer in replay mode.
            r.start(
                onFix = { fix ->
                    ticker.onFix(fix)
                    try {
                        tick(fix.t)
                    } catch (e: Exception) {
                        Log.e(TAG, "replay tick failed", e)
                    }
                },
                onHr = { ticker.onHr(it) },
            )
            return
        } else {
            location = LocationSource.create(context, preferRawGps).also { src ->
                try {
                    src.start { ticker.onFix(it) }
                } catch (e: Exception) {
                    Log.w(TAG, "location start failed: $e")
                    fault(FaultKind.GPS_LOST, "Location updates unavailable: ${e.message}")
                }
            }
            val client = BleHolder.client(context)
            ble = client
            client.listener = object : BleHrClient.Listener {
                override fun onReading(reading: HrReading) {
                    lastHr = reading.bpm
                    ticker.onHr(reading)
                }

                override fun onNoContact() {
                    lastHr = null
                    ticker.onHrNoContact()
                }

                override fun onLink(connected: Boolean) {
                    hrConnected = connected
                    writer.append(JournalLine.HrLink(clock(), System.currentTimeMillis(), connected))
                    if (!connected) fault(FaultKind.HR_DISCONNECTED, "Heart rate strap disconnected")
                    onNotificationChanged?.invoke()
                }
            }
            client.connectIfPaired()
        }
        scheduleTick()
    }

    fun detachSensors() {
        if (!attached) return
        attached = false
        tickRunnable?.let { handler.removeCallbacks(it) }
        tickRunnable = null
        location?.stop()
        location = null
        replay?.stop()
        ble?.let {
            it.listener = null
            it.disconnect()
        }
        ble = null
        lapInput.disable()
        cues.release()
    }

    private fun scheduleTick() {
        val period = 1000L
        val r = object : Runnable {
            override fun run() {
                if (!attached || finished) return
                try {
                    tick(clock())
                } catch (e: Exception) {
                    Log.e(TAG, "tick failed", e)
                }
                handler.postDelayed(this, period)
            }
        }
        tickRunnable = r
        handler.postDelayed(r, period)
    }

    // ---- the 1 Hz loop ----

    private fun tick(t: Long) {
        if (finished) return
        val r = replay
        if (r != null && replayLapsPressed < r.autoLapAtMs.size && core.status(t).elapsedMs >= r.autoLapAtMs[replayLapsPressed]) {
            replayLapsPressed++
            lap(LapSource.notification)
        }
        handle(core.tick(t), t)
        val samples = ticker.tick(t)
        for (s in samples) writer.append(s)
        val last = samples.last()
        var pace: Double? = null
        if (last.hasFix) {
            pace = livePace.update(last.t, ticker.distanceM)
            moving.update(last.t, ticker.distanceM)
        }
        val lost = ticker.gpsLost(t)
        if (lost && !gpsLostReported && r == null) {
            gpsLostReported = true
            fault(FaultKind.GPS_LOST, "No GPS fix")
        } else if (!lost) {
            gpsLostReported = false
        }
        val wall = SystemClock.elapsedRealtime()
        if (wall - lastNotificationRefreshWall >= 10_000) {
            lastNotificationRefreshWall = wall
            onNotificationChanged?.invoke() // keeps the HR text fresh; the chronometer ticks on its own
        }
        if (wall - lastTickEventWall >= 500) {
            lastTickEventWall = wall
            val st = core.status(t)
            RecorderEventBus.emit(
                TickEvent(
                    elapsedMs = st.elapsedMs,
                    lapElapsedMs = t - lapStartT,
                    lapDistanceM = ticker.distanceM - lapStartDist,
                    lapPaceLiveSecPerKm = pace,
                    totalDistanceM = ticker.distanceM,
                    hr = last.hr?.toLong(),
                    gpsAccuracyM = last.accuracyM,
                    state = st.state.toPigeon(),
                    phase = st.phase.toPigeon(),
                    repIndex = st.repIndex.toLong(),
                    phaseRemainingMs = st.phaseRemainingMs,
                ),
            )
        }
        if (r != null && !r.running && t >= r.endT) {
            Log.i(TAG, "replay finished")
            onReplayFinished?.invoke()
        }
    }

    // ---- controls ----

    fun lap(source: LapSource) {
        if (finished) return
        val t = clock()
        val (decision, out) = core.lap(source, t)
        Log.i(TAG, "lap $source → $decision")
        handle(out, t)
    }

    fun pause() {
        if (finished || core.state != RecorderState.recording) return
        val t = clock()
        core.pause(t)
        ticker.onPause()
        writer.append(JournalLine.Pause(t, System.currentTimeMillis()))
        emitState()
        onNotificationChanged?.invoke()
    }

    fun resume() {
        if (finished || core.state != RecorderState.paused) return
        val t = clock()
        core.resume(t)
        ticker.onResume()
        writer.append(JournalLine.Resume(t, System.currentTimeMillis()))
        emitState()
        onNotificationChanged?.invoke()
    }

    /** Stop and finalise in Kotlin (B3). Returns the run file path relative to `files/`, or null on corruption. */
    fun stop(): String? {
        if (finished) return null
        finished = true
        val t = clock()
        val out = core.stop(t)
        for (o in out) if (o is RecorderCore.Output.Cue) {
            cues.play(o.kind, Phase.none, core.repIndex)
            writer.append(JournalLine.Cue(o.t, System.currentTimeMillis(), o.kind))
        }
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.FINALISING, runId = runId, phase = app.runsolo.platform.Phase.NONE))
        detachSensors()
        writer.close()
        val outcome = Finaliser(fs).finalise(runId, System.currentTimeMillis(), activeRunId = null)
        ExitDiagnostics.noteStopped(context, runId)
        val path = when (outcome) {
            is Finaliser.Outcome.Done -> outcome.path
            is Finaliser.Outcome.Corrupt -> {
                Log.e(TAG, "finalise: corrupt journal ${outcome.reason}")
                null
            }
            else -> null
        }
        Log.i(TAG, "finalised $runId → $path")
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.IDLE, runId = runId, phase = app.runsolo.platform.Phase.NONE))
        return path
    }

    fun setCues(enabled: Boolean) {
        cues.enabled = enabled
    }

    /** The foreground service could not start: nothing worth keeping. Deletes the journal, never finalises. */
    fun discard() {
        if (finished) return
        finished = true
        detachSensors()
        writer.close()
        fs.deleteRecursively(RunPaths.journalDir(runId))
        ExitDiagnostics.noteStopped(context, runId)
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.IDLE, runId = runId, phase = app.runsolo.platform.Phase.NONE))
        Log.w(TAG, "discarded $runId")
    }

    /** The service was torn down while the process lives: stop cleanly, keep the journal for recovery. */
    fun suspend() {
        if (finished) return
        finished = true
        detachSensors()
        writer.close()
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.IDLE, runId = runId, phase = app.runsolo.platform.Phase.NONE))
    }

    // ---- outputs ----

    private fun handle(outputs: List<RecorderCore.Output>, t: Long) {
        for (o in outputs) {
            when (o) {
                is RecorderCore.Output.Lap -> {
                    writer.append(JournalLine.Lap(o.t, System.currentTimeMillis(), o.source))
                    lapCount = o.index + 1
                    lapStartT = o.t
                    lapStartDist = ticker.distanceM
                    val st = core.status(o.t)
                    val activeMs = st.activeMs - lapStartActive
                    lapStartActive = st.activeMs
                    laps.add(LapSummary(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = ticker.distanceM, source = o.source.toPigeon()))
                    RecorderEventBus.emit(
                        LapEvent(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = ticker.distanceM, source = o.source.toPigeon()),
                    )
                    Log.i(TAG, "lap index=${o.index} source=${o.source} t=${core.status(o.t).elapsedMs}")
                    onNotificationChanged?.invoke()
                }
                is RecorderCore.Output.Cue -> {
                    writer.append(JournalLine.Cue(o.t, System.currentTimeMillis(), o.kind))
                    cues.play(o.kind, core.phase, core.repIndex)
                    RecorderEventBus.emit(CueEvent(kind = o.kind.toPigeon()))
                }
                is RecorderCore.Output.PhaseChanged -> {
                    RecorderEventBus.emit(PhaseEvent(phase = o.phase.toPigeon(), repIndex = o.repIndex.toLong(), phaseDurationMs = o.phaseDurationMs ?: 0L))
                    onNotificationChanged?.invoke()
                }
            }
        }
    }

    private fun emitState() {
        RecorderEventBus.emit(StateEvent(state = core.state.toPigeon(), runId = runId, phase = core.phase.toPigeon()))
    }

    private fun fault(kind: FaultKind, message: String) {
        RecorderEventBus.emit(FaultEvent(kind = kind, message = message))
    }

    // ---- views ----

    fun status(): RecorderStatus {
        val t = clock()
        val st = core.status(t)
        return RecorderStatus(
            state = st.state.toPigeon(),
            runId = runId,
            mode = mode.toPigeon(),
            laps = laps.toList(),
            elapsedMs = st.elapsedMs,
            lapIndex = st.lapIndex.toLong(),
            gpsFix = !ticker.gpsLost(t),
            hrConnected = hrConnected,
            phase = st.phase.toPigeon(),
            repIndex = st.repIndex.toLong(),
            phaseRemainingMs = st.phaseRemainingMs,
            preset = preset?.toPigeon(),
            journalOk = writer.ok,
        )
    }

    fun notificationContent(): RecorderNotification.Content {
        val t = clock()
        val st = core.status(t)
        val timed = st.phase == Phase.work || st.phase == Phase.recovery
        return RecorderNotification.Content(
            state = st.state,
            phase = st.phase,
            repIndex = st.repIndex,
            reps = preset?.reps,
            elapsedBaseRealtime = SystemClock.elapsedRealtime() - st.activeMs,
            phaseRemainingMs = if (timed && st.state == RecorderState.recording) st.phaseRemainingMs else null,
            lapIndex = st.lapIndex,
            hr = lastHr,
        )
    }

    val state: RecorderState get() = if (::core.isInitialized) core.state else RecorderState.idle

    companion object {
        const val TAG = "RunSolo/session"
    }
}
