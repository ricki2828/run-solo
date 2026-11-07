package app.runsolo.core.record

import app.runsolo.core.journal.TreadmillMarkPoint

/**
 * The treadmill markers standing, and the one rule for taking a new one, shared by Android's
 * `RecordingSession` and iOS's `LiveRecorder`. A mark is taken only when the recorder is running
 * (a paused one would carry the previous mark's moving time: a 0 ms split), the distance is past
 * the last mark and the moving time is later than the last mark's.
 */
class TreadmillMarks(restored: List<TreadmillMarkPoint> = emptyList()) {
    private val marks = ArrayList(restored)

    val points: List<TreadmillMarkPoint> get() = marks

    /** Flat `[movingMs, metres, ...]`, the shape the platform channel carries. */
    fun flat(): List<Double> = marks.flatMap { listOf(it.activeMs.toDouble(), it.distanceM) }

    /** Whether a mark at [metres] / [activeMs] would be taken now. */
    fun accepts(metres: Double, activeMs: Long, paused: Boolean): Boolean {
        if (paused || !metres.isFinite() || metres <= 0 || metres > 500_000) return false
        val last = marks.lastOrNull() ?: return true
        return metres > last.distanceM && activeMs > last.activeMs
    }

    fun add(metres: Double, activeMs: Long) { marks.add(TreadmillMarkPoint(activeMs, metres)) }

    /** Takes the latest mark back; false when there is none. */
    fun undo(): Boolean {
        if (marks.isEmpty()) return false
        marks.removeAt(marks.lastIndex)
        return true
    }
}
