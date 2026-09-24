package app.runsolo.core.record

import app.runsolo.core.journal.Replay
import app.runsolo.core.journal.RunEvent
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Phase
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode

/**
 * Lap state machine + preset phase timer + cue scheduler, device-independent (plan §3, §6).
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
 *  - Volume-key laps: only when [Config.volumeKeyLaps] (default: Free mode only). In preset
 *    mode they are recorded but never re-align the phase (pocket-bump guard, W8).
 *  - Double-lap guard: a manual press within [Config.doubleLapGuardMs] of an auto-lap is
 *    ignored; any manual press within [Config.debounceMs] of the previous manual lap is ignored.
 *  - Laps while paused are ignored.
 */
class RecorderCore(
    val mode: RunMode,
    val preset: Preset?,
    private val config: Config = Config(volumeKeyLaps = mode == RunMode.free),
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

    enum class LapDecision { accepted, ignoredDoubleLap, ignoredDebounce, ignoredVolumeKeyDisabled, ignoredPaused, ignoredIdle }

    data class Status(
        val state: RecorderState,
        val elapsedMs: Long,
        val activeMs: Long,
        val lapIndex: Int,
        val phase: Phase,
        val repIndex: Int,
        val phaseRemainingMs: Long,
    )

    init {
        require(mode == RunMode.free || preset != null) { "4x4 mode needs a preset" }
    }

    var state: RecorderState = RecorderState.idle
        private set
    var lapCount: Int = 0
        private set
    var phase: Phase = Phase.none
        private set

    /** 1-based rep number during work/recovery; 0 in warmup/none, preset.reps after the last recovery. */
    var repIndex: Int = 0
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
        if (preset != null) {
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
        if (state == RecorderState.paused) return LapDecision.ignoredPaused to emptyList()
        if (source == LapSource.auto) {
            // Only restore() feeds auto laps; live auto-laps come from the cue scheduler in tick().
            return LapDecision.accepted to endTimedPhase(t, auto = true)
        }
        if (source == LapSource.volumeKey && !config.volumeKeyLaps) return LapDecision.ignoredVolumeKeyDisabled to emptyList()
        lastAutoLapT?.let { if (t - it < config.doubleLapGuardMs) return LapDecision.ignoredDoubleLap to emptyList() }
        lastManualLapT?.let { if (t - it < config.debounceMs) return LapDecision.ignoredDebounce to emptyList() }
        lastManualLapT = t
        val out = ArrayList<Output>()
        out.add(Output.Lap(lapCount++, t, source))
        val realigns = preset != null && source != LapSource.volumeKey
        if (realigns) {
            when (phase) {
                Phase.warmup -> out.addAll(enterPhase(t, Phase.work, 1))
                Phase.work, Phase.recovery -> out.addAll(advance(t))
                Phase.cooldown, Phase.none -> Unit
            }
        }
        return LapDecision.accepted to out
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
                // Fire exactly at the boundary so the lap time is the preset time, not tick jitter.
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

    /** Move from the current timed phase to the next one. */
    private fun advance(t: Long): List<Output> {
        val p = preset ?: return emptyList()
        return when (phase) {
            Phase.work -> enterPhase(t, Phase.recovery, repIndex)
            Phase.recovery -> if (repIndex >= p.reps) enterPhase(t, Phase.cooldown, repIndex) else enterPhase(t, Phase.work, repIndex + 1)
            else -> emptyList()
        }
    }

    private fun enterPhase(t: Long, next: Phase, rep: Int): List<Output> {
        val p = preset!!
        phase = next
        repIndex = rep
        phaseStartActive = activeAt(t)
        val dur = when (next) {
            Phase.work -> p.workMs
            Phase.recovery -> p.recoveryMs
            else -> null
        }
        phaseDurationMs = dur
        pendingCues = if (dur != null) ArrayDeque(CueScheduler.forPhase(dur)) else ArrayDeque()
        val out = ArrayList<Output>()
        out.add(Output.PhaseChanged(t, next, rep, dur))
        if (dur != null) {
            // The `start` cue is due at 0 — emit it now rather than on the next tick.
            pendingCues.removeFirst()
            out.add(Output.Cue(t, CueKind.start))
        }
        return out
    }

    companion object {
        /**
         * Rebuild the machine from a replayed journal after a kill (plan §3: preset phase rebuilt
         * from the lap lines; W12). [nowT] is the device time at which the `gap` line was
         * written, i.e. run time [Replay.endT] maps to device time [nowT]. Cues already spoken
         * before the kill are not re-spoken; the machine resumes in the paused state if the
         * journal ended paused, else recording.
         */
        fun restore(replay: Replay, nowT: Long, config: Config? = null): RecorderCore {
            val h = replay.header
            val core = if (config != null) RecorderCore(h.mode, h.preset, config) else RecorderCore(h.mode, h.preset)
            val base = nowT - replay.endT // deviceT = runT + base
            core.start(base)
            for (e in replay.events) {
                val t = e.t + base
                when (e) {
                    is RunEvent.Lap -> {
                        // Replay bypasses the guards: whatever was journaled did happen.
                        core.lastAutoLapT = null
                        core.lastManualLapT = null
                        core.lap(e.source, t)
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
