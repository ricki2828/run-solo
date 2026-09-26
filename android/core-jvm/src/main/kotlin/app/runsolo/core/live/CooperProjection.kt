package app.runsolo.core.live

import java.util.Locale
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * Cooper 12-minute test projection (Phase 4 §3.3, B1), the Kotlin mirror of the engine's
 * `cooper_projection.dart`, both tested against `packages/run_engine/test/fixtures/cooper/
 * cooper_projection.json`. `F(t)` is the fraction of the final 12-minute distance typically
 * covered by minute `t`; mid-test the projected distance is `d(t) / F(t)` (replaces the Phase 3
 * linear `d / elapsed × 720`, which over-projects after a fast start).
 */
object CooperProjection {
    const val TEST_SECONDS = 720
    const val MINUTES = 12

    /** No projection before this: one minute of data says little. */
    const val FIRST_PROJECTION_SECONDS = 60

    /** Cooper 1968. An estimate, never a measurement. */
    fun vo2(metres: Double): Double = (metres - 504.9) / 44.73

    /** Projected 12-minute distance at [elapsedSeconds] with [distanceM] covered; null before a minute or with no distance. */
    fun project(curve: CooperCurve, elapsedSeconds: Double, distanceM: Double): Double? {
        if (elapsedSeconds < FIRST_PROJECTION_SECONDS || distanceM <= 0) return null
        return distanceM / curve.fractionAt(elapsedSeconds / 60)
    }

    /** "5 minutes. Heading for about 2,740. VO2 about 50." Rounded to 10 m and a whole VO2 here only. */
    fun cue(minute: Int, projectedM: Double): String {
        val m = if (minute == 1) "1 minute" else "$minute minutes"
        val rounded = (projectedM / 10).roundToLong() * 10
        return "$m. Heading for about ${String.format(Locale.US, "%,d", rounded)}. VO2 about ${vo2(projectedM).roundToInt()}."
    }
}

/** Cumulative fraction of the 12-minute distance at minutes 1..12 (`F(12) = 1`, strictly increasing). */
class CooperCurve private constructor(val fractions: List<Double>) {
    /** `F` at any time in minutes, linear between whole minutes with `F(0) = 0`; clamped to 0–12. */
    fun fractionAt(minute: Double): Double {
        if (minute <= 0) return 0.0
        if (minute >= CooperProjection.MINUTES) return 1.0
        val i = floor(minute).toInt()
        val lo = if (i == 0) 0.0 else fractions[i - 1]
        val hi = fractions[i]
        return lo + (hi - lo) * (minute - i)
    }

    companion object {
        /**
         * Tests 1 and 2 (plan §3.3): an asymmetric U, minute 1 at 1.05 × mean speed, minutes 2–11
         * easing linearly 0.99 → 0.97, minute 12 at 1.03, normalised so `F(12) = 1`. Placeholder
         * magnitudes (needs verification); the engine sends the personal curve from test 3 on.
         */
        val DEFAULT: CooperCurve = fromMinuteSpeeds(listOf(1.05) + (0 until 10).map { 0.99 - 0.02 * it / 9 } + listOf(1.03))

        /** From 12 relative per-minute speeds (any scale). */
        fun fromMinuteSpeeds(speeds: List<Double>): CooperCurve {
            require(speeds.size == CooperProjection.MINUTES) { "a Cooper curve needs 12 minutes" }
            val total = speeds.sum()
            var acc = 0.0
            val f = speeds.map { acc += it; acc / total }.toMutableList()
            f[CooperProjection.MINUTES - 1] = 1.0
            return CooperCurve(f)
        }

        /** One test's curve from its 12 cumulative minute distances; null unless they strictly increase from a positive first minute. */
        fun fromMinuteDistances(m: List<Double>): CooperCurve? {
            if (m.size != CooperProjection.MINUTES || m.first() <= 0) return null
            for (i in 1 until m.size) if (!(m[i] > m[i - 1])) return null
            val total = m.last()
            return CooperCurve((0 until m.size - 1).map { m[it] / total } + 1.0)
        }

        /** Point-wise mean of the runner's cumulative fraction curves. */
        fun mean(curves: List<CooperCurve>): CooperCurve {
            require(curves.isNotEmpty()) { "no curves" }
            return CooperCurve((0 until CooperProjection.MINUTES).map { i -> curves.sumOf { it.fractions[i] } / curves.size })
        }

        /** The LiveContext `cooperCurve`; null (use [DEFAULT]) unless 12 strictly increasing points ending at 1. */
        fun fromFractions(f: List<Double>?): CooperCurve? {
            if (f == null || f.size != CooperProjection.MINUTES || f.any { it.isNaN() } || f.first() <= 0 || kotlin.math.abs(f.last() - 1) > 1e-9) return null
            for (i in 1 until f.size) if (!(f[i] > f[i - 1])) return null
            return CooperCurve(f.toList())
        }
    }
}
