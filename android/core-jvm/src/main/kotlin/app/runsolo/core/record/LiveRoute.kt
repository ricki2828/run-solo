package app.runsolo.core.record

import kotlin.math.cos
import kotlin.math.hypot

/**
 * The live map's simplified route: accepted fixes only (accuracy within [maxAccuracyM]), thinned to a
 * point every [minStepM] metres so a long run stays small. Read-only view of what the recorder already
 * samples; it never asks for a fix and nothing in the recording reads it back.
 */
class LiveRoute(private val minStepM: Double = 4.0, private val maxAccuracyM: Double = 25.0) {
    private val flat = ArrayList<Double>()

    val size: Int get() = flat.size / 2

    /** True when the fix became a route point. */
    fun offer(lat: Double, lon: Double, accuracyM: Double): Boolean {
        if (accuracyM > maxAccuracyM) return false
        if (flat.isNotEmpty()) {
            val pLat = flat[flat.size - 2]
            val pLon = flat[flat.size - 1]
            val dy = (lat - pLat) * METRES_PER_DEG
            val dx = (lon - pLon) * METRES_PER_DEG * cos(Math.toRadians(pLat))
            if (hypot(dx, dy) < minStepM) return false
        }
        flat.add(lat)
        flat.add(lon)
        return true
    }

    /** Flat `[lat, lon, ...]` from point [fromIndex]; empty past the end. */
    fun since(fromIndex: Int): List<Double> {
        val from = fromIndex.coerceAtLeast(0)
        return if (from >= size) emptyList() else ArrayList(flat.subList(from * 2, flat.size))
    }

    private companion object {
        const val METRES_PER_DEG = 111_320.0
    }
}
