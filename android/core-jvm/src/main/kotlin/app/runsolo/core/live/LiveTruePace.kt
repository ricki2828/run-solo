package app.runsolo.core.live

import app.runsolo.core.elevation.GradeWindow
import kotlin.math.abs
import kotlin.math.pow

/**
 * The live TRUE PACE the run screen shows ("TRUE 4:46"), computed natively so voice coaching judges the
 * same number against a True Pace target. A line-for-line mirror of the Dart `RunTruePace.live` chain:
 * pace on the live grade (Minetti 2002 cost, `Gap.ratio`), the hills factor clamped as
 * `TruePace.clampGrade`, and the start-of-run heat slowdown ramped in over the distance
 * (`HeatModel.distanceRamp`). Pinned with the engine by `fixtures/phase4/live_true_pace_vectors.json`.
 */
object LiveTruePace {
    private const val FLAT_COST = 3.6
    private const val MIN_GRADE = 0.75
    private const val MAX_GRADE = 1.15
    private const val GRADE_DEADBAND = 0.005
    private const val MIN_HEAT = 0.90

    /** Metabolic cost of a metre at [grade] (rise over run), J/(kg m): `Gap.cost`. */
    fun cost(grade: Double): Double {
        val i = grade.coerceIn(-GradeWindow.MAX_GRADE, GradeWindow.MAX_GRADE)
        return 155.4 * i.pow(5) - 30.4 * i.pow(4) - 43.3 * i.pow(3) + 46.3 * i * i + 19.5 * i + FLAT_COST
    }

    /** How many flat metres a metre at [grade] is worth: `Gap.ratio`. */
    fun ratio(grade: Double): Double = cost(grade) / FLAT_COST

    /** `HeatModel.distanceRamp`: the heat share at [metres] into a run (smoothstep, 3 km to 9 km). */
    fun heatRamp(metres: Double): Double {
        val t = ((metres - 3000) / 6000).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /**
     * [paceSecPerKm] on [gradeFraction] (0.05 = 5% uphill; null before the first grade), with the run's
     * heat [slowdown] fraction (null = no usable weather) at [distanceM]. Null without a pace.
     */
    fun apply(paceSecPerKm: Double?, gradeFraction: Double?, slowdown: Double?, distanceM: Double): Double? {
        paceSecPerKm ?: return null
        val raw = gradeFraction?.let { 1 / ratio(it) }
        val grade = when {
            raw == null -> 1.0
            abs(raw - 1) < GRADE_DEADBAND -> 1.0
            else -> raw.coerceIn(MIN_GRADE, MAX_GRADE)
        }
        val heat = if (slowdown == null) 1.0 else (1 - slowdown * heatRamp(distanceM)).coerceIn(MIN_HEAT, 1.0)
        return paceSecPerKm * grade * heat
    }
}
