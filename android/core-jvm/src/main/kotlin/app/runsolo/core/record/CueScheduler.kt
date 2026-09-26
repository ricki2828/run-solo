package app.runsolo.core.record

import app.runsolo.core.model.CueKind

/**
 * Cue points for one timed or measured phase (plan §3/§6, Phase 3 §3.6). [CuePoint.at] is
 * active milliseconds into the phase for a time phase and metres into it for a distance step.
 * Every list starts with `start` (except the warm-up/cool-down edges) and ends with `phaseEnd`,
 * which also fires the auto-lap.
 */
object CueScheduler {
    data class CuePoint(val kind: CueKind, val at: Long)

    /** Minutes of a 12-minute Cooper test that speak the projected score instead of the minute (Phase 4 §3.3: every minute 2–11). */
    val COOPER_PROJECTION_MINUTES = (2..11).toList()

    /** Standard profile, time step: `start` at 0, `halfway`, `thirtySeconds` at duration − 30 s, `phaseEnd`. For 4:00 that is 0:00, 2:00, 3:30, 4:00; the −30 s cue is dropped when it would not come after halfway (steps ≤ 60 s). */
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

    /** Short profile (steps under a minute, 30/30s): `start`, a 3-2-1 `countdown`, `phaseEnd`. No halfway chatter. */
    fun short(durationMs: Long): List<CuePoint> {
        require(durationMs > 0)
        val points = ArrayList<CuePoint>()
        points.add(CuePoint(CueKind.start, 0))
        if (durationMs > 3_000) points.add(CuePoint(CueKind.countdown, durationMs - 3_000))
        points.add(CuePoint(CueKind.phaseEnd, durationMs))
        return points
    }

    /**
     * Cooper profile (the 12-minute test): `start`, a `minuteMark` at 1:00, the `projection`
     * each minute 2–11 instead of the minute (the core suppresses it while GPS is weak), a
     * 3-2-1 `countdown`, `phaseEnd`.
     */
    fun cooper(durationMs: Long): List<CuePoint> {
        require(durationMs > 0)
        val points = ArrayList<CuePoint>()
        points.add(CuePoint(CueKind.start, 0))
        var m = 1
        while (m * 60_000L < durationMs) {
            points.add(CuePoint(if (m in COOPER_PROJECTION_MINUTES) CueKind.projection else CueKind.minuteMark, m * 60_000L))
            m++
        }
        if (durationMs > 3_000) points.add(CuePoint(CueKind.countdown, durationMs - 3_000))
        points.add(CuePoint(CueKind.phaseEnd, durationMs))
        return points.sortedBy { it.at }
    }

    /**
     * Distance step, in metres: `start`, `halfway` for ≥ 800 m, `distanceToGo` 100 m out for
     * ≥ 300 m, a `projection` (finish time) at each whole km of a step ≥ 3 km, `phaseEnd` at the
     * target. Stable order when two land on the same metre (halfway before a km projection).
     */
    fun distance(targetM: Long): List<CuePoint> {
        require(targetM > 0)
        val points = ArrayList<CuePoint>()
        points.add(CuePoint(CueKind.start, 0))
        if (targetM >= 800) points.add(CuePoint(CueKind.halfway, targetM / 2))
        if (targetM >= 3_000) {
            var km = 1_000L
            while (km < targetM) {
                points.add(CuePoint(CueKind.projection, km))
                km += 1_000
            }
        }
        if (targetM >= 300) points.add(CuePoint(CueKind.distanceToGo, targetM - 100))
        points.add(CuePoint(CueKind.phaseEnd, targetM))
        return points.sortedBy { it.at }
    }

    /** A fixed warm-up or cool-down: `thirtySeconds` before the end when it is over a minute, then `phaseEnd`. */
    fun edge(durationMs: Long): List<CuePoint> {
        require(durationMs > 0)
        val points = ArrayList<CuePoint>()
        if (durationMs > 60_000) points.add(CuePoint(CueKind.thirtySeconds, durationMs - 30_000))
        points.add(CuePoint(CueKind.phaseEnd, durationMs))
        return points
    }
}
