package app.runsolo.core.live

import app.runsolo.core.json.Json
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The shared CO1 table (computed independently in Python): Kotlin must match the engine to the digit. */
class CooperProjectionTest {
    private val fx: Map<String, Any?> = Json.parseObject(File("../../packages/run_engine/test/fixtures/cooper/cooper_projection.json").readText())

    @Suppress("UNCHECKED_CAST")
    private fun doubles(v: Any?) = (v as List<Any?>).map { (it as Number).toDouble() }

    @Test
    fun `default curve from the default speeds, plan check values`() {
        val speeds = doubles(fx["default_speeds"])
        val fromSpeeds = CooperCurve.fromMinuteSpeeds(speeds)
        val expected = doubles(fx["default_curve"])
        for (i in 0 until 12) {
            assertEquals(expected[i], CooperCurve.DEFAULT.fractions[i], 1e-12, "F(${i + 1})")
            assertEquals(expected[i], fromSpeeds.fractions[i], 1e-12, "F(${i + 1}) from the table's speeds")
        }
        assertEquals(0.0884, CooperCurve.DEFAULT.fractions[0], 5e-5)
        assertEquals(0.5032, CooperCurve.DEFAULT.fractions[5], 5e-5)
        assertEquals(0.9133, CooperCurve.DEFAULT.fractions[10], 5e-5)
        assertEquals(51.31008271853342, CooperProjection.vo2(2800.0), 1e-9)
    }

    @Test
    fun `default projections and their cues`() {
        @Suppress("UNCHECKED_CAST")
        for (p in fx["default_projections"] as List<Map<String, Any?>>) {
            val elapsed = (p["elapsed_s"] as Number).toDouble()
            val d = (p["distance_m"] as Number).toDouble()
            val got = CooperProjection.project(CooperCurve.DEFAULT, elapsed, d)
            if (p.containsKey("projection") && p["projection"] == null) {
                assertNull(got, "no projection at $elapsed s")
                continue
            }
            assertEquals((p["projected_m"] as Number).toDouble(), got!!, 1e-3, "projection at $elapsed s")
            assertEquals((p["vo2"] as Number).toDouble(), CooperProjection.vo2(got), 1e-4, "vo2 at $elapsed s")
            (p["cue"] as String?)?.let { assertEquals(it, CooperProjection.cue((elapsed / 60).toInt(), got)) }
        }
    }

    @Test
    fun `personal curve is the mean of the last three tests`() {
        val personal = fx["personal"] as Map<*, *>
        @Suppress("UNCHECKED_CAST")
        val tests = (personal["tests_minute_m"] as List<List<Number>>).map { t -> t.map { it.toDouble() } }
        val curve = CooperCurve.mean(tests.takeLast(3).map { CooperCurve.fromMinuteDistances(it)!! })
        val expected = doubles(personal["curve_from_last3"])
        for (i in 0 until 12) assertEquals(expected[i], curve.fractions[i], 1e-12, "F_you(${i + 1})")
        val proj = personal["projection"] as Map<*, *>
        val got = CooperProjection.project(curve, (proj["elapsed_s"] as Number).toDouble(), (proj["distance_m"] as Number).toDouble())!!
        assertEquals((proj["projected_m"] as Number).toDouble(), got, 1e-6)
        // The LiveContext carries the fractions; they round-trip.
        assertEquals(curve.fractions, CooperCurve.fromFractions(curve.fractions)!!.fractions)
        assertNull(CooperCurve.fromFractions(curve.fractions.reversed()))
        assertNull(CooperCurve.fromMinuteDistances(listOf(0.0) + tests[0].drop(1)))
    }
}
