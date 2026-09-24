package app.runsolo.core.record

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.Preset

/**
 * Cue points for one timed phase, derived from the preset (plan §3/§6): `start` at 0,
 * `halfway`, `thirtySeconds` at duration − 30 s, `phaseEnd` at the duration (which also fires
 * the auto-lap). For 4:00 that is 0:00, 2:00, 3:30, 4:00; for 3:00 it is 0:00, 1:30, 2:30, 3:00.
 * The −30 s cue is dropped when it would not come after the halfway cue (phases ≤ 60 s).
 */
object CueScheduler {
    data class CuePoint(val kind: CueKind, val atMs: Long)

    fun forPhase(durationMs: Long): List<CuePoint> {
        require(durationMs > 0)
        val points = ArrayList<CuePoint>()
        points.add(CuePoint(CueKind.start, 0))
        val half = durationMs / 2
        points.add(CuePoint(CueKind.halfway, half))
        val thirty = durationMs - 30_000
        if (thirty > half) points.add(CuePoint(CueKind.thirtySeconds, thirty))
        points.add(CuePoint(CueKind.phaseEnd, durationMs))
        return points
    }

    fun forWork(preset: Preset) = forPhase(preset.workMs)
    fun forRecovery(preset: Preset) = forPhase(preset.recoveryMs)
}
