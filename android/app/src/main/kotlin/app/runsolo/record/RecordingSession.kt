package app.runsolo.record

import app.runsolo.core.model.LiveContext
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import app.runsolo.BuildConfig
import app.runsolo.ble.BleHolder
import app.runsolo.ble.BleHrClient
import app.runsolo.core.elevation.ElevSource
import app.runsolo.core.elevation.LiveElevation
import app.runsolo.core.elevation.PressureReading
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
import app.runsolo.core.live.CheckInPlan
import app.runsolo.core.live.CheckInSnapshot
import app.runsolo.core.live.CheckInTracker
import app.runsolo.core.live.CooperCurve
import app.runsolo.core.live.CueSlot
import app.runsolo.core.live.GoalCoach
import app.runsolo.core.live.LiveCoach
import app.runsolo.core.live.LiveTruePace
import app.runsolo.core.live.MomentInput
import app.runsolo.core.live.TrailMoments
import app.runsolo.core.live.VoiceCoach
import app.runsolo.core.live.VoiceLevel
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.SummaryWords
import app.runsolo.core.record.LapDispatch
import app.runsolo.core.record.LiveRoute
import app.runsolo.core.route.RetraceDetector
import app.runsolo.core.route.RetraceFeed
import app.runsolo.core.route.RetraceDirection
import app.runsolo.core.route.RetraceState
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.record.SampleTicker
import app.runsolo.core.replay.ReplayScenarios
import app.runsolo.core.route.FollowRoute
import app.runsolo.core.route.RouteFollower
import app.runsolo.core.trail.TrailCueSink
import app.runsolo.core.trail.TrailGhostFeed
import app.runsolo.core.route.RoutePath
import app.runsolo.core.route.RouteWords
import app.runsolo.core.run.Finaliser
import app.runsolo.platform.CompareEvent
import app.runsolo.platform.CueEvent
import app.runsolo.platform.FaultEvent
import app.runsolo.platform.FaultKind
import app.runsolo.platform.GoalEvent
import app.runsolo.platform.LapEvent
import app.runsolo.platform.LapPendingEvent
import app.runsolo.platform.LapSummary
import app.runsolo.platform.PhaseEvent
import app.runsolo.platform.RecorderEventBus
import app.runsolo.platform.RecorderStatus
import app.runsolo.platform.RoutePointsEvent
import app.runsolo.platform.RouteEndCue
import app.runsolo.platform.RouteProgress
import app.runsolo.platform.StateEvent
import app.runsolo.platform.TickEvent
import app.runsolo.platform.TrailClimb
import app.runsolo.platform.TrailProgress
import app.runsolo.platform.toPigeon
import kotlin.math.abs

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
    /**
     * The live compare's history (Phase 4 §3.2): journaled as the `lctx` line right after the
     * header, handed back from the journal on resume. [LiveCoach] compares against it; its
     * Cooper curve drives the minute projections.
     */
    private val liveContext: LiveContext? = null,
    /** The route this run follows (Follow a route): journaled as the `route` line, handed back from the journal on resume. */
    route: FollowRoute? = null,
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

    /** Climb so far and the current grade (barometer + GPS fused, see ElevationFuser). */
    private val liveElev = LiveElevation()
    /** Retrace detection (out-and-back): fed with accepted fixes on this thread, so the screen and the voice read one answer. */
    private val retraceFeed = RetraceFeed(onFailure = { Log.e(TAG, "retrace disabled for this run", it) })
    private val retrace: RetraceDetector get() = retraceFeed.detector
    private var lastElevRel: Double? = null

    /**
     * Known-trail ghost (ahead/behind the best and last run on a trail the runner has run before, and the turnaround
     * point of an out-and-back): Free and Trail runs only, fed with accepted fixes on this thread. A failure switches
     * it off for the run, never the recording.
     */
    private val trailFeed = TrailGhostFeed(
        if (mode == RunMode.free || mode == RunMode.trail) liveContext?.trails.orEmpty() else emptyList(),
        onFailure = { Log.e(TAG, "trail ghost disabled for this run", it) },
    )
    /** The ghost's own active clock (ms): grows while recording and not auto-paused, the same live and on restore. */
    private var ghostActiveMs = 0L
    private var ghostLastT: Long? = null
    private val moving = MovingDetector()

    /** Stop/go for auto-pause only; [moving] keeps its own settings for the moving-time summary. */
    private val autoDetector = MovingDetector.forAutoPause(mode)
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
    private val cues = CuePlayer(this.context) { clock() }
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
    private var baro: PressureSource? = null
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

    /** The route being followed, with its progress and off-route state (null: the run follows nothing). Native, so it works screen off. */
    private val followRoute: FollowRoute? = route
    private val follower: RouteFollower? = route?.let { RouteFollower(RoutePath(it), imperial = units == Units.mi) }

    /** The live map's route (read-only view of the samples; recording never reads it). */
    private val liveRoute = LiveRoute()
    private var routeSentCount = 0
    private var lastRouteEventWall = 0L
    private var lastNotificationRefreshWall = 0L
    private var gpsLostReported = false

    /** When lap, phase and cue events go out: a manual lap waits for the next tick (see [LapDispatch]). */
    private val dispatch = LapDispatch(onLap = ::publishLap, onPhase = ::publishPhase, onCue = ::publishCue)

    /** The Cooper fade curve: the engine's personal curve from the LiveContext, else the default (§3.3). */
    private val coreConfig: RecorderCore.Config
        get() = RecorderCore.Config(volumeKeyLaps = volumeKeyLapsEnabled, cooperCurve = CooperCurve.fromFractions(liveContext?.cooperCurve) ?: CooperCurve.DEFAULT)

    /** Live "you vs you" (LV1); rebuilt from the journal's `cf` lines on resume. */
    private var coach = LiveCoach(liveContext, mode, spec)

    /** GOAL runs (§G): the goal-reached line, once; rebuilt on resume. */
    private var goal = GoalCoach(spec, liveContext)
    private var coachPrevT = 0L
    private var coachPrevD = 0.0

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
        replay?.anchorAt(t)
        startWallMs = System.currentTimeMillis()
        writer.open()
        writer.append(JournalLine.Header(t, startWallMs, runId, device, app, tz, mode, spec, units))
        liveContext?.let { writer.append(JournalLine.LiveContextLine(t, startWallMs, it)) }
        followRoute?.let { writer.append(JournalLine.RouteLine(t, startWallMs, it)) }
        core = RecorderCore(mode, spec, coreConfig)
        handle(core.start(t), t)
        dispatch.ticked(t, 0.0)
        coachPrevT = t
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
        core = RecorderCore.restore(replayed, t, coreConfig)
        lapCount = core.lapCount
        lapStartT = t
        // Laps from the journal, with active time (pauses and gaps excluded) per lap.
        var lapT = 0L
        var inactive = 0L
        var pauseStart: Long? = null
        var prevActive = 0L
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Pause, is RunEvent.AutoPause -> if (pauseStart == null) pauseStart = e.t
                is RunEvent.Resume, is RunEvent.AutoResume -> pauseStart?.let { inactive += e.t - it; pauseStart = null }
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
        var reanchor = false // only a manual pause re-anchors on resume (see SampleTicker)
        var lastLapDist = 0.0
        for (e in replayed.events) {
            when (e) {
                is RunEvent.Sample -> {
                    if (e.hasFix && !paused) ticker.filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                    // Progress along the followed route, rebuilt quietly: nothing is said for what already happened.
                    if (e.hasFix && !paused) follower?.offer(e.t, e.lat!!, e.lon!!, e.accuracyM!!, quiet = true)
                    liveElev.offer(e.t, e.hpa, e.altM, e.accuracyM, ticker.filter.totalM, paused)?.let { lastElevRel = it }
                    // The same rule as live (RetraceFeed), so a restore rebuilds the track the live path built.
                    if (e.hasFix) retraceFeed.offer(e.lat!!, e.lon!!, e.accuracyM!!, lastElevRel, liveElev.source == ElevSource.baro, ticker.distanceM, active = !paused)
                    // The trail ghost is rebuilt quietly too (its turnaround, if already given, is not given again).
                    if (e.hasFix && trailFeed.active) {
                        val active = ghostClock(e.t, !paused)
                        if (!paused) trailFeed.offer(e.t, e.lat!!, e.lon!!, e.accuracyM!!, active, ticker.distanceM)
                    }
                }
                is RunEvent.Pause -> { paused = true; reanchor = true }
                is RunEvent.Resume -> { paused = false; ticker.filter.reanchor(); reanchor = false }
                is RunEvent.AutoPause -> paused = true
                is RunEvent.AutoResume -> { paused = false; if (reanchor) ticker.filter.reanchor(); reanchor = false }
                is RunEvent.Lap -> {
                    lastLapDist = ticker.filter.totalM
                    laps.indexOfFirst { it.tMs == e.t }.takeIf { it >= 0 }?.let { i -> laps[i] = laps[i].copy(distanceM = lastLapDist) }
                }
                else -> Unit
            }
        }
        follower?.restartClock() // the fixes' clock starts over after a kill
        ghostLastT = null
        ticker.filter.reanchor() // the runner moved during the dark span; do not count the jump
        lapStartDist = lastLapDist
        dispatch.ticked(t, ticker.distanceM)
        // Compares already said stay said; a point passed while dead is dropped (BLOCK-1). The
        // reps run so far give the live rep paces back, each by the step its lap ended; a rep
        // with a kill gap inside it (this one included: the gap line is already journaled) is
        // unclean.
        coach = LiveCoach(liveContext, mode, spec, replayed.cuesFired).also {
            it.kmSplits = kmSplits
            // The zone minutes before the kill were not seen: after a restore the check-in says the zone only.
            // Kept as a field so a tracker built later (or rebuilt by the setter) starts partial too.
            checkInPartial = true
            checkInTracker?.partial = true
            it.checkIn = checkIn
            // A journaled "Mute tips" survives the kill: nothing is spoken again after a restore.
            if (replayed.tipsMuted) it.muted = true
        }
        var cumActive = 0L
        coach.restoreReps(replayed.events, core, laps.map { l -> cumActive += l.activeMs; l.distanceM to cumActive })
        coach.resumeAt(ticker.distanceM)
        trailMoments.resumeAt(ticker.distanceM)
        // A goal already reached before the kill is never said again; a kill before it marks the
        // result interrupted (WARN-G2).
        goal = GoalCoach(spec, liveContext).also { it.restored(reachedBeforeKill = core.finalStepEnd != null) }
        if (core.finalStepEnd != null) coach.goalReachedAt(ticker.distanceM, null)
        coachPrevT = t
        coachPrevD = ticker.distanceM
        if (core.state == RecorderState.paused) if (core.autoPaused) ticker.onAutoPause() else ticker.onPause()
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
        speakStart()
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
            baro = PressureSource(context).also { src ->
                if (!src.start(handler) { onPressure(it) }) Log.i(TAG, "no barometer: elevation follows GPS altitude")
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
    private fun onPressure(reading: PressureReading) {
        if (!finished) ticker.onPressure(reading)
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
        baro?.stop()
        baro = null
        replay?.stop()
        ble?.let {
            it.listener = null
            it.disconnect()
        }
        ble = null
        lapInput.disable()
        // A cue still being said ("Run saved" with the summary off) finishes first, up to a short cap.
        cues.releaseWhenIdle()
    }

    /**
     * "Trail run. Following Kastro loop, 6.2 kilometres, 230 metres of climb.": what the run is, once, as
     * recording begins (never for a resumed run or a replay, whose transcripts are pinned). Muted cues or
     * the setting off: silent ([CuePlayer.enabled]).
     */
    private fun speakStart() {
        if (!spokenSummary || resumed || replay != null) return
        val path = follower?.path
        val text = SummaryWords.start(mode, spec, units, followRoute?.name, path?.totalM, path?.totalClimbM) ?: return
        cues.announceSummary(text)
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
                ReplayScenarios.Press.pause -> pause()
            }
        }
        // Sample first: the core's distance steps need this second's distance (Phase 3 §3.6).
        val samples = ticker.tick(t)
        for (s in samples) {
            writer.append(s)
            liveElev.offer(s.t, s.hpa, s.altM, s.accuracyM, ticker.distanceM, ticker.paused)?.let { lastElevRel = it }
        }
        val lost = ticker.gpsLost(t)
        dispatch.flush(t, ticker.distanceM)
        handle(core.tick(t, ticker.distanceM, gpsOk = !lost), t)
        dispatch.ticked(t, ticker.distanceM)
        // Free / Laps: a whole km crossed in this tick says its compare, if there is one.
        checkInTick(t, samples.last().hr)
        coach.onTick(coachPrevT, coachPrevD, t, ticker.distanceM, samples.last().hr, snap = { checkInSnapshot(t) }) { core.status(it).activeMs }
            ?.let { speakFire(null, it.base, it.fire, t, it.nudge, it.tail, it.slot, it.key) }
        trailMomentsTick(t)
        coachPrevT = t
        coachPrevD = ticker.distanceM
        // A nudge follows its cue as its own line: done (journaled, never offered again) only once said.
        cues.dueNudge()?.let { n ->
            logSaid(n.text)
            coach.nudgeSaid(n)
            writer.append(JournalLine.CueFired(t, System.currentTimeMillis(), JournalLine.FiredKind.nudge, n.rule, n.index, core.status(t).elapsedMs))
            Log.i(TAG, "nudge ${n.rule}#${n.index}")
        }
        if (core.state == RecorderState.recording) {
            for (s in samples) if (s.hasFix) {
                liveRoute.offer(s.lat!!, s.lon!!, s.accuracyM!!, routeElevation())
                retraceFeed.offer(s.lat!!, s.lon!!, s.accuracyM!!, lastElevRel, liveElev.source == ElevSource.baro, ticker.distanceM, active = !core.autoPaused)
            }
        }
        val last = samples.last()
        // Follow a route: progress, off-route and turn cues, on this thread so the screen can be off.
        if (follower != null && core.state == RecorderState.recording && last.hasFix) {
            for (e in follower.offer(last.t, last.lat!!, last.lon!!, last.accuracyM!!)) routeEvent(e)
        }
        // A known trail: ahead/behind, and the turnaround cue when the run follows no route of its own.
        if (trailFeed.active && core.state == RecorderState.recording && last.hasFix) {
            val active = ghostClock(last.t, !core.autoPaused)
            if (!core.autoPaused) {
                for (e in trailFeed.offer(last.t, last.lat!!, last.lon!!, last.accuracyM!!, active, ticker.distanceM)) {
                    if (follower == null && e is RouteFollower.Event.RouteEnd) trailTurn(e)
                }
            }
        }
        var pace: Double? = null
        if (last.hasFix) {
            pace = livePace.update(last.t, ticker.distanceM)
            moving.update(last.t, ticker.distanceM)
            // The detector must see the runner move while the distance is frozen, so it reads the unfrozen filter.
            val wasMoving = autoDetector.moving
            val isMoving = autoDetector.update(last.t, ticker.moveDistanceM, last.speedMps, last.lat, last.lon)
            if (wasMoving && !isMoving) autoPauseNow(t) else if (!wasMoving && isMoving) autoResumeNow(t, speak = true)
        }
        checkInFeed(if (lost) null else pace)
        coachTick(t, if (lost) null else pace, last.hr)
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
                    autoPaused = core.autoPaused,
                    elevGainM = liveElev.ascentM,
                    elevLossM = liveElev.descentM,
                    gradePct = liveElev.grade?.let { it * 100 },
                    retracing = retrace.state.retracing,
                    retraceSame = retrace.state.direction == RetraceDirection.same,
                    backToStartM = retrace.state.distanceToStartM,
                    climbAheadM = retrace.state.climbAheadM,
                    descentAheadM = retrace.state.descentAheadM,
                    heightVsStartM = retrace.state.heightVsStartM,
                    route = routeProgress(),
                    trail = trailProgress(),
                ),
            )
        }
        val routeWall = SystemClock.elapsedRealtime()
        if (liveRoute.size > routeSentCount && routeWall - lastRouteEventWall >= 900) {
            lastRouteEventWall = routeWall
            RecorderEventBus.emit(RoutePointsEvent(fromIndex = routeSentCount.toLong(), latLon = liveRoute.since(routeSentCount), elevM = liveRoute.elevSince(routeSentCount)))
            routeSentCount = liveRoute.size
        }
        refreshSnapshot()
        if (r != null && !r.running && t >= r.endT) {
            // ReplaySource flips running before delivering the last fix, so this is that fix's tick.
            Log.i(TAG, "replay finished at ${core.status(t).elapsedMs} ms; stopping")
            onReplayFinished?.invoke()
        }
    }

    /** Barometer-smoothed elevation for a route point; null without a barometer or before GPS has set the level. */
    private fun routeElevation(): Double? = if (liveElev.source == ElevSource.baro) liveElev.elevationM else null

    /** The retrace state now (back on our own track, distance back to the start, the old climb ahead); for voice check-ins. */
    fun retraceState(): RetraceState = retrace.state

    /** The route this run follows (null: none), for the map to draw under the runner's track. */
    fun followedRoute(): FollowRoute? = followRoute

    /** The live map's catch-up read ([RoutePointsEvent] carries the deltas). */
    @Synchronized
    fun routeSince(fromIndex: Int): List<Double> = liveRoute.since(fromIndex)

    // ---- controls ----

    @Synchronized
    fun lap(source: LapSource) {
        if (finished) return
        val t = clock()
        val endedPhase = core.phase
        val endedRep = core.repIndex
        val wasAutoPaused = core.autoPaused
        val (decision, out) = core.lap(source, t)
        Log.i(TAG, "lap $source → $decision")
        if (decision == RecorderCore.LapDecision.ignoredModeNoLaps && BuildConfig.DEBUG) {
            // Debug only (plan §18.2): a LAP in Free mode means some surface still shows a LAP control.
            fault(FaultKind.LAP_IGNORED, "LAP from $source ignored in $mode mode")
        }
        handle(out, t)
        endedAutoPause(wasAutoPaused, t)
        emitLapPending(out, endedPhase, endedRep)
        refreshSnapshot()
    }

    /** A LAP press moved the session on and the core ended an auto-pause that no longer applies: journal it. */
    private fun endedAutoPause(was: Boolean, t: Long) {
        if (!was || core.autoPaused) return
        writer.append(JournalLine.AutoResume(t, System.currentTimeMillis()))
        emitState()
        onNotificationChanged?.invoke()
    }

    /** "Start reps": end the warm-up and start rep 1 (the Cooper test's only start); a no-op outside the warm-up. */
    @Synchronized
    fun startReps() {
        if (finished) return
        val t = clock()
        val endedPhase = core.phase
        val endedRep = core.repIndex
        val wasAutoPaused = core.autoPaused
        val (decision, out) = core.startReps(t)
        Log.i(TAG, "startReps → $decision")
        handle(out, t)
        endedAutoPause(wasAutoPaused, t)
        emitLapPending(out, endedPhase, endedRep)
        refreshSnapshot()
    }

    /** The notification's "tap to finish" (ACTION_FINISH) this run; `status().finishRequests`. */
    private var finishRequests = 0

    /** "Tap to finish": pause if not yet, and tell the app (status and a state event) to open its finish screen. */
    @Synchronized
    fun requestFinish() {
        if (finished) return
        finishRequests++
        if (core.state == RecorderState.recording || core.autoPaused) pause() else emitState()
    }

    /**
     * The runner stopped ([MovingDetector]'s edge): the clock and the distance freeze (journal `apause`), as in a
     * manual pause but with no re-anchor on resume. Free, Laps and Goal runs, and the warm-up/cool-down of other sessions; the core decides.
     */
    private fun autoPauseNow(t: Long) {
        if (!autoPause || !core.autoPause(t)) return
        ticker.onAutoPause()
        cues.dropNudge()
        writer.append(JournalLine.AutoPause(t, System.currentTimeMillis()))
        if (replay == null) cues.announce("Paused")
        Log.i(TAG, "auto-pause at ${core.status(t).elapsedMs} ms")
        emitState()
        onNotificationChanged?.invoke()
    }

    /** Moving again (or RESUME tapped in an auto-pause): the clock runs (journal `aresume`). */
    private fun autoResumeNow(t: Long, speak: Boolean) {
        if (!core.autoResume(t)) return
        ticker.onAutoResume()
        writer.append(JournalLine.AutoResume(t, System.currentTimeMillis()))
        if (speak && replay == null) cues.announce("Resumed")
        Log.i(TAG, "auto-resume at ${core.status(t).elapsedMs} ms")
        emitState()
        onNotificationChanged?.invoke()
    }

    /** Settings → Run → "Auto-pause" (default on). Set before start and on change; off never starts an auto-pause (one in force still ends when the runner moves). */
    @Volatile
    var autoPause: Boolean = true

    @Synchronized
    fun pause() {
        if (finished || (core.state != RecorderState.recording && !core.autoPaused)) return
        val t = clock()
        core.pause(t) // on top of an auto-pause this makes it the runner's pause
        ticker.onPause()
        cues.dropNudge()
        writer.append(JournalLine.Pause(t, System.currentTimeMillis()))
        emitState()
        onNotificationChanged?.invoke()
    }

    @Synchronized
    fun resume() {
        if (finished || core.state != RecorderState.paused) return
        val t = clock()
        if (core.autoPaused) return autoResumeNow(t, speak = false)
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
            // "Run saved" opens the spoken summary when that is on (a real run only: replays keep the cue pinned).
            val words = if (o.kind == CueKind.stop && replay == null && spokenSummary) SummaryWords.stopCue(true) else cueText(o)
            cues.play(o.kind, words)
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

    /** DISCARD on the finish screen: the live run (new or resumed) goes, journal and all; no run file is written. */
    @Synchronized
    fun discardRun() = discard()

    /** Deletes the journal and never writes a run file: a start that never recorded ([abortStart]) or [discardRun]. */
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
        // The journal keeps the core's order; what goes out puts a step's end cue after its lap.
        for (o in outputs) {
            when (o) {
                is RecorderCore.Output.Lap -> writer.append(JournalLine.Lap(o.t, System.currentTimeMillis(), o.source))
                is RecorderCore.Output.Cue -> writer.append(JournalLine.Cue(o.t, System.currentTimeMillis(), o.kind))
                else -> Unit
            }
        }
        for (o in LapDispatch.ordered(outputs)) {
            when (o) {
                is RecorderCore.Output.Lap -> {
                    lapCount = o.index + 1
                    dispatch.lap(o, t, ticker.distanceM)
                }
                is RecorderCore.Output.Cue -> dispatch.cue(o, hold = coach.holdsRepEndCues)
                is RecorderCore.Output.PhaseChanged -> dispatch.phase(o)
                is RecorderCore.Output.AutoStop -> {
                    Log.i(TAG, "auto-stop at ${core.status(o.t).elapsedMs} ms")
                    onAutoStop?.invoke()
                }
            }
        }
    }

    /**
     * The press, now: a manual lap's [LapEvent] waits for the next tick (up to 1 s) so its distance
     * is interpolated at the press, but the runner must see the lap at once or presses again. The
     * UI shows the new lap (and the phase it starts) from this; the LapEvent fills in distance.
     */
    private fun emitLapPending(out: List<RecorderCore.Output>, endedPhase: Phase, endedRep: Int) {
        val p = dispatch.pressed(out, lapStartActive) { core.status(it).activeMs } ?: return
        RecorderEventBus.emit(
            LapPendingEvent(
                index = p.lap.index.toLong(),
                tMs = core.status(p.lap.t).elapsedMs,
                activeMs = p.activeMs,
                source = p.lap.source.toPigeon(),
                endedPhase = endedPhase.toPigeon(),
                endedRepIndex = endedRep.toLong(),
                nextPhase = p.next?.phase?.toPigeon(),
                nextRepIndex = p.next?.repIndex?.toLong(),
                nextPhaseDurationMs = p.next?.let { it.phaseDurationMs ?: 0L },
            ),
        )
    }

    private fun publishPhase(o: RecorderCore.Output.PhaseChanged) {
        refreshSnapshot()
        RecorderEventBus.emit(PhaseEvent(phase = o.phase.toPigeon(), repIndex = o.repIndex.toLong(), phaseDurationMs = o.phaseDurationMs ?: 0L))
        onNotificationChanged?.invoke()
    }

    private fun publishLap(o: RecorderCore.Output.Lap, distanceM: Double) {
        lapStartT = o.t
        val st = core.status(o.t)
        val activeMs = st.activeMs - lapStartActive
        coach.lapEnded(core.lapStep(o.index), distanceM, st.activeMs)
        lapStartDist = distanceM
        lapStartActive = st.activeMs
        laps.add(LapSummary(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = distanceM, source = o.source.toPigeon()))
        RecorderEventBus.emit(LapEvent(index = o.index.toLong(), tMs = st.elapsedMs, activeMs = activeMs, distanceM = distanceM, source = o.source.toPigeon()))
        Log.i(TAG, "lap index=${o.index} source=${o.source} t=${st.elapsedMs}")
        onNotificationChanged?.invoke()
    }

    private fun publishCue(o: RecorderCore.Output.Cue) {
        goal.atCue(o.kind, core.phase, core.finalStepEnd)?.let { publishGoal(it) }
        val st = core.status(o.t)
        val next = if (st.stepRemainingM != null) null else st.phaseRemainingMs
        val fire = coach.atCue(o.kind, o.index, o.value, core.phase, core.stepIndex, st.phaseActiveMs, next)
        speakFire(o.kind, cueText(o), fire, o.t, coach.nudgeAtCue(o.kind, core.phase))
        RecorderEventBus.emit(CueEvent(kind = o.kind.toPigeon(), value = o.value))
    }

    /**
     * Says a cue with its compare appended ([CuePlayer] keeps the 16-word budget and drops a stale
     * extra); a compare also goes to the journal (`cf`, so a restore never repeats it) and to the
     * app as a [CompareEvent] for the overlay, muted or not. [kind] null = a Free run's km split.
     */
    private fun speakFire(
        kind: CueKind?,
        cueBase: String?,
        fire: LiveCoach.Fire?,
        t: Long,
        nudge: LiveCoach.Nudge? = null,
        tail: String? = null,
        slot: CueSlot = if (kind == null) CueSlot.km else CueSlot.structure,
        key: String? = null,
    ) {
        val extra = fire?.takeIf { it.speak }?.text
        // A spoken goal-km compare replaces "On pace for …" with "3 k." (§G); muted, the cue stays.
        val base = fire?.takeIf { it.speak }?.base ?: cueBase
        // A nudge waits in the player to follow this cue; it is journaled at the tick that says it
        // (the next run's `blocked` list comes from those lines), never when it is dropped.
        val said = if (kind != null || base != null || extra != null) cues.play(kind, base, extra, nudge, tail, slot, key) else null
        said?.text?.let { logSaid(it) }
        val droppedByBudget = cues.consumeDropped()
        fire ?: return
        val st = core.status(t)
        // A compare the budget dropped was never said: it is not journaled as fired (the overlay below still shows it).
        if (!droppedByBudget || !fire.speak) {
            writer.append(JournalLine.CueFired(t, System.currentTimeMillis(), JournalLine.FiredKind.compare, fire.key, fire.index, st.elapsedMs))
        }
        val r = fire.result
        RecorderEventBus.emit(
            CompareEvent(
                boardKey = r.boardKey, boardLabel = r.boardLabel, kind = r.kind.name, index = r.index.toLong(),
                rank = r.rank.toLong(), of = r.of.toLong(), deltaMs = r.deltaMs, deltaSecPerKm = r.deltaSecPerKm,
                deltaVo2 = r.deltaVo2, value = r.value, text = fire.text, overlay = fire.overlay,
            ),
        )
        Log.i(TAG, "compare ${r.boardKey}#${r.index} rank ${r.rank}/${r.of} spoken=${fire.speak}")
    }

    /** Settings → Voice → "Spoken summary" (default on): one line as recording starts, set before start. */
    @Volatile
    var spokenSummary: Boolean = true

    /**
     * Voice coaching (Settings → Voice), set before start from the app's `setVoiceCoach` and on a resume
     * from the same prefs; null = off. Never active in a replay. Read on the recorder thread.
     */
    @Volatile
    var voiceCoach: VoiceCoach.Config? = null
        set(value) {
            field = value
            coachLines = value?.let { VoiceCoach(it) }
        }

    private var coachLines: VoiceCoach? = null

    /**
     * The run's start heat slowdown (fraction, null = no weather), from the app's `setCoachSlowdown` once
     * the first fix has fetched it: the same figure the run screen's live TRUE pace uses.
     */
    @Volatile
    var coachSlowdown: Double? = null

    /** Settings → Voice → "Km splits" (default on): a Free run says each km. Set before start and on change. */
    @Volatile
    var kmSplits: Boolean = true
        set(value) {
            field = value
            synchronized(this) { coach.kmSplits = value }
        }

    /**
     * Settings → Voice → "Check-in": what a Free or Trail km line says besides the split. Set before start and on a
     * resume from the app's `setCheckIn`; null (a replay, never set) = the plain km split. Read on the recorder thread.
     */
    @Volatile
    var checkIn: CheckInPlan? = null
        set(value) {
            field = value
            checkInTracker = value?.let { p -> CheckInTracker(p.zoneBottomsBpm).also { it.partial = checkInPartial } }
            synchronized(this) { coach.checkIn = value }
            // Voice detail is for Free and Trail runs; intervals and laps keep today's voice (Coaching detail governs their coaching lines).
            cues.voiceLevel = if (mode == RunMode.free || mode == RunMode.trail) value?.level ?: VoiceLevel.everything else VoiceLevel.everything
        }

    private var checkInTracker: CheckInTracker? = null

    /** The run was restored after a kill: its zone minutes are incomplete, whichever tracker is built. */
    private var checkInPartial = false

    /** Tests: the Voice detail the cue player is on (Free and Trail only; everything else is Everything). */
    internal val voiceLevel: VoiceLevel get() = cues.voiceLevel

    /** Tests: the check-in's tracker says only the zone (restored run). */
    internal val checkInSaysZoneOnly: Boolean get() = checkInTracker?.partial == true
    private var checkInPace: Double? = null
    private var checkInTruePace: Double? = null
    private var checkInLastT: Long? = null

    /** This tick's pace and True pace (the run screen's number), read by the next tick's [checkInTick]. */
    private fun checkInFeed(pace: Double?) {
        checkInPace = pace
        checkInTruePace = LiveTruePace.apply(pace, liveElev.grade, coachSlowdown, ticker.distanceM)
    }

    /** Offers a moving, recording tick to the check-in's tracker: pauses and auto-pauses count for nothing. */
    private fun checkInTick(t: Long, hr: Number?) {
        val tr = checkInTracker ?: return
        val dt = checkInLastT?.let { (t - it).coerceIn(0L, 2_000L) } ?: 0L
        checkInLastT = t
        if (replay != null || core.state != RecorderState.recording || core.autoPaused) return
        tr.noteElevation(liveElev.elevationM, baro = liveElev.source == ElevSource.baro)
        tr.tick(dt, (ticker.distanceM - coachPrevD).coerceAtLeast(0.0), checkInPace, checkInTruePace, hr?.toDouble())
    }

    /** The extra metrics at a km mark; only called when the km line is said. Barometer-only for height and climb (GPS altitude is too noisy to read out). */
    private fun checkInSnapshot(t: Long): CheckInSnapshot? {
        val tr = checkInTracker ?: return null
        val snap = tr.snapshot(core.status(t).activeMs, ticker.distanceM, liveElev.source == ElevSource.baro, liveElev.elevationM, liveElev.ascentM)
        // Retrace (the same detector the run screen reads): only while heading back over our own track.
        val r = retrace.state
        val back = r.takeIf { it.retracing && it.direction == RetraceDirection.reverse }
        return snap.copy(
            backToStartKm = back?.distanceToStartM?.let { it / 1000.0 },
            climbAheadM = back?.climbAheadM,
        )
    }

    /** The live coach as restored (tests: the resume path keeps the context and the fired cues). */
    internal val liveCoach: LiveCoach get() = coach

    /**
     * The goal is reached (§G): a long buzz and one line, the app's goal card, then the open
     * cool-down says km splits only (from the goal on: a whole-km distance goal keeps the split
     * pace going, a time goal starts it again at the next km).
     */
    private fun publishGoal(g: GoalCoach.Reached) {
        cues.goal(g.text)
        if (cues.enabled) logSaid(g.text)
        // The timed 5 km says its result line and stops: no goal card, no cool-down.
        if (spec?.isEvent == true) {
            Log.i(TAG, "event finished: ${g.text} interrupted=${g.interrupted}")
            return
        }
        RecorderEventBus.emit(
            GoalEvent(
                distanceGoal = g.distanceGoal, goalValue = g.goalValue.toLong(), timeMs = g.timeMs, distanceM = g.distanceM,
                newBest = g.newBest, interrupted = g.interrupted, text = g.text,
            ),
        )
        coach.goalReachedAt(g.distanceM, if (g.distanceGoal && g.goalValue % 1_000 == 0) g.timeMs else null)
        Log.i(TAG, "goal reached: ${g.text} interrupted=${g.interrupted}")
    }

    /**
     * "Mute tips" for this run (notification action or the app's button): compares keep firing
     * (journal, `CompareEvent`) but are not spoken; the app hides the card once `tipsMuted` is true.
     */
    @Synchronized
    fun muteTips() {
        // Not started yet (a pending session): no core, no journal header, so nothing to mute and
        // no `tm` line ahead of the header. No coaching this run: nothing to journal (#77 review).
        if (finished || !::core.isInitialized || !coach.active || coach.muted) return
        coach.muted = true
        cues.dropNudge()
        writer.append(JournalLine.TipsMuted(clock(), System.currentTimeMillis()))
        Log.i(TAG, "tips muted for $runId")
        onNotificationChanged?.invoke()
        // The app re-reads status() on a state event: its Mute tips button and the card go.
        emitState()
    }

    /**
     * Target status and zone drift ([VoiceCoach]), on the tick so they speak with the screen off. A
     * coachable segment is a work step (or the whole run when it has no steps); nothing in a pause,
     * warm-up, recovery or cool-down. The next-step line is the ten-seconds cue, not said from here.
     */
    private fun coachTick(t: Long, pace: Double?, hr: Number?) {
        val vc = coachLines ?: return
        if (replay != null || !cues.enabled) return
        val st = core.status(t)
        val steps = spec?.steps.orEmpty()
        val recording = st.state == RecorderState.recording && !core.autoPaused
        val segment = when {
            !recording -> null
            steps.isEmpty() -> 0
            st.phase == Phase.work -> st.stepIndex
            else -> null
        }
        // Like for like: the live TRUE pace the run screen shows (hills and heat out), against a True Pace target.
        val grade = liveElev.grade
        val truePace = LiveTruePace.apply(pace, grade, coachSlowdown, ticker.distanceM)
        // A distance rep has no time left to read: estimate it from the metres to go at the current pace, and treat the last 100 m as the end.
        val toEndMs = st.stepRemainingMs ?: st.stepRemainingM?.let { m -> if (m <= COACH_LAST_M) 0L else pace?.let { (m * it).toLong() } }
        // The sample's HR is null once the strap's last reading is over 2 s old (HrJoin.hrAt), so a dropped strap reaches the coach as null.
        val line = vc.tick(
            VoiceCoach.Input(
                t = t,
                segment = segment,
                segmentActiveMs = if (steps.isEmpty()) st.activeMs else st.phaseActiveMs,
                paceSecPerKm = truePace,
                hr = hr?.toDouble(),
                msToPhaseEnd = toEndMs,
                busyUntil = if (cues.nudgePending) t + 1 else cues.coachBusyUntil,
                wideBand = mode == RunMode.trail || (grade != null && abs(grade) > COACH_STEEP_GRADE),
            ),
        ) ?: return
        Log.i(TAG, "coach ${line.kind}: ${line.text}")
        cues.announce(line.text, if (line.kind == VoiceCoach.Kind.drift) CueSlot.zoneDrift else CueSlot.paceStatus)
    }

    private val trailMoments = TrailMoments()
    private var trailMomentsOff = false

    /**
     * Trail beats and the budget's held game beat, once a tick, on the recorder thread. A live Trail run on the Coach
     * level only; a failure here turns the feature off for the run, never the recording. The ghost fields are null until
     * the ghost engine fills them (see [MomentInput]); the finish verdict and the turnaround are offered through
     * [CuePlayer.moment] by their owners.
     */
    private fun trailMomentsTick(t: Long) {
        if (replay != null) return
        if (trailMomentsOff) {
            cues.hardEffort = false
            return
        }
        try {
            // Steep and working hard: the budget keeps the km and half km quiet (Free and Trail alike).
            cues.hardEffort = (liveElev.grade ?: 0.0) > HARD_GRADE && (checkInTracker?.smoothedZone() ?: 0) >= HARD_ZONE
            if (mode != RunMode.trail || core.state != RecorderState.recording || core.autoPaused) return
            val plan = checkIn ?: return
            if (plan.level != VoiceLevel.coach) return
            val input = MomentInput(
                nowMs = t,
                distM = ticker.distanceM,
                climbAheadM = retrace.state.takeIf { it.retracing && it.direction == RetraceDirection.reverse }?.climbAheadM,
                ascentM = liveElev.ascentM.takeIf { liveElev.source == ElevSource.baro },
                grade = liveElev.grade,
            )
            for (line in trailMoments.tick(input)) cues.moment(line)?.let { logSaid(it.text) }
            cues.dueMoment()?.let { logSaid(it.text) }
        } catch (e: Exception) {
            trailMomentsOff = true
            cues.hardEffort = false
            Log.w(TAG, "trail moments off: $e")
        }
    }

    /** Replay only (T4): what was said, at trace ms, for the emulator's transcript check. */
    private fun logSaid(text: String) {
        val r = replay ?: return
        Log.i(TAG, "said ${r.traceMs(clock())} $text")
    }

    // Voice coaching names the next step in the ten-seconds cue; a replay's transcript stays pinned.
    private fun cueText(o: RecorderCore.Output.Cue): String? =
        CueWords.text(o.kind, o.value, spec, core.phase, core.repIndex, core.stepIndex, o.index, coach = voiceCoach != null && replay == null)

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
            pausedAtElapsedMs = core.pausedAtElapsedMs,
            autoPaused = core.autoPaused,
            finishRequests = finishRequests.takeIf { it > 0 }?.toLong(),
            tipsMuted = tipsMuted(),
            elevGainM = liveElev.ascentM,
            elevLossM = liveElev.descentM,
            gradePct = liveElev.grade?.let { it * 100 },
            retracing = retrace.state.retracing,
            retraceSame = retrace.state.direction == RetraceDirection.same,
            backToStartM = retrace.state.distanceToStartM,
            climbAheadM = retrace.state.climbAheadM,
            descentAheadM = retrace.state.descentAheadM,
            heightVsStartM = retrace.state.heightVsStartM,
            route = routeProgress(),
            trail = trailProgress(),
        )
    }

    /**
     * Set by whoever arbitrates speech (the voice budget): the ghost's turnaround is then offered to it instead of being
     * said here. Null = say it straight away.
     */
    @Volatile
    var trailCueSink: TrailCueSink? = null

    private fun trailTurn(e: RouteFollower.Event.RouteEnd) {
        val sink = trailCueSink
        val id = trailFeed.state?.trailId
        if (sink != null && id != null) sink.turnaround(id, e.text, e.t) else routeEvent(e)
    }

    /** The ghost's clock: advances by the time since the last fix (a kill gap or a long silence counts for at most 5 s) while [running]. */
    private fun ghostClock(t: Long, running: Boolean): Long {
        val prev = ghostLastT
        ghostLastT = t
        if (prev != null && running) ghostActiveMs += (t - prev).coerceIn(0L, GHOST_MAX_STEP_MS)
        return ghostActiveMs
    }

    /** The known trail the run is on, with its ahead/behind; null until matched (and when the ghost is off). */
    private fun trailProgress(): TrailProgress? {
        val s = trailFeed.state ?: return null
        return TrailProgress(
            trailId = s.trailId,
            name = s.name,
            alongM = s.alongM,
            toGoM = s.toGoM,
            off = s.off,
            aheadBestMs = s.aheadBestMs,
            aheadLastMs = s.aheadLastMs,
            lastIsBest = s.lastIsBest,
            bestDateMs = s.bestDateMs,
            lastDateMs = s.lastDateMs,
            toTurnM = s.toTurnM,
            turnCue = s.turnCue,
            elevProfile = s.elevProfile,
            elevStepM = s.elevStepM,
            climbs = s.climbs.takeIf { it.isNotEmpty() }?.map { TrailClimb(it.startM, it.endM, it.gainM, it.avgGradePct) },
            toClimbM = s.toClimbM,
            inClimb = s.inClimb,
            racing = s.racing.name,
        )
    }

    /** The followed route's figures for the app; the next turn only while it is close enough to matter. */
    private fun routeProgress(): RouteProgress? {
        val f = follower ?: return null
        val turnIn = f.nextTurnInM?.takeIf { it <= TURN_STRIP_M }
        return RouteProgress(
            toGoM = f.toGoM,
            climbToGoM = f.climbToGoM,
            off = f.off,
            turnLabel = turnIn?.let { f.nextTurn?.let { turn -> RouteWords.turnLabel(turn) } },
            turnInM = turnIn,
            endCue = when (f.endCue) {
                RouteFollower.EndKind.turnAround -> RouteEndCue.TURN_AROUND
                RouteFollower.EndKind.done -> RouteEndCue.DONE
                null -> null
            },
        )
    }

    /** Off route, back on route and the turn cues: a buzz and a line through the cue player (its settings apply to the voice). */
    private fun routeEvent(e: RouteFollower.Event) {
        when (e) {
            is RouteFollower.Event.OffRoute -> {
                cues.alert(RouteWords.OFF_ROUTE, longArrayOf(0, 400, 150, 400, 150, 400), CueSlot.offRoute)
                logSaid(RouteWords.OFF_ROUTE)
                Log.i(TAG, "off route at ${core.status(e.t).elapsedMs} ms, ${"%.0f".format(follower?.offsetM ?: 0.0)} m from the line")
            }
            is RouteFollower.Event.BackOnRoute -> {
                cues.alert(RouteWords.BACK_ON_ROUTE, longArrayOf(0, 120, 80, 120), CueSlot.offRoute)
                logSaid(RouteWords.BACK_ON_ROUTE)
                Log.i(TAG, "back on route at ${core.status(e.t).elapsedMs} ms")
            }
            is RouteFollower.Event.RouteEnd -> {
                // Two long pulses: unlike the off-route triple or the short turn tick. The screen cue comes from [routeProgress].
                cues.alert(e.text, longArrayOf(0, 600, 200, 600), CueSlot.routeEnd)
                logSaid(e.text)
                Log.i(TAG, "route end: ${e.kind}")
            }
            is RouteFollower.Event.Turn -> {
                cues.alert(e.text, longArrayOf(0, 150), CueSlot.turnaround)
                logSaid(e.text)
                Log.i(TAG, "route turn: ${e.text}")
            }
        }
    }

    /** null: no live coaching this run (nothing to compare, or Coaching tips off in Settings). */
    private fun tipsMuted(): Boolean? = if (!coach.active || liveContext?.coachingMuted == true) null else coach.muted

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
            muteTipsAction = coach.active && !coach.muted,
            autoPaused = core.autoPaused,
        )
    }

    val state: RecorderState get() = if (::core.isInitialized) core.state else RecorderState.idle

    companion object {
        const val TAG = "RunSolo/session"

        /** The strip shows the next turn from this far out. */
        private const val TURN_STRIP_M = 300.0
        private const val GHOST_MAX_STEP_MS = 5_000L


        /** Voice coaching: a distance rep this close to its end counts as ended; a grade over 3% widens the band. */
        private const val COACH_LAST_M = 100.0

        /** The Coach level keeps the km and half km quiet above this grade (a fraction) and this smoothed HR zone. */
        private const val HARD_GRADE = 0.08
        private const val HARD_ZONE = 4
        private const val COACH_STEEP_GRADE = 0.03
        private const val VOLUME_KEY_UNAVAILABLE_MARKER = "volume-key-unavailable"
    }
}
