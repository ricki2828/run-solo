package app.runsolo.core.record

import app.runsolo.core.journal.Replay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.model.CueProfile

/**
 * Lap state machine + session step timer + cue scheduler, device-independent (plan §3, §6;
 * Phase 3 §3.6).
 *
 * The service owns the clock and calls [tick] at ≥ 1 Hz with device monotonic millis; the core
 * returns [Output]s (laps to journal, cues to speak, phase changes for the notification). It
 * never sleeps, never touches I/O, and is rebuilt after a kill from the journal via [restore].
 *
 * Timeline: `elapsed` counts wall time since start (pauses included, as the file's `t` does);
 * phase timers count ACTIVE time only, so a pause freezes the countdown.
 *
 * Rules:
 *  - Warmup and cooldown are untimed. The first manual LAP (button/notification) starts rep 1.
 *  - A timed phase ends by its `phaseEnd` cue (auto-lap) or early by a manual LAP from the
 *    button/notification, which re-aligns the phases (R5: the engine may then call the run
 *    `lapsInconsistent`; that is the user's choice).
 *  - Modes (plan §18.2): `intervals` = the phases walk [SessionSpec.steps] (work, recovery,
 *    …, work; N reps have N−1 recoveries; a 0 s recovery goes straight into the next rep);
 *    `laps` = by-feel laps from any source (a fartlek spec changes nothing here); `free` (and
 *    `cooper` until I2) = no lap input at all — every LAP is [LapDecision.ignoredModeNoLaps].
 *    Every mode check is an exhaustive `when` (W7).
 *  - I1 runs time steps only; [unsupported] names what a spec needs that this core cannot do yet.
 *  - Volume-key laps: only when [Config.volumeKeyLaps] (default: Laps mode only). In
 *    a structured session they are recorded but never re-align the phase (pocket-bump guard, W8).
 *  - Double-lap guard: a manual press within [Config.doubleLapGuardMs] of an auto-lap is
 *    ignored; any manual press within [Config.debounceMs] of the previous manual lap is ignored.
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
    )

    sealed class Output {
        data class Lap(val index: Int, val t: Long, val source: LapSource) : Output()
        data class Cue(val t: Long, val kind: CueKind) : Output()
        data class PhaseChanged(val t: Long, val phase: Phase, val repIndex: Int, val phaseDurationMs: Long?) : Output()
    }

    enum class LapDecision { accepted, ignoredDoubleLap, ignoredDebounce, ignoredVolumeKeyDisabled, ignoredPaused, ignoredIdle, ignoredModeNoLaps, ignoredNotWarmup }

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
        val stepRemainingMs: Long?,
        /** Metres left in a distance step; always null until distance steps land (I2). */
        val stepRemainingM: Double?,
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

    private var startT = 0L
    private var pausedTotalMs = 0L
    private var pauseStartT: Long? = null
    private var lastT = 0L

    private var phaseStartActive = 0L
    private var phaseDurationMs: Long? = null
    private var pendingCues: ArrayDeque<CueScheduler.CuePoint> = ArrayDeque()
    private var lastAutoLapT: Long? = null
    private var lastManualLapT: Long? = null

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
        state = RecorderState.recording
        val out = ArrayList<Output>()
        if (structured) {
            phase = Phase.warmup
            out.add(Output.PhaseChanged(t, phase, 0, null))
        }
        return out
    }

    fun pause(t: Long): List<Output> {
        if (state != RecorderState.recording) return emptyList()
        state = RecorderState.paused
        pauseStartT = t
        lastT = t
        return emptyList()
    }

    fun resume(t: Long): List<Output> {
        if (state != RecorderState.paused) return emptyList()
        val ps = pauseStartT ?: t
        pausedTotalMs += (t - ps).coerceAtLeast(0)
        pauseStartT = null
        state = RecorderState.recording
        lastT = t
        return emptyList()
    }

    fun stop(t: Long): List<Output> {
        if (state == RecorderState.idle || state == RecorderState.finalising) return emptyList()
        if (state == RecorderState.paused) resume(t)
        state = RecorderState.finalising
        phase = Phase.none
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
        lastAutoLapT?.let { if (t - it < config.doubleLapGuardMs) return LapDecision.ignoredDoubleLap to emptyList() }
        lastManualLapT?.let { if (t - it < config.debounceMs) return LapDecision.ignoredDebounce to emptyList() }
        return LapDecision.accepted to applyManualLap(source, t)
    }

    /**
     * The "Start reps" action: ends the untimed warm-up and starts rep 1 (plan §6). Journaled as
     * a button lap so the file is what a first LAP would have written; a no-op anywhere else
     * (a press mid-rep is never a lap, so a manual LAP cannot be confused with starting).
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
        out.add(Output.Lap(lapCount++, t, source))
        val realigns = structured && source != LapSource.volumeKey
        if (realigns) {
            when (phase) {
                Phase.warmup -> out.addAll(enterStep(t, 0))
                Phase.work, Phase.recovery -> out.addAll(advance(t))
                Phase.cooldown, Phase.none -> Unit
            }
        }
        return out
    }

    /** Advance the clock: emits due cues and the auto-lap at phase end. */
    fun tick(t: Long): List<Output> {
        lastT = t
        if (state != RecorderState.recording || phaseDurationMs == null) return emptyList()
        val out = ArrayList<Output>()
        var guard = 0
        while (phaseDurationMs != null && guard++ < 64) {
            val dur = phaseDurationMs!!
            val phaseElapsed = activeAt(t) - phaseStartActive
            val cue = pendingCues.firstOrNull() ?: break
            if (phaseElapsed < cue.atMs) break
            pendingCues.removeFirst()
            if (cue.kind == CueKind.phaseEnd) {
                // Fire exactly at the boundary so the lap time is the step time, not tick jitter.
                val boundaryT = t - (phaseElapsed - dur)
                out.add(Output.Cue(boundaryT, CueKind.phaseEnd))
                out.addAll(endTimedPhase(boundaryT, auto = true, cueAlreadyEmitted = true))
            } else {
                out.add(Output.Cue(t, cue.kind))
            }
        }
        return out
    }

    fun status(t: Long): Status {
        val remaining = phaseDurationMs?.let { (it - (activeAt(t) - phaseStartActive)).coerceAtLeast(0) } ?: 0L
        return Status(
            state = state,
            elapsedMs = if (state == RecorderState.idle) 0 else elapsedAt(t),
            activeMs = if (state == RecorderState.idle) 0 else activeAt(t),
            lapIndex = lapCount,
            phase = phase,
            repIndex = repIndex,
            phaseRemainingMs = remaining,
            stepIndex = stepIndex,
            stepRemainingMs = if (stepIndex != null) remaining else null,
            stepRemainingM = null,
        )
    }

    private fun endTimedPhase(t: Long, auto: Boolean, cueAlreadyEmitted: Boolean = false): List<Output> {
        if (phaseDurationMs == null) return emptyList()
        val out = ArrayList<Output>()
        if (auto) {
            lastAutoLapT = t
            out.add(Output.Lap(lapCount++, t, LapSource.auto))
        }
        out.addAll(advance(t))
        return out
    }

    /**
     * Move from the current step to the next one. The spec has no recovery after the last rep
     * (founder field test 25-Sep), so the last work step goes straight to cool-down; a 0 s
     * recovery is skipped (no phase, no lap).
     */
    private fun advance(t: Long): List<Output> {
        val steps = spec?.steps ?: return emptyList()
        val from = stepIndex ?: return emptyList()
        var next = from + 1
        while (next < steps.size && steps[next].durationMs == 0L) next++
        return if (next < steps.size) enterStep(t, next) else enterCooldown(t)
    }

    private fun enterStep(t: Long, index: Int): List<Output> {
        val step = spec!!.steps[index]
        phase = when (step.kind) {
            StepKind.work -> Phase.work
            StepKind.recovery -> Phase.recovery
        }
        repIndex = step.rep
        stepIndex = index
        phaseStartActive = activeAt(t)
        val dur = step.durationMs!! // I1: time steps only (see [unsupported])
        phaseDurationMs = dur
        pendingCues = ArrayDeque(CueScheduler.forPhase(dur))
        // The `start` cue is due at 0 — emit it now rather than on the next tick.
        pendingCues.removeFirst()
        return listOf(Output.PhaseChanged(t, phase, repIndex, dur), Output.Cue(t, CueKind.start))
    }

    private fun enterCooldown(t: Long): List<Output> {
        phase = Phase.cooldown
        stepIndex = null
        phaseStartActive = activeAt(t)
        phaseDurationMs = null
        pendingCues = ArrayDeque()
        return listOf(Output.PhaseChanged(t, phase, repIndex, null))
    }

    companion object {
        /**
         * Why this core cannot run [spec] in [mode], or null when it can. Invalid specs fail
         * here too. I1 runs uniform-or-not time steps with an open warm-up/cool-down and the
         * standard cue profile; distance and equal-time steps, fixed warm-up/cool-down, lap
         * lockout and the short/Cooper cue profiles arrive with I2.
         */
        fun unsupported(mode: RunMode, spec: SessionSpec?): String? {
            spec?.problems()?.takeIf { it.isNotEmpty() }?.let { return "invalid session: ${it.joinToString("; ")}" }
            return when (mode) {
                RunMode.intervals -> when {
                    spec == null -> null // a by-feel 4x4 from an old journal; new runs are refused by the shell
                    spec.steps.isEmpty() -> "intervals needs steps"
                    spec.steps.any { it.target != TargetKind.time } -> "distance and equal-time steps are not supported yet"
                    spec.warmupSeconds != null || spec.cooldownSeconds != null -> "a fixed warm-up or cool-down is not supported yet"
                    spec.lapLockout -> "lap lockout is not supported yet"
                    spec.cueProfile != CueProfile.standard -> "cue profile ${spec.cueProfile.name} is not supported yet"
                    else -> null
                }
                RunMode.laps -> if (spec == null || (spec.isFartlek && spec.steps.isEmpty())) null else "laps takes no session but a fartlek"
                RunMode.free -> if (spec == null) null else "free takes no session"
                RunMode.cooper -> if (spec?.templateId == SessionSpec.COOPER_ID) null else "cooper needs the Cooper session"
            }
        }

        /**
         * Rebuild the machine from a replayed journal after a kill (plan §3: step phase rebuilt
         * from the lap lines; W12). [nowT] is the device time at which the `gap` line was
         * written, i.e. run time [Replay.endT] maps to device time [nowT]. Cues already spoken
         * before the kill are not re-spoken; the machine resumes in the paused state if the
         * journal ended paused, else recording.
         */
        fun restore(replay: Replay, nowT: Long, config: Config? = null): RecorderCore {
            val h = replay.header
            val core = if (config != null) RecorderCore(h.mode, h.session, config) else RecorderCore(h.mode, h.session)
            val base = nowT - replay.endT // deviceT = runT + base
            core.start(base)
            for (e in replay.events) {
                val t = e.t + base
                when (e) {
                    is RunEvent.Lap -> {
                        // Replay bypasses every gate and guard: whatever was journaled did happen.
                        if (core.state == RecorderState.paused) continue
                        if (e.source == LapSource.auto) core.endTimedPhase(t, auto = true) else core.applyManualLap(e.source, t)
                    }
                    is RunEvent.Pause -> core.pause(t)
                    is RunEvent.Resume -> core.resume(t)
                    is RunEvent.Gap -> {
                        // The run was dark from e.t to e.endT; phase timers must not count it.
                        // If it was already paused, the open pause covers the span.
                        if (core.state != RecorderState.paused) core.pausedTotalMs += e.endT - e.t
                    }
                    is RunEvent.Sample, is RunEvent.Cue, is RunEvent.HrLink -> Unit
                }
            }
            // Cues whose time has passed were spoken (or lost with the process); do not repeat.
            val phaseElapsed = core.activeAt(nowT) - core.phaseStartActive
            while (core.phaseDurationMs != null) {
                val c = core.pendingCues.firstOrNull() ?: break
                if (c.kind == CueKind.phaseEnd || c.atMs > phaseElapsed) break
                core.pendingCues.removeFirst()
            }
            core.lastT = nowT
            return core
        }
    }
}
