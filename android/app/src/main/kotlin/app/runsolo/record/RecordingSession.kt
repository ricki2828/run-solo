package app.runsolo.record

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import app.runsolo.BuildConfig
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
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.LapDispatch
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
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
    override val runId: String,
    val mode: RunMode,
    val spec: SessionSpec?,
    val units: Units,
    private val replay: ReplayRunner?,
    volumeKeyLaps: Boolean,
    /** The last Cooper result's VO2, for the projection cue's "up 2 on last time"; not journaled (a recovered test omits the gap). */
    private val lastCooperVo2: Double? = null,
) : app.runsolo.platform.StartGuard.Session {
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
    // The recorder runs on its own thread: the 1 Hz tick, journal writes (incl. fsync) and
    // sensor callbacks never wait behind Flutter's main-thread work (on a slow emulator the
    // first Flutter frame starved the main looper for seconds and the run lost its ticks).
    // Every public method and the tick are @Synchronized on this object, so main-thread calls
    // (lap/pause/stop/status from the API, BLE callbacks) and the recorder thread interleave safely.
    private val thread = HandlerThread("runsolo-recorder", android.os.Process.THREAD_PRIORITY_FOREGROUND).also { it.start() }

    /**
     * Last computed status, refreshed after every tick and control call. `status()` reads it
     * without taking the monitor, so a Pigeon call on main never waits behind a journal fsync
     * on the recorder thread; it is at most one tick (1 s) old.
     */
    @Volatile
    private var snapshot: RecorderStatus? = null
    private val handler = Handler(thread.looper)
    private val cues = CuePlayer(this.context)
    internal val lapInput = LapInput(
        this.context,
        onLap = { lap(LapSource.volumeKey) },
        onUnavailable = { volumeKeyUnavailableOnce() },
    )

    /** Volume-key laps need a mode that takes laps at all (plan §18.2): Free never registers the MediaSession. */
    private val volumeKeyLapsEnabled = volumeKeyLaps && mode.lapInput
    private lateinit var core: RecorderCore
    private var location: LocationSource? = null
    private var ble: BleHrClient? = null
    private var tickRunnable: Runnable? = null
    private var attached = false
    private var finished = false

    /** Wall time the run started (from the header; survives a resume). */
    var startWallMs: Long = 0
        private set

    /** True once [startResumed] ran: this session continues an orphaned journal that must never be deleted. */
    @Volatile
    override var resumed: Boolean = false
        private set
    private var lapCount = 0
    private val laps = ArrayList<LapSummary>()
    private var lapStartT = 0L
    private var lapStartActive = 0L
    private var lapStartDist = 0.0
    private var lastTickEventWall = 0L
    private var lastNotificationRefreshWall = 0L
    private var gpsLostReported = false

    /** When lap and phase events go out: a manual lap waits for the next tick (see [LapDispatch]). */
    private val dispatch = LapDispatch(onLap = ::publishLap, onPhase = ::publishPhase)

    /** Distance step whose "GPS weak" was already said (once per step, W3). */
    private var gpsWeakStep: Int? = null
    private var replayLapsPressed = 0
    private var hrConnected = false
    private var lastHr: Int? = null

    var onNotificationChanged: (() -> Unit)? = null
    var onReplayFinished: (() -> Unit)? = null

    /** The session asked to end itself ([SessionSpec.autoStop]); called on the recorder thread, the service stops on main. */
    var onAutoStop: (() -> Unit)? = null

    val cuesEnabled: Boolean get() = cues.enabled

    /** Wall time since Start (pauses and gaps included) right now; 0 before the core starts. */
    @Synchronized
    fun elapsedNowMs(): Long = if (::core.isInitialized) core.status(clock()).elapsedMs else 0L
    val isReplay: Boolean get() = replay != null

    private fun clock(): Long = replay?.now() ?: SystemClock.elapsedRealtime()

    // ---- lifecycle ----

    /** Fresh run: header line, state machine at warmup/none. Ticks start now, sensors when the service is up. */
    @Synchronized
    fun startNew(device: String, app: String, tz: String) {
        val t = clock()
        startWallMs = System.currentTimeMillis()
        writer.open()
        writer.append(JournalLine.Header(t, startWallMs, runId, device, app, tz, mode, spec, units))
        core = RecorderCore(mode, spec, RecorderCore.Config(volumeKeyLaps = volumeKeyLapsEnabled))
        handle(core.start(t), t)
        dispatch.ticked(t, 0.0)
        lapStartT = t
        ExitDiagnostics.noteStart(context, runId, startWallMs)
        emitState()
        scheduleTick()
    }

    /** Continue an orphaned journal after a kill (plan §3, W12): gap line, phase rebuilt from the journal. */
    @Synchronized
    fun startResumed(orphan: Replay) {
        val t = clock()
        val nowWall = System.currentTimeMillis()
        startWallMs = orphan.header.w
        resumed = true // from here on, any abort keeps the journal
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
        dispatch.ticked(t, ticker.distanceM)
        if (core.state == RecorderState.paused) ticker.onPause()
        ExitDiagnostics.noteResume(context, runId, nowWall)
        scheduleTick()
        Log.i(TAG, "resumed $runId after ${gap / 1000}s gap; phase=${core.phase} rep=${core.repIndex} paused=${core.state == RecorderState.paused}")
        emitState()
    }

    /** Called by the service once it is in the foreground: sensors and cues (ticks are already running). */
    @Synchronized
    fun attachSensors(preferRawGps: Boolean, cuesEnabled: Boolean) {
        if (attached || finished) return
        attached = true
        cues.enabled = cuesEnabled
        cues.init()
        enableLapInput()
        val r = replay
        if (r != null) {
            // One clock, one tick per delivered fix (see ReplaySource): no timer in replay mode.
            r.start(
                handler,
                onFix = { fix ->
                    try {
                        replayFix(fix)
                    } catch (e: Exception) {
                        Log.e(TAG, "replay tick failed", e)
                    }
                },
                onHr = { onHr(it) },
            )
            return
        } else {
            location = LocationSource.create(context, preferRawGps).also { src ->
                try {
                    src.start(thread.looper) { onFix(it) }
                } catch (e: Exception) {
                    Log.w(TAG, "location start failed: $e")
                    fault(FaultKind.GPS_LOST, "Location updates unavailable: ${e.message}")
                }
            }
            val client = BleHolder.client(context)
            ble = client
            client.listener = object : BleHrClient.Listener {
                override fun onReading(reading: HrReading) = onHr(reading)

                override fun onNoContact() = onHrNoContact()

                override fun onLink(connected: Boolean) = onHrLink(connected)
            }
            client.connectIfPaired()
        }
    }

    // Sensor callbacks (recorder thread for fixes/replay, main thread for BLE) enter under the lock.
    @Synchronized
    private fun onFix(fix: LocationFix) {
        if (!finished) ticker.onFix(fix)
    }

    @Synchronized
    private fun replayFix(fix: LocationFix) {
        if (finished) return
        ticker.onFix(fix)
        tick(fix.t)
    }

    @Synchronized
    private fun onHr(reading: HrReading) {
        lastHr = reading.bpm
        ticker.onHr(reading)
    }

    @Synchronized
    private fun onHrNoContact() {
        lastHr = null
        ticker.onHrNoContact()
    }

    @Synchronized
    private fun onHrLink(connected: Boolean) {
        if (finished) return
        hrConnected = connected
        writer.append(JournalLine.HrLink(clock(), System.currentTimeMillis(), connected))
        if (!connected) fault(FaultKind.HR_DISCONNECTED, "Heart rate strap disconnected")
        onNotificationChanged?.invoke()
    }

    @Synchronized
    fun detachSensors() {
        stopTicks()
        if (!attached) return
        attached = false
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

    /** 1 Hz timer on the recorder thread; replay mode ticks per delivered fix instead. */
    private fun scheduleTick() {
        if (tickRunnable != null || replay != null) return
        val period = 1000L
        val r = object : Runnable {
            override fun run() {
                if (finished || tickRunnable !== this) return
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

    private fun stopTicks() {
        tickRunnable?.let { handler.removeCallbacks(it) }
        tickRunnable = null
    }

    // ---- the 1 Hz loop ----

    @Synchronized
    private fun tick(t: Long) {
        if (finished) return
        val r = replay
        // As ReplayScenarios.Driver (the core-jvm fixture path): at most one due press per tick.
        if (r != null && replayLapsPressed < r.presses.size && r.traceMs(t) >= r.presses[replayLapsPressed].atMs) {
            when (r.presses[replayLapsPressed++].press) {
                ReplayScenarios.Press.lap -> lap(LapSource.notification)
                ReplayScenarios.Press.startReps -> startReps()
            }
        }
        // Sample first: the core's distance steps need this second's distance (Phase 3 §3.6).
        val samples = ticker.tick(t)
        for (s in samples) writer.append(s)
        val lost = ticker.gpsLost(t)
        dispatch.flush(t, ticker.distanceM)
        handle(core.tick(t, ticker.distanceM, gpsOk = !lost), t)
        dispatch.ticked(t, ticker.distanceM)
        val last = samples.last()
        var pace: Double? = null
        if (last.hasFix) {
            pace = livePace.update(last.t, ticker.distanceM)
            moving.update(last.t, ticker.distanceM)
        }
        val step = core.stepIndex
        if (lost && step != null && core.status(t).stepRemainingM != null && gpsWeakStep != step && r == null) {
            // A distance rep does not end on its own without GPS (W3): say so once per rep.
            gpsWeakStep = step
            cues.announce("GPS weak")
            fault(FaultKind.GPS_WEAK, "GPS weak: this rep ends when GPS is back, or on LAP")
        }
        if (lost && !gpsLostReported && r == null) {
            gpsLostReported = true
            fault(FaultKind.GPS_LOST, "No GPS fix")
        } else if (!lost) {
            gpsLostReported = false
        }
        val wall = SystemClock.elapsedRealtime()
        // Distance steps show metres to go, so they refresh more often than the HR text needs.
        val refreshMs = if (core.status(t).stepRemainingM != null) 3_000 else 10_000
        if (wall - lastNotificationRefreshWall >= refreshMs) {
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
                    stepIndex = st.stepIndex?.toLong(),
                    stepRemainingMs = st.stepRemainingMs,
                    stepRemainingM = st.stepRemainingM,
                ),
            )
        }
        refreshSnapshot()
        if (r != null && !r.running && t >= r.endT) {
            // ReplaySource flips running before delivering the last fix, so this is that fix's tick.
            Log.i(TAG, "replay finished at ${core.status(t).elapsedMs} ms; stopping")
            onReplayFinished?.invoke()
        }
    }

    // ---- controls ----

    @Synchronized
    fun lap(source: LapSource) {
        if (finished) return
        val t = clock()
        val (decision, out) = core.lap(source, t)
        Log.i(TAG, "lap $source → $decision")
        if (decision == RecorderCore.LapDecision.ignoredModeNoLaps && BuildConfig.DEBUG) {
            // Debug only (plan §18.2): a LAP in Free mode means some surface still shows a LAP control.
            fault(FaultKind.LAP_IGNORED, "LAP from $source ignored in $mode mode")
        }
        handle(out, t)
        refreshSnapshot()
    }

    /** "Start reps": end the warm-up and start rep 1 (the Cooper test's only start); a no-op outside the warm-up. */
    @Synchronized
    fun startReps() {
        if (finished) return
        val t = clock()
        val (decision, out) = core.startReps(t)
        Log.i(TAG, "startReps → $decision")
        handle(out, t)
        refreshSnapshot()
    }

    @Synchronized
    fun pause() {
        if (finished || core.state != RecorderState.recording) return
        val t = clock()
        core.pause(t)
        ticker.onPause()
        writer.append(JournalLine.Pause(t, System.currentTimeMillis()))
        emitState()
        onNotificationChanged?.invoke()
    }

    @Synchronized
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
    @Synchronized
    fun stop(): String? {
        if (finished) return null
        finished = true
        stopTicks()
        val t = clock()
        dispatch.flush(t, ticker.distanceM)
        val out = core.stop(t)
        refreshSnapshot()
        for (o in out) if (o is RecorderCore.Output.Cue) {
            cues.play(o.kind, cueText(o))
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
        thread.quitSafely()
        return path
    }

    /** Registers the volume-key LAP when the user's setting and the mode allow it (from [attachSensors]). */
    internal fun enableLapInput() {
        if (volumeKeyLapsEnabled) lapInput.enable()
    }

    @Synchronized
    fun setCues(enabled: Boolean) {
        cues.enabled = enabled
    }

    /**
     * A start that did not reach recording (start step threw, `startForegroundService` or
     * `startForeground` refused). The only decision point for the journal: a brand-new run is
     * discarded (nothing worth keeping), a resumed run is suspended — journal closed and kept
     * on disk for the next `recover()`. Never finalises.
     */
    @Synchronized
    override fun abortStart() {
        if (resumed) suspend() else discard()
    }

    /** A brand-new run that never recorded: deletes its header-only journal. Only [abortStart] may call this. */
    @Synchronized
    private fun discard() {
        if (finished) return
        finished = true
        stopTicks()
        detachSensors()
        writer.close()
        fs.deleteRecursively(RunPaths.journalDir(runId))
        ExitDiagnostics.noteStopped(context, runId)
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.IDLE, runId = runId, phase = app.runsolo.platform.Phase.NONE))
        Log.w(TAG, "discarded $runId")
        thread.quitSafely()
    }

    /** Stop cleanly and keep the journal for recovery (service torn down mid-run, or a resumed start aborted). */
    @Synchronized
    fun suspend() {
        if (finished) return
        finished = true
        stopTicks()
        detachSensors()
        writer.close()
        RecorderEventBus.emit(StateEvent(state = app.runsolo.platform.RecorderState.IDLE, runId = runId, phase = app.runsolo.platform.Phase.NONE))
        thread.quitSafely()
    }

    // ---- outputs ----

    private fun handle(outputs: List<RecorderCore.Output>, t: Long) {
        for (o in outputs) {
            when (o) {
                is RecorderCore.Output.Lap -> {
                    writer.append(JournalLine.Lap(o.t, System.currentTimeMillis(), o.source))
                    lapCount = o.index + 1
                    dispatch.lap(o, t, ticker.distanceM)
                }
                is RecorderCore.Output.Cue -> {
                    writer.append(JournalLine.Cue(o.t, System.currentTimeMillis(), o.kind))
                    cues.play(o.kind, cueText(o))
                    RecorderEventBus.emit(CueEvent(kind = o.kind.toPigeon(), value = o.value))
                }
                is RecorderCore.Output.PhaseChanged -> dispatch.phase(o)
                is RecorderCore.Output.AutoStop -> {
                    Log.i(TAG, "auto-stop at ${core.status(o.t).elapsedMs} ms")
                    onAutoStop?.invoke()
                }
            }
        }
    }

    private fun publishPhase(o: RecorderCore.Output.PhaseChanged) {
        refreshSnapshot()
        RecorderEventBus.emit(PhaseEvent(phase = o.phase.toPigeon(), repIndex = o.repIndex.toLong(), phaseDurationMs = o.phaseDurationMs ?: 0L))
        onNotificationChanged?.invoke()
    }

    private fun publishLap(o: RecorderCore.Output.Lap, distanceM: Double) {
        lapStartT = o.t
        lapStartDist = distanceM
        val st = core.status(o.t)
        val activeMs = st.activeMs - lapStartActive
        lapStartActive = st.activeMs
        laps.add(LapSummary(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = distanceM, source = o.source.toPigeon()))
        RecorderEventBus.emit(LapEvent(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = distanceM, source = o.source.toPigeon()))
        Log.i(TAG, "lap index=${o.index} source=${o.source} t=${st.elapsedMs}")
        onNotificationChanged?.invoke()
    }

    private fun cueText(o: RecorderCore.Output.Cue): String? =
        CueWords.text(o.kind, o.value, spec, core.phase, core.repIndex, core.stepIndex, lastCooperVo2)

    private fun emitState() {
        refreshSnapshot()
        RecorderEventBus.emit(StateEvent(state = core.state.toPigeon(), runId = runId, phase = core.phase.toPigeon()))
    }

    private fun refreshSnapshot() {
        if (::core.isInitialized) snapshot = statusNow()
    }

    /**
     * Once per run id, across kill/recovery: a marker next to the journal (deleted with it on
     * finalise/discard) records that the note was already shown for this run.
     */
    private fun volumeKeyUnavailableOnce() {
        val marker = "${RunPaths.journalDir(runId)}/$VOLUME_KEY_UNAVAILABLE_MARKER"
        if (fs.exists(marker)) {
            Log.i(TAG, "volumeKeyUnavailable already noted for $runId")
            return
        }
        try {
            fs.mkdirs(RunPaths.journalDir(runId))
            fs.writeBytes(marker, ByteArray(0))
        } catch (e: Exception) {
            Log.w(TAG, "volumeKeyUnavailable marker not written: $e")
        }
        fault(FaultKind.VOLUME_KEY_UNAVAILABLE, "Volume-key laps don't work on Android 14; use the lock-screen LAP")
    }

    private fun fault(kind: FaultKind, message: String) {
        RecorderEventBus.emit(FaultEvent(kind = kind, message = message))
    }

    // ---- views ----

    /** Lock-free: the snapshot from the last tick/control call (≤ 1 s old), or a fresh one before the first tick. */
    fun status(): RecorderStatus = snapshot ?: statusNow()

    @Synchronized
    private fun statusNow(): RecorderStatus {
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
            spec = spec?.toPigeon(),
            stepIndex = st.stepIndex?.toLong(),
            stepRemainingMs = st.stepRemainingMs,
            stepRemainingM = st.stepRemainingM,
            journalOk = writer.ok,
        )
    }

    @Synchronized
    fun notificationContent(): RecorderNotification.Content {
        val t = clock()
        val st = core.status(t)
        // Counting down: a time step, or a fixed warm-up/cool-down still running.
        val fixedEdge = (st.phase == Phase.warmup && spec?.warmupSeconds != null) || (st.phase == Phase.cooldown && spec?.cooldownSeconds != null)
        val timed = st.stepRemainingMs != null || (fixedEdge && st.phaseRemainingMs > 0)
        return RecorderNotification.Content(
            state = st.state,
            phase = st.phase,
            repIndex = st.repIndex,
            reps = spec?.reps?.takeIf { mode.followsSteps },
            elapsedBaseRealtime = SystemClock.elapsedRealtime() - st.activeMs,
            phaseRemainingMs = if (timed && st.state == RecorderState.recording) st.phaseRemainingMs else null,
            metresToGo = st.stepRemainingM,
            cooper = mode == RunMode.cooper,
            lapIndex = st.lapIndex,
            hr = lastHr,
            lapAction = mode.lapInput,
        )
    }

    val state: RecorderState get() = if (::core.isInitialized) core.state else RecorderState.idle

    companion object {
        const val TAG = "RunSolo/session"
        private const val VOLUME_KEY_UNAVAILABLE_MARKER = "volume-key-unavailable"
    }
}
