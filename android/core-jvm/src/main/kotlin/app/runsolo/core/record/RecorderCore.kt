package app.runsolo.core.record

import app.runsolo.core.gps.PointFilter
import app.runsolo.core.journal.Replay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.live.CooperCurve
import app.runsolo.core.live.CooperProjection
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind

/**
 * Lap state machine + session step engine + cue scheduler, device-independent (plan §3, §6;
 * Phase 3 §3.6).
 *
 * The service owns the clock and calls [tick] at ≥ 1 Hz with device monotonic millis and the
 * live filtered, pause-frozen distance (the same `PointFilter` rule the finaliser uses); the core
 * returns [Output]s (laps to journal, cues to speak, phase changes for the notification, an
 * auto-stop). It never sleeps, never touches I/O, and is rebuilt after a kill from the journal
 * via [restore].
 *
 * Timeline: `elapsed` counts wall time since start (pauses included, as the file's `t` does);
 * phase timers count ACTIVE time only, so a pause freezes the countdown (and the distance).
 *
 * Rules:
 *  - Warm-up and cool-down are open (untimed) unless the session fixes them. An open warm-up
 *    ends on the first manual LAP or `startReps`; a fixed one also ends by itself.
 *  - A step ends by its `phaseEnd` cue (auto-lap) or early by a manual LAP from the
 *    button/notification, which re-aligns the phases (R5: the engine may then call the run
 *    `lapsInconsistent`; that is the user's choice).
 *  - Steps: time (seconds), distance (metres; ends at the first tick at or past the target,
 *    the boundary time interpolated between the two ticks, never extrapolated: with no GPS the
 *    step does not end on its own), equal-time recovery (as long as the work step before it
 *    actually took, manual LAP included). A 0 s recovery goes straight into the next rep.
 *  - Modes (plan §18.2): `intervals` and `cooper` walk [SessionSpec.steps] (work, recovery, …,
 *    work; N reps have N−1 recoveries); `laps` = by-feel laps from any source (a fartlek spec
 *    changes nothing here); `free` = no lap input at all. Cooper takes no LAP either (its
 *    `startReps` starts the 12:00; lap lockout). Every mode check is an exhaustive `when` (W7).
 *  - Lap lockout: every manual lap during a work step is ignored.
 *  - Auto-stop ([SessionSpec.autoStop]): when the last timed part ends (the last step, or a
 *    fixed cool-down), [Output.AutoStop] asks the shell to stop; no lap marks that boundary, the
 *    stop ends the lap.
 *  - Volume-key laps: only when [Config.volumeKeyLaps] (default: Laps mode only). In
 *    a structured session they are recorded but never re-align the phase (pocket-bump guard, W8).
 *  - Double-lap guard: a manual press within [Config.doubleLapGuardMs] of an auto-lap is
 *    ignored; any manual press within [Config.debounceMs] of the previous manual lap is ignored,
 *    [Config.unstructuredDebounceMs] in a run without steps (Laps, by-feel): there LAP is the
 *    main control and a second press after a missed-looking first one would be a real extra lap.
 *  - Laps while paused are ignored.
 */
class RecorderCore(
    val mode: RunMode,
    val spec: SessionSpec?,
    private val config: Config = Config(volumeKeyLaps = mode.volumeKeyLapsDefault),
) {
    data class Config(
        val volumeKeyLaps: Boolean,
        val doubleLapGuardMs: Long = 5_000,
        val debounceMs: Long = 400,
        val unstructuredDebounceMs: Long = 1_500,
        /** The Cooper fade curve (Phase 4 §3.3): the LiveContext's personal curve, else the default. */
        val cooperCurve: CooperCurve = CooperCurve.DEFAULT,
    )

    sealed class Output {
        data class Lap(val index: Int, val t: Long, val source: LapSource) : Output()

        /**
         * [value]: `projection` = projected Cooper distance in metres (Cooper) or projected finish
         * in ms (distance step); `minuteMark` = the minute; `phaseEnd` = [CueWords.COOLDOWN_OVER]
         * when it closes a fixed cool-down.
         */
        data class Cue(val t: Long, val kind: CueKind, val value: Double? = null, val index: Int? = null) : Output()
        data class PhaseChanged(val t: Long, val phase: Phase, val repIndex: Int, val phaseDurationMs: Long?) : Output()

        /** The session is over ([SessionSpec.autoStop]); the shell stops the recording. */
        data class AutoStop(val t: Long) : Output()
    }

    enum class LapDecision { accepted, ignoredDoubleLap, ignoredDebounce, ignoredVolumeKeyDisabled, ignoredPaused, ignoredIdle, ignoredModeNoLaps, ignoredNotWarmup, ignoredLockout }

    data class Status(
        val state: RecorderState,
        val elapsedMs: Long,
        val activeMs: Long,
        val lapIndex: Int,
        val phase: Phase,
        val repIndex: Int,
        val phaseRemainingMs: Long,
        /** 0-based index into [SessionSpec.steps] during work/recovery; null in warm-up, cool-down and unstructured runs. */
        val stepIndex: Int?,
        /** Time left in a time or equal-time step; null otherwise. */
        val stepRemainingMs: Long?,
        /** Metres left in a distance step; null otherwise. */
        val stepRemainingM: Double?,
        /** Active time into the current phase (pauses and gaps excluded). */
        val phaseActiveMs: Long = 0,
    )

    init {
        unsupported(mode, spec)?.let { throw IllegalArgumentException(it) }
    }

    /**
     * Phases follow [spec]. An `intervals` run with no session is a by-feel 4x4 read from a
     * schema ≤ 2 file or journal (`fourByFour` without a preset): it records like `laps`.
     */
    private val structured: Boolean = mode.followsSteps && spec != null

    var state: RecorderState = RecorderState.idle
        private set
    var lapCount: Int = 0
        private set
    var phase: Phase = Phase.none
        private set

    /** 1-based rep number during work/recovery; 0 in warmup/none, the last rep through cool-down. */
    var repIndex: Int = 0
        private set

    /** 0-based index into [SessionSpec.steps] while a step runs; null otherwise. */
    var stepIndex: Int? = null
        private set

    /** True once [Output.AutoStop] was emitted (also after a [restore] that ends past the session). */
    var autoStopped: Boolean = false
        private set

    private var startT = 0L
    private var pausedTotalMs = 0L
    private var pauseStartT: Long? = null
    private var lastT = 0L

    /** Distance (m) and device time of the last tick: the interpolation base for distance boundaries. */
    private var lastD = 0.0

    /** The distance as of the last tick (after a restore: rebuilt from the journal's samples). */
    val distanceM: Double get() = lastD
    private var lastDT = 0L
    private var gpsOk = true

    private var phaseStartActive = 0L
    private var phaseStartD = 0.0

    /** Active ms the current phase lasts (time, equal-time, fixed warm-up/cool-down), or null. */
    private var phaseDurationMs: Long? = null

    /** Metres the current distance step covers, or null. */
    private var phaseTargetM: Long? = null
    private var pendingCues: ArrayDeque<CueScheduler.CuePoint> = ArrayDeque()

    /**
     * A step started by a manual LAP / `startReps` between two ticks: its start distance is
     * re-read at the next tick, interpolated at the press time (as the run file sees it), so a
     * distance step does not count the sample before the press.
     */
    private var pendingStartT: Long? = null

    /** Measured active time of the last work step (the equal-time recovery's length). */
    private var lastWorkActiveMs = 0L
    private var lastAutoLapT: Long? = null
    private var lastManualLapT: Long? = null

    private val timed: Boolean get() = phaseDurationMs != null || phaseTargetM != null

    private fun elapsedAt(t: Long) = t - startT
    private fun activeAt(t: Long): Long {
        val ps = pauseStartT
        val currentPause = if (ps != null) (t - ps).coerceAtLeast(0) else 0
        return elapsedAt(t) - pausedTotalMs - currentPause
    }

    fun start(t: Long): List<Output> {
        check(state == RecorderState.idle) { "already started" }
        startT = t
        lastT = t
        lastDT = t
        state = RecorderState.recording
        val out = ArrayList<Output>()
        if (structured && spec!!.warmupSeconds == 0) {
            // No warm-up (parkrun): step 1 begins now, from 0 m; there is no warm-up lap and
            // startReps() is a no-op (not in a warm-up).
            out.addAll(enterFirstStep(t, 0.0))
        } else if (structured) {
            phase = Phase.warmup
            phaseStartActive = 0
            val fixed = spec!!.warmupSeconds?.let { it * 1000L }
            phaseDurationMs = fixed
            pendingCues = if (fixed != null) ArrayDeque(CueScheduler.edge(fixed)) else ArrayDeque()
            out.add(Output.PhaseChanged(t, phase, 0, fixed))
        }
        return out
    }

    fun pause(t: Long): List<Output> {
        if (state != RecorderState.recording) return emptyList()
        state = RecorderState.paused
        pauseStartT = t
        lastT = t
        // A press earlier in this second starts its step at the distance the pause froze: no
        // later sample counts while paused (the shell's next tick, the replay's next sample and
        // the run file all read this distance), so do not wait for a tick after the resume.
        if (pendingStartT != null) {
            phaseStartD = lastD
            pendingStartT = null
        }
        return emptyList()
    }

    fun resume(t: Long): List<Output> {
        if (state != RecorderState.paused) return emptyList()
        val ps = pauseStartT ?: t
        pausedTotalMs += (t - ps).coerceAtLeast(0)
        pauseStartT = null
        state = RecorderState.recording
        lastT = t
        lastDT = t // no distance was counted while paused; do not interpolate across the pause
        return emptyList()
    }

    fun stop(t: Long): List<Output> {
        if (state == RecorderState.idle || state == RecorderState.finalising) return emptyList()
        if (state == RecorderState.paused) resume(t)
        state = RecorderState.finalising
        phase = Phase.none
        stepIndex = null
        return listOf(Output.Cue(t, CueKind.stop))
    }

    /** A LAP from any source. Returns the decision plus the outputs to journal/speak. */
    fun lap(source: LapSource, t: Long): Pair<LapDecision, List<Output>> {
        if (state == RecorderState.idle || state == RecorderState.finalising) return LapDecision.ignoredIdle to emptyList()
        if (!mode.lapInput) return LapDecision.ignoredModeNoLaps to emptyList()
        if (state == RecorderState.paused) return LapDecision.ignoredPaused to emptyList()
        if (source == LapSource.auto) {
            // Only restore() feeds auto laps; live auto-laps come from the cue scheduler in tick().
            return LapDecision.accepted to endTimedPhase(t, auto = true)
        }
        if (source == LapSource.volumeKey && !config.volumeKeyLaps) return LapDecision.ignoredVolumeKeyDisabled to emptyList()
        if (spec?.lapLockout == true && phase == Phase.work) return LapDecision.ignoredLockout to emptyList()
        lastAutoLapT?.let { if (t - it < config.doubleLapGuardMs) return LapDecision.ignoredDoubleLap to emptyList() }
        val debounceMs = if (structured) config.debounceMs else config.unstructuredDebounceMs
        lastManualLapT?.let { if (t - it < debounceMs) return LapDecision.ignoredDebounce to emptyList() }
        return LapDecision.accepted to applyManualLap(source, t)
    }

    /**
     * The "Start reps" action: ends the warm-up and starts rep 1 (plan §6). Journaled as a
     * button lap so the file is what a first LAP would have written; a no-op anywhere else
     * (a press mid-rep is never a lap, so a manual LAP cannot be confused with starting). The
     * one way to start a Cooper test, which takes no LAP.
     */
    fun startReps(t: Long): Pair<LapDecision, List<Output>> {
        if (state == RecorderState.idle || state == RecorderState.finalising) return LapDecision.ignoredIdle to emptyList()
        if (state == RecorderState.paused) return LapDecision.ignoredPaused to emptyList()
        if (!structured || phase != Phase.warmup) return LapDecision.ignoredNotWarmup to emptyList()
        return LapDecision.accepted to applyManualLap(LapSource.button, t)
    }

    /** Records a manual lap with no gate or guard: what was journaled did happen. */
    private fun applyManualLap(source: LapSource, t: Long): List<Output> {
        lastManualLapT = t
        val out = ArrayList<Output>()
        // A goal's step ends on its distance or time only (§G): a LAP in it marks a lap, no more.
        val goalStep = spec?.isGoal == true && phase == Phase.work
        val realigns = structured && source != LapSource.volumeKey && !goalStep
        noteLapStep(lapCount, realigns)
        out.add(Output.Lap(lapCount++, t, source))
        if (realigns) {
            when (phase) {
                Phase.warmup -> out.addAll(enterFirstStep(t, lastD))
                Phase.work, Phase.recovery -> out.addAll(advance(t, lastD))
                Phase.cooldown, Phase.none -> Unit
            }
            if (stepIndex != null) pendingStartT = t
        }
        return out
    }

    /**
     * Advance the clock: emits due cues, the auto-lap at a step's end and the auto-stop.
     * [distanceM] is the live filtered, pause-frozen total; [gpsOk] false suppresses the
     * projection cues (a projection from a stale distance would be wrong).
     */
    fun tick(t: Long, distanceM: Double = lastD, gpsOk: Boolean = true): List<Output> {
        lastT = t
        this.gpsOk = gpsOk
        if (state != RecorderState.recording) return emptyList()
        val prevT = lastDT
        val prevD = lastD
        lastD = distanceM
        lastDT = t
        pendingStartT?.let { pt ->
            phaseStartD = distanceAtTime(pt, prevT, prevD, t, distanceM)
            pendingStartT = null
        }
        val out = ArrayList<Output>()
        var guard = 0
        while (timed && guard++ < 256) {
            val target = phaseTargetM
            if (target != null) {
                val covered = distanceM - phaseStartD
                val cue = pendingCues.firstOrNull() ?: break
                if (covered < cue.at) break
                pendingCues.removeFirst()
                if (cue.kind == CueKind.phaseEnd) {
                    // Interpolate the crossing between the two ticks; a step that began after
                    // prevT (a boundary earlier in this loop) starts from its own start distance.
                    val fromD = maxOf(prevD, phaseStartD)
                    val fromT = if (prevD >= phaseStartD) prevT else boundaryStartT(prevT, t)
                    val frac = if (distanceM > fromD) ((phaseStartD + target - fromD) / (distanceM - fromD)).coerceIn(0.0, 1.0) else 1.0
                    val bt = (fromT + frac * (t - fromT)).toLong().coerceIn(fromT, t)
                    out.add(Output.Cue(bt, CueKind.phaseEnd))
                    out.addAll(endTimedPhase(bt, auto = true, endD = phaseStartD + target))
                } else {
                    cueOut(t, cue)?.let { out.add(it) }
                }
            } else {
                val dur = phaseDurationMs!!
                val phaseElapsed = activeAt(t) - phaseStartActive
                val cue = pendingCues.firstOrNull() ?: break
                if (phaseElapsed < cue.at) break
                pendingCues.removeFirst()
                if (cue.kind == CueKind.phaseEnd) {
                    // Fire exactly at the boundary so the lap time is the step time, not tick jitter.
                    val bt = t - (phaseElapsed - dur)
                    out.add(Output.Cue(bt, CueKind.phaseEnd, if (phase == Phase.cooldown) CueWords.COOLDOWN_OVER else null))
                    out.addAll(endTimedPhase(bt, auto = true, endD = distanceAtTime(bt, prevT, prevD, t, distanceM)))
                } else {
                    cueOut(t, cue)?.let { out.add(it) }
                }
            }
        }
        return out
    }

    /**
     * What lap [Output.Lap.index] did to the session's steps (LV1: a live rep pace belongs to the
     * step its lap ended, not to "lap i − 1"): [endedStep] = the step it ended (null for the
     * warm-up lap, a lap in the cool-down, a volume-key lap mid-step, an unstructured run);
     * [startsStep] = a new step or the cool-down begins at it. A 0 s recovery has no lap, and a
     * lap that does not re-align ends nothing, so neither shifts the reps that follow. Kept for
     * every lap, and rebuilt by [restore] (which replays the laps through the same code).
     */
    data class LapStep(val endedStep: Int?, val startsStep: Boolean)

    private val lapSteps = HashMap<Int, LapStep>()

    fun lapStep(index: Int): LapStep? = lapSteps[index]

    private fun noteLapStep(index: Int, realigns: Boolean) {
        val inStep = phase == Phase.work || phase == Phase.recovery
        lapSteps[index] = LapStep(
            endedStep = if (realigns && inStep) stepIndex else null,
            startsStep = realigns && (inStep || phase == Phase.warmup),
        )
    }

    /**
     * Where the session's last step ended: its (back-dated) time, active run ms and distance. A
     * goal's reached point (§G: moving time at the goal distance, distance at the goal time).
     * Set once when the last step closes; [restore] sets it again from the journal.
     */
    data class StepEnd(val t: Long, val activeMs: Long, val distanceM: Double)

    var finalStepEnd: StepEnd? = null
        private set

    /** The time a step that started inside this tick began (the last boundary emitted), for interpolation. */
    private var lastBoundaryT = 0L
    private fun boundaryStartT(prevT: Long, t: Long) = lastBoundaryT.coerceIn(prevT, t)

    fun distanceAtTime(bt: Long, prevT: Long, prevD: Double, t: Long, d: Double): Double =
        if (t <= prevT) d else prevD + (d - prevD) * ((bt - prevT).toDouble() / (t - prevT)).coerceIn(0.0, 1.0)

    /** A due non-boundary cue, with its value; null when suppressed. */
    private fun cueOut(t: Long, cue: CueScheduler.CuePoint): Output.Cue? {
        if (cue.kind == CueKind.minuteMark) return Output.Cue(t, cue.kind, (cue.at / 60_000).toDouble(), (cue.at / 60_000).toInt())
        if (cue.kind != CueKind.projection) return Output.Cue(t, cue.kind)
        if (!gpsOk) return null
        val activeMs = activeAt(t) - phaseStartActive
        val covered = lastD - phaseStartD
        return when (val target = phaseTargetM) {
            null -> {
                // Cooper: projected 12-minute distance through the fade curve (§3.3), index = the minute.
                val projected = CooperProjection.project(config.cooperCurve, activeMs / 1_000.0, covered) ?: return null
                Output.Cue(t, CueKind.projection, projected, (cue.at / 60_000).toInt())
            }
            else -> {
                // Distance step: projected finish time of the step, from its own start; index = the km.
                if (covered <= 0 || activeMs <= 0) return null
                Output.Cue(t, CueKind.projection, activeMs / covered * target, (cue.at / 1_000).toInt())
            }
        }
    }

    fun status(t: Long): Status {
        val remainingMs = phaseDurationMs?.let { (it - (activeAt(t) - phaseStartActive)).coerceAtLeast(0) }
        val remainingM = phaseTargetM?.let { (it - (lastD - phaseStartD)).coerceAtLeast(0.0) }
        return Status(
            state = state,
            elapsedMs = if (state == RecorderState.idle) 0 else elapsedAt(t),
            activeMs = if (state == RecorderState.idle) 0 else activeAt(t),
            lapIndex = lapCount,
            phase = phase,
            repIndex = repIndex,
            phaseRemainingMs = remainingMs ?: 0L,
            stepIndex = stepIndex,
            stepRemainingMs = if (stepIndex != null) remainingMs else null,
            stepRemainingM = if (stepIndex != null) remainingM else null,
            phaseActiveMs = if (state == RecorderState.idle) 0 else activeAt(t) - phaseStartActive,
        )
    }

    private fun endTimedPhase(t: Long, auto: Boolean, endD: Double = lastD): List<Output> {
        if (!timed) return emptyList()
        val out = ArrayList<Output>()
        if (auto && !(spec?.autoStop == true && isFinalTimedPart())) {
            lastAutoLapT = t
            noteLapStep(lapCount, realigns = true)
            out.add(Output.Lap(lapCount++, t, LapSource.auto))
        }
        lastBoundaryT = t
        out.addAll(
            when (phase) {
                Phase.warmup -> enterFirstStep(t, endD)
                Phase.work, Phase.recovery -> advance(t, endD)
                Phase.cooldown -> finishCooldown(t)
                Phase.none -> emptyList()
            },
        )
        return out
    }

    /** The part ending now is the session's last timed part (the last step with an open cool-down, or the fixed cool-down). */
    private fun isFinalTimedPart(): Boolean {
        val s = spec ?: return false
        return when (phase) {
            Phase.cooldown -> true
            Phase.work, Phase.recovery -> s.cooldownSeconds == null && nextStepIndex(stepIndex ?: return false) >= s.steps.size
            Phase.warmup, Phase.none -> false
        }
    }

    private fun nextStepIndex(from: Int): Int {
        val steps = spec!!.steps
        var next = from + 1
        while (next < steps.size && steps[next].target == TargetKind.time && steps[next].value == 0) next++
        return next
    }

    private fun enterFirstStep(t: Long, startD: Double): List<Output> =
        if (spec!!.steps.isEmpty()) enterCooldown(t) else enterStep(t, 0, startD)

    /**
     * Move from the current step to the next one. The spec has no recovery after the last rep
     * (founder field test 25-Sep), so the last work step goes to cool-down; a 0 s recovery is
     * skipped (no phase, no lap).
     */
    private fun advance(t: Long, startD: Double): List<Output> {
        val from = stepIndex ?: return emptyList()
        if (phase == Phase.work) lastWorkActiveMs = activeAt(t) - phaseStartActive
        val next = nextStepIndex(from)
        if (next >= spec!!.steps.size) finalStepEnd = StepEnd(t, activeAt(t), startD)
        return if (next < spec.steps.size) enterStep(t, next, startD) else enterCooldown(t)
    }

    private fun enterStep(t: Long, index: Int, startD: Double): List<Output> {
        val s = spec!!
        val step = s.steps[index]
        phase = when (step.kind) {
            StepKind.work -> Phase.work
            StepKind.recovery -> Phase.recovery
        }
        repIndex = step.rep
        stepIndex = index
        phaseStartActive = activeAt(t)
        phaseStartD = startD
        val out = ArrayList<Output>()
        when (step.target) {
            TargetKind.distance -> {
                phaseDurationMs = null
                phaseTargetM = step.value.toLong()
                pendingCues = ArrayDeque(CueScheduler.distance(step.value.toLong()))
            }
            TargetKind.time, TargetKind.equalToPreviousWork -> {
                val dur = if (step.target == TargetKind.time) step.value * 1000L else lastWorkActiveMs.coerceAtLeast(1_000)
                phaseDurationMs = dur
                phaseTargetM = null
                pendingCues = ArrayDeque(
                    when (s.cueProfile) {
                        CueProfile.standard -> CueScheduler.forPhase(dur)
                        CueProfile.short -> CueScheduler.short(dur)
                        CueProfile.cooper -> CueScheduler.cooper(dur)
                    },
                )
            }
        }
        out.add(Output.PhaseChanged(t, phase, repIndex, phaseDurationMs))
        // The `start` cue is due at 0 — emit it now rather than on the next tick.
        pendingCues.removeFirst()
        out.add(Output.Cue(t, CueKind.start))
        if (phase == Phase.work && s.reps > 1 && index == s.steps.indexOfLast { it.kind == StepKind.work }) out.add(Output.Cue(t, CueKind.lastRep))
        return out
    }

    private fun enterCooldown(t: Long): List<Output> {
        val s = spec!!
        phase = Phase.cooldown
        stepIndex = null
        phaseStartActive = activeAt(t)
        phaseTargetM = null
        val fixed = s.cooldownSeconds?.let { it * 1000L }
        phaseDurationMs = fixed
        pendingCues = if (fixed != null) ArrayDeque(CueScheduler.edge(fixed)) else ArrayDeque()
        val out = ArrayList<Output>()
        out.add(Output.PhaseChanged(t, phase, repIndex, fixed))
        if (fixed == null && s.autoStop) out.add(autoStop(t))
        return out
    }

    /** A fixed cool-down ran out: untimed from here; the recording stops if the session says so. */
    private fun finishCooldown(t: Long): List<Output> {
        phaseDurationMs = null
        pendingCues = ArrayDeque()
        return if (spec?.autoStop == true) listOf(autoStop(t)) else emptyList()
    }

    private fun autoStop(t: Long): Output {
        autoStopped = true
        return Output.AutoStop(t)
    }

    companion object {
        /**
         * Why this core cannot run [spec] in [mode], or null when it can: an invalid spec, or
         * one that does not fit the mode.
         */
        fun unsupported(mode: RunMode, spec: SessionSpec?): String? {
            spec?.problems()?.takeIf { it.isNotEmpty() }?.let { return "invalid session: ${it.joinToString("; ")}" }
            return when (mode) {
                RunMode.intervals -> when {
                    spec == null -> null // a by-feel 4x4 from an old journal; new runs are refused by the shell
                    spec.steps.isEmpty() -> "intervals needs steps"
                    else -> null
                }
                RunMode.laps -> if (spec == null || (spec.isFartlek && spec.steps.isEmpty())) null else "laps takes no session but a fartlek"
                RunMode.free -> if (spec == null) null else "free takes no session"
                RunMode.cooper -> if (spec?.templateId == SessionSpec.COOPER_ID) null else "cooper needs the Cooper session"
            }
        }

        /**
         * Rebuild the machine from a replayed journal after a kill (plan §3: step phase rebuilt
         * from the lap lines; W12; Phase 3 §3.6 W2). [nowT] is the device time at which the `gap`
         * line was written, i.e. run time [Replay.endT] maps to device time [nowT]. Samples only
         * rebuild the distance (a `PointFilter` with the finaliser's pause rule); step changes come
         * only from journaled laps, so a journaled distance auto-lap can never fire twice. Cues
         * already spoken before the kill are not re-spoken; the machine resumes in the paused
         * state if the journal ended paused, else recording.
         */
        fun restore(replay: Replay, nowT: Long, config: Config? = null): RecorderCore {
            val h = replay.header
            val core = if (config != null) RecorderCore(h.mode, h.session, config) else RecorderCore(h.mode, h.session)
            val base = nowT - replay.endT // deviceT = runT + base
            core.start(base)
            val filter = PointFilter()
            var paused = false
            var prevSampleT = base
            for (e in replay.events) {
                val t = e.t + base
                when (e) {
                    is RunEvent.Sample -> {
                        val before = filter.totalM
                        if (e.hasFix && !paused) {
                            filter.offer(LocationFix(e.t, e.lat!!, e.lon!!, e.altM, e.accuracyM!!, e.speedMps))
                            core.lastD = filter.totalM
                        }
                        // As live: a step started by a press between two samples starts at the interpolated distance.
                        core.pendingStartT?.let { pt ->
                            core.phaseStartD = core.distanceAtTime(pt, prevSampleT, before, t, filter.totalM)
                            core.pendingStartT = null
                        }
                        prevSampleT = t
                    }
                    is RunEvent.Lap -> {
                        // Replay bypasses every gate and guard: whatever was journaled did happen.
                        if (core.state == RecorderState.paused) continue
                        if (e.source == LapSource.auto) {
                            // A distance auto-lap starts the next step exactly at the target, as live.
                            val endD = core.phaseTargetM?.let { core.phaseStartD + it } ?: filter.totalM
                            core.endTimedPhase(t, auto = true, endD = endD)
                        } else {
                            core.lastD = filter.totalM
                            core.applyManualLap(e.source, t)
                        }
                    }
                    is RunEvent.Pause -> {
                        paused = true
                        core.pause(t)
                    }
                    is RunEvent.Resume -> {
                        paused = false
                        filter.reanchor()
                        core.resume(t)
                    }
                    is RunEvent.Gap -> {
                        // The run was dark from e.t to e.endT; phase timers must not count it.
                        // If it was already paused, the open pause covers the span.
                        if (core.state != RecorderState.paused) core.pausedTotalMs += e.endT - e.t
                    }
                    is RunEvent.Cue, is RunEvent.HrLink -> Unit
                }
            }
            core.lastD = filter.totalM
            core.lastDT = nowT
            // Cues whose time or distance has passed were spoken (or lost with the process); do not repeat.
            val passed: Long = if (core.phaseTargetM != null) (core.lastD - core.phaseStartD).toLong() else core.activeAt(nowT) - core.phaseStartActive
            while (core.timed) {
                val c = core.pendingCues.firstOrNull() ?: break
                if (c.kind == CueKind.phaseEnd || c.at > passed) break
                core.pendingCues.removeFirst()
            }
            core.lastT = nowT
            return core
        }
    }
}
