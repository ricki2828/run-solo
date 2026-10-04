package app.runsolo.core.gps

import app.runsolo.core.platform.atan2
import app.runsolo.core.platform.cos
import app.runsolo.core.platform.sin
import app.runsolo.core.platform.toRadians
import kotlin.math.sqrt

object Geo {
    const val EARTH_RADIUS_M = 6_371_008.8

    /** Great-circle distance in metres. */
    fun haversineM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val p1 = toRadians(lat1)
        val p2 = toRadians(lat2)
        val dp = p2 - p1
        val dl = toRadians(lon2 - lon1)
        val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * EARTH_RADIUS_M * atan2(sqrt(a), sqrt(1 - a))
    }
}
