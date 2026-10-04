package app.runsolo.core.gps

/**
 * Rolling "live" pace for the tick stream (plan §2: labelled live; differs from the verdict's
 * trimmed pace). Pace = seconds per km over the trailing [windowMs] of accepted points; null
 * until at least [minDistanceM] has been covered inside the window.
 */
class LivePace(private val windowMs: Long = 15_000, private val minDistanceM: Double = 5.0) {
    private data class P(val t: Long, val d: Double)

    private val window = ArrayDeque<P>()

    fun update(t: Long, totalM: Double): Double? {
        window.addLast(P(t, totalM))
        while (window.size > 1 && t - window.first().t > windowMs) window.removeFirst()
        val dd = totalM - window.first().d
        val dt = t - window.first().t
        if (dd < minDistanceM || dt <= 0) return null
        return (dt / 1000.0) / (dd / 1000.0)
    }

    fun reset() = window.clear()
}
