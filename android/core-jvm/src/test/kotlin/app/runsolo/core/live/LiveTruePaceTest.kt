package app.runsolo.core.live

import app.runsolo.core.json.Json
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The live True Pace the coach judges: the same number the run screen shows (shared vectors with Dart). */
class LiveTruePaceTest {
    @Test
    fun `shared vectors - agrees with the engine on every case`() {
        val fx = Json.parseObject(File("../../packages/run_engine/test/fixtures/phase4/live_true_pace_vectors.json").readText())

        @Suppress("UNCHECKED_CAST")
        val cases = fx["cases"] as List<Map<String, Any?>>
        assertEquals(16, cases.size)
        for (c in cases) {
            val grade = (c["gradePct"] as? Number)?.let { it.toDouble() / 100 }
            val got = LiveTruePace.apply((c["paceSecPerKm"] as? Number)?.toDouble(), grade, (c["slowdown"] as? Number)?.toDouble(), (c["distanceM"] as Number).toDouble())
            val want = (c["expected"] as? Number)?.toDouble()
            if (want == null) assertNull(got, "$c") else assertTrue(got != null && kotlin.math.abs(got - want) < 1e-4, "$c: got $got want $want")
        }
    }

    @Test
    fun `a climb makes true pace faster than the clock, a descent slower, flat is the clock`() {
        assertEquals(300.0, LiveTruePace.apply(300.0, 0.0, null, 1000.0))
        assertTrue(LiveTruePace.apply(300.0, 0.05, null, 1000.0)!! < 300.0)
        assertTrue(LiveTruePace.apply(300.0, -0.05, null, 1000.0)!! > 300.0)
    }
}
