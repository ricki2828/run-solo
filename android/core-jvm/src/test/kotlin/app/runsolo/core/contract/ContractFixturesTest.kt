package app.runsolo.core.contract

import app.runsolo.core.json.Json
import app.runsolo.core.json.list
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ContractFixturesTest {
    private fun fixture(name: String): Map<String, Any?> = Json.parseObject(ContractFixtures.all().getValue(name))
    private fun laps(m: Map<String, Any?>) = m.list("laps").map { it as Map<*, *> }
    private fun samples(m: Map<String, Any?>) = m.list("samples").map { it as List<*> }

    @Test
    fun `checked-in contract fixtures match the generator byte for byte`() {
        for ((name, json) in ContractFixtures.all()) {
            val file = File(ContractFixtures.DIR, "$name.json")
            assertTrue(file.exists(), "missing ${file.path}; regenerate with ContractFixturesKt.main")
            assertEquals(json + "\n", file.readText(), "$name drifted; regenerate and copy to run_engine")
        }
    }

    @Test
    fun `4x4 preset fixture - 10 laps, 8 auto on the exact boundaries, HR on every sample, fixes throughout`() {
        val m = fixture("four_by_four_preset_auto_hr")
        val laps = laps(m)
        assertEquals(10, laps.size)
        assertEquals(8, laps.count { it["kind"] == "auto" })
        assertEquals("manual", laps.first()["kind"])
        assertEquals("manual", laps.last()["kind"])
        assertEquals(60_000L, laps[0]["t1"])
        assertEquals(300_000L, laps[1]["t1"])
        assertEquals(480_000L, laps[2]["t1"])
        assertEquals(240.0 * 4.2, (laps[1]["d1"] as Number).toDouble() - (laps[1]["d0"] as Number).toDouble(), 3.0)
        val s = samples(m)
        assertEquals(60 + 4 * 420 + 60, s.size) // recording starts at second 1; the last tick is the stop second
        assertTrue(s.all { it[7] != null && it[1] != null })
        assertTrue(s.zipWithNext().all { (a, b) -> (b[0] as Long) > (a[0] as Long) && (b[6] as Number).toDouble() >= (a[6] as Number).toDouble() })
        assertEquals(mapOf("reps" to 4L, "workSeconds" to 240L, "recoverySeconds" to 180L), m["preset"])
        assertEquals("2025-09-24T00:00:00Z", m["start"])
        assertEquals("2025-09-24T00:30:00Z", m["end"])
    }

    @Test
    fun `treadmill fixture - HR, no fixes, zero distance, 2 laps`() {
        val m = fixture("treadmill_no_fix_hr")
        val s = samples(m)
        assertEquals(600, s.size)
        assertTrue(s.all { it[1] == null && it[2] == null && it[4] == null })
        assertEquals(listOf(1000L, null, null, null, null, null, 0L, 120L), s[0])
        assertEquals(150L, s.last()[7])
        assertEquals(2, laps(m).size)
        assertEquals(0L, laps(m).last()["d1"])
    }

    @Test
    fun `dropout fixture - HR through 46 no-fix ticks, distance repeats then catches up`() {
        val m = fixture("gps_dropout_hr")
        val s = samples(m)
        assertEquals(360, s.size)
        val noFix = s.filter { it[1] == null }
        assertEquals(46, noFix.size)
        assertTrue(s.all { it[7] == 150L })
        assertTrue(noFix.all { it[6] == noFix.first()[6] })
        assertEquals(359 * 3.0, (s.last()[6] as Number).toDouble(), 4.0) // anchored at second 1
    }

    @Test
    fun `pause fixture - one 20 s pause, 3 laps, no HR`() {
        val m = fixture("free_run_pause_manual_laps")
        assertEquals(listOf(listOf(270_000L, 290_000L)), m["pauses"])
        assertEquals(listOf(0L, 180_000L, 360_000L), laps(m).map { it["t0"] })
        assertEquals(540_000L, laps(m).last()["t1"])
        assertNull(samples(m).first()[7])
    }
}
