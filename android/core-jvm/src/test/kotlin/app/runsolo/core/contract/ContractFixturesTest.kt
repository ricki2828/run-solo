package app.runsolo.core.contract

import app.runsolo.core.json.Json
import app.runsolo.core.json.list
import app.runsolo.core.model.SessionSpec
import java.io.File
import kotlin.math.abs
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
    fun `schema-1 fixtures are frozen - four files, schema 1, free is the lap-capable mode of the day`() {
        val files = File(ContractFixtures.SCHEMA1_DIR).listFiles { f -> f.name.endsWith(".json") }!!.sortedBy { it.name }
        assertEquals(
            listOf("four_by_four_preset_auto_hr", "free_run_pause_manual_laps", "gps_dropout_hr", "treadmill_no_fix_hr"),
            files.map { it.nameWithoutExtension },
        )
        for (f in files) {
            val m = Json.parseObject(f.readText())
            assertEquals(1L, m["schema"], f.name)
            assertTrue(m["mode"] == "fourByFour" || m["mode"] == "free", f.name)
        }
        // The frozen `free` file with manual laps is exactly what schema 2 calls `laps`.
        val v1 = Json.parseObject(File(ContractFixtures.SCHEMA1_DIR, "free_run_pause_manual_laps.json").readText())
        assertEquals("free", v1["mode"])
        assertEquals(3, laps(v1).size)
    }

    @Test
    fun `schema-2 fixtures are frozen - five files, schema 2, fourByFour carries a preset`() {
        val files = File(ContractFixtures.SCHEMA2_DIR).listFiles { f -> f.name.endsWith(".json") }!!.sortedBy { it.name }
        assertEquals(
            listOf("four_by_four_preset_auto_hr", "free_run_no_laps", "gps_dropout_hr", "laps_run_pause_manual_laps", "treadmill_no_fix_hr"),
            files.map { it.nameWithoutExtension },
        )
        for (f in files) {
            val m = Json.parseObject(f.readText())
            assertEquals(2L, m["schema"], f.name)
            assertTrue(m["mode"] in setOf("fourByFour", "laps", "free"), f.name)
            assertEquals(m["mode"] == "fourByFour", m["preset"] != null, f.name)
            assertTrue(!m.containsKey("session"), f.name)
        }
    }

    @Test
    fun `every schema-3 fixture is schema 3 - intervals and cooper carry a session, preset is gone`() {
        for ((name, json) in ContractFixtures.all()) {
            val m = Json.parseObject(json)
            assertEquals(3L, m["schema"], name)
            assertTrue(m["mode"] in setOf("intervals", "laps", "free", "cooper"), "$name mode=${m["mode"]}")
            assertTrue(!m.containsKey("preset"), "$name still has preset")
            assertTrue(m.containsKey("session"), "$name has no session key")
            val session = m["session"] as Map<*, *>?
            when (m["mode"]) {
                "intervals", "cooper" -> assertTrue(session != null, name)
                "free" -> assertNull(session, name)
                "laps" -> assertTrue(session == null || session["templateId"] == "fartlek", name)
            }
            // Canonical key order: ... mode, session, units ...
            val keys = m.keys.toList()
            assertEquals(keys.indexOf("mode") + 1, keys.indexOf("session"), name)
            assertEquals(keys.indexOf("session") + 1, keys.indexOf("units"), name)
            // Every session the writer emits parses back and validates.
            if (session != null) {
                @Suppress("UNCHECKED_CAST")
                val spec = SessionSpec.fromJson(session as Map<String, Any?>)!!
                assertEquals(emptyList(), spec.problems(), name)
                assertEquals(session, Json.parseObject(Json.write(spec.toJson())), "$name session round trip")
            }
        }
    }

    @Test
    fun `free fixture - LAP presses from every source ignored, one lap segment, pause recorded`() {
        val m = fixture("free_run_no_laps")
        assertEquals("free", m["mode"])
        val laps = laps(m)
        assertEquals(1, laps.size)
        assertEquals(0L, laps[0]["t0"])
        assertEquals(480_000L, laps[0]["t1"])
        assertEquals("manual", laps[0]["kind"])
        assertEquals(listOf(listOf(240_000L, 255_000L)), m["pauses"])
        val s = samples(m)
        assertEquals(480, s.size)
        assertTrue(s.all { it[7] != null })
        val dist = (s.last()[6] as Number).toDouble()
        assertTrue(dist in 1380.0..1395.0, "15 s standing still is not distance: $dist") // 465 moving seconds @3 m/s minus re-anchor
    }

    @Test
    fun `4x4 preset fixture - 9 laps, 7 auto on the exact boundaries (no recovery after rep 4), HR on every sample, fixes throughout`() {
        val m = fixture("four_by_four_preset_auto_hr")
        val laps = laps(m)
        assertEquals(9, laps.size)
        assertEquals(7, laps.count { it["kind"] == "auto" })
        assertEquals(60_000L + 4 * 240_000L + 3 * 180_000L, laps[7]["t1"]) // rep 4 ends straight into cool-down
        assertEquals("manual", laps.first()["kind"])
        assertEquals("manual", laps.last()["kind"])
        assertEquals(60_000L, laps[0]["t1"])
        assertEquals(300_000L, laps[1]["t1"])
        assertEquals(480_000L, laps[2]["t1"])
        assertEquals(240.0 * 4.2, (laps[1]["d1"] as Number).toDouble() - (laps[1]["d0"] as Number).toDouble(), 3.0)
        val s = samples(m)
        assertEquals(60 + 4 * 240 + 3 * 180 + 60, s.size) // recording starts at second 1; the last tick is the stop second
        assertTrue(s.all { it[7] != null && it[1] != null })
        assertTrue(s.zipWithNext().all { (a, b) -> (b[0] as Long) > (a[0] as Long) && (b[6] as Number).toDouble() >= (a[6] as Number).toDouble() })
        assertEquals("intervals", m["mode"])
        val session = m["session"] as Map<*, *>
        assertEquals(
            listOf("templateId", "templateVersion", "name", "warmupSeconds", "cooldownSeconds", "lapLockout", "autoStop", "cueProfile", "hrBand", "steps"),
            session.keys.toList(),
        )
        assertEquals("norwegian-4x4", session["templateId"])
        assertEquals(1L, session["templateVersion"])
        assertEquals("Norwegian 4x4", session["name"])
        assertEquals(listOf(0.85, 0.95), session["hrBand"])
        val steps = session["steps"] as List<*>
        assertEquals(7, steps.size)
        assertEquals(mapOf("kind" to "work", "target" to "time", "value" to 240L, "style" to "run", "rep" to 1L), steps[0])
        assertEquals(mapOf("kind" to "recovery", "target" to "time", "value" to 180L, "style" to "jog", "rep" to 1L), steps[1])
        assertEquals(mapOf("kind" to "work", "target" to "time", "value" to 240L, "style" to "run", "rep" to 4L), steps[6])
        assertEquals("2025-09-24T00:00:00Z", m["start"])
        assertEquals("2025-09-24T00:27:00Z", m["end"])
    }

    @Test
    fun `treadmill fixture - HR, no fixes, zero distance, 2 laps`() {
        val m = fixture("treadmill_no_fix_hr")
        assertEquals("laps", m["mode"])
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
        assertEquals("free", m["mode"])
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
        val m = fixture("laps_run_pause_manual_laps")
        assertEquals("laps", m["mode"])
        assertEquals(listOf(listOf(270_000L, 290_000L)), m["pauses"])
        assertEquals(listOf(0L, 180_000L, 360_000L), laps(m).map { it["t0"] })
        assertEquals(540_000L, laps(m).last()["t1"])
        assertNull(samples(m).first()[7])
    }

    @Test
    fun `3-rep 4x4 - 7 laps, 5 auto, no recovery after rep 3`() {
        val m = fixture("four_by_four_3_reps")
        val laps = laps(m)
        assertEquals(7, laps.size)
        assertEquals(5, laps.count { it["kind"] == "auto" })
        assertEquals(listOf(60_000L, 300_000L, 450_000L, 690_000L, 840_000L, 1_080_000L), laps.dropLast(1).map { it["t1"] })
        @Suppress("UNCHECKED_CAST")
        assertEquals(SessionSpec.norwegian4x4(3, 240, 150), SessionSpec.fromJson(m["session"] as Map<String, Any?>))
    }

    @Test
    fun `cooper - the Cooper session, no lap input, 12 minutes`() {
        val m = fixture("cooper_12min")
        assertEquals("cooper", m["mode"])
        assertEquals("cooper", (m["session"] as Map<*, *>)["templateId"])
        assertEquals(true, (m["session"] as Map<*, *>)["lapLockout"])
        assertEquals(1, laps(m).size)
        assertEquals(720, samples(m).size)
    }

    @Test
    fun `fartlek - laps with the steps-empty fartlek session and 5 manual segments`() {
        val m = fixture("fartlek_laps")
        assertEquals("laps", m["mode"])
        assertEquals("fartlek", (m["session"] as Map<*, *>)["templateId"])
        assertEquals(emptyList<Any?>(), (m["session"] as Map<*, *>)["steps"])
        assertEquals(listOf(120_000L, 150_000L, 300_000L, 345_000L, 480_000L), laps(m).map { it["t1"] })
    }

    @Test
    fun `8x400 - recorded by the core - 15 auto laps within a sample of each 400 and 200 m target`() {
        val m = fixture("session_8x400_shape")
        assertEquals("intervals", m["mode"])
        val steps = (m["session"] as Map<*, *>)["steps"] as List<*>
        assertEquals(15, steps.size)
        assertEquals(mapOf("kind" to "recovery", "target" to "distance", "value" to 200L, "style" to "jog", "rep" to 1L), steps[1])
        val laps = laps(m)
        assertEquals(17, laps.size) // warm-up, 15 steps, cool-down
        assertEquals(15, laps.count { it["kind"] == "auto" })
        val dist = laps.subList(1, 16).map { (it["d1"] as Number).toDouble() - (it["d0"] as Number).toDouble() }
        for ((i, d) in dist.withIndex()) {
            val target = if (i % 2 == 0) 400.0 else 200.0
            assertTrue(abs(d - target) <= 4.5, "step $i: $d m for $target (one sample at 4 m/s)")
        }
    }

    @Test
    fun `parkrun - no warm-up, auto-stopped at 5 00 km - one lap from 0, nothing dropped`() {
        val m = fixture("parkrun_5k_autostop")
        val session = m["session"] as Map<*, *>
        assertEquals(true, session["autoStop"])
        assertEquals(0L, session["warmupSeconds"])
        val laps = laps(m)
        assertEquals(1, laps.size, "the step began at Start; the stop ends the one lap: $laps")
        assertEquals(0L, laps[0]["t0"])
        val fiveK = (laps[0]["d1"] as Number).toDouble() - (laps[0]["d0"] as Number).toDouble()
        assertTrue(fiveK in 5_000.0..5_004.5, "5 km lap $fiveK m: at least 5 km, at most one sample over")
        assertTrue((laps[0]["t1"] as Long) in 1_248_000L..1_256_000L, "stopped at ${laps[0]["t1"]} (about 1250 s at 4 m/s, filter distance)")
    }

    @Test
    fun `30-30 short - 19 auto laps of exactly 30 s`() {
        val m = fixture("thirty_thirty_short")
        val laps = laps(m)
        assertEquals(21, laps.size)
        assertEquals(19, laps.count { it["kind"] == "auto" })
        assertTrue(laps.subList(1, 20).all { (it["t1"] as Long) - (it["t0"] as Long) == 30_000L })
    }

    // ---- I5 replay fixtures (one per session kind, closed-loop traces) ----

    private fun dur(l: Map<*, *>) = (l["t1"] as Long) - (l["t0"] as Long)
    private fun dist(l: Map<*, *>) = (l["d1"] as Number).toDouble() - (l["d0"] as Number).toDouble()

    /** Warm-up lap (the press at 60 s), the steps as auto laps, the cool-down ended by the stop. */
    private fun structuredLaps(name: String, steps: Int): List<Map<*, *>> {
        val laps = laps(fixture(name))
        assertEquals(steps + 2, laps.size, "$name laps ${laps.map { it["kind"] }}")
        assertEquals("manual", laps[0]["kind"], name)
        assertEquals(60_000L, laps[0]["t1"], "$name: rep 1 starts at the 60 s press")
        assertEquals(List(steps) { "auto" }, laps.subList(1, steps + 1).map { it["kind"] }, name)
        // The cool-down runs its 60 s after the last step, then the trace ends.
        assertTrue(dur(laps.last()) in 58_000L..61_000L, "$name cool-down ${dur(laps.last())}")
        return laps.subList(1, steps + 1)
    }

    private fun assertDistance(name: String, steps: List<Map<*, *>>, targets: (Int) -> Double?) {
        for ((i, l) in steps.withIndex()) {
            val target = targets(i) ?: continue
            assertTrue(abs(dist(l) - target) <= 4.5, "$name step $i: ${dist(l)} m for $target (one sample at 4 m/s)")
        }
    }

    @Test
    fun `replay fixtures - one per kind`() {
        val names = ContractFixtures.all().keys.filter { it.startsWith("replay_") }
        assertEquals(8, names.size, names.toString())
    }

    @Test
    fun `replay 4x4 - 3 reps, 5 auto laps on the exact time boundaries`() {
        val steps = structuredLaps("replay_4x4", 5)
        assertEquals(listOf(240_000L, 180_000L, 240_000L, 180_000L, 240_000L), steps.map { dur(it) })
    }

    @Test
    fun `replay 400s - 4 x 400 m with 200 m jogs, every step within a sample of its target`() {
        val steps = structuredLaps("replay_400s", 7)
        assertDistance("replay_400s", steps) { if (it % 2 == 0) 400.0 else 200.0 }
        // Closed loop: every rep is at work pace, so the reps take the same time (about 100 s).
        val reps = steps.filterIndexed { i, _ -> i % 2 == 0 }.map { dur(it) }
        assertTrue(reps.all { it in 99_000L..102_000L }, "rep times $reps")
    }

    @Test
    fun `replay 30-30s - 10 reps, 19 auto laps of exactly 30 s`() {
        val steps = structuredLaps("replay_30_30s", 19)
        assertTrue(steps.all { dur(it) == 30_000L }, steps.map { dur(it) }.toString())
        assertEquals("short", (fixture("replay_30_30s")["session"] as Map<*, *>)["cueProfile"])
    }

    @Test
    fun `replay yasso - 4 x 800 m, each recovery as long as the rep before it`() {
        val steps = structuredLaps("replay_yasso_800s", 7)
        assertDistance("replay_yasso_800s", steps) { if (it % 2 == 0) 800.0 else null }
        for (i in 1 until steps.size step 2) {
            assertTrue(abs(dur(steps[i]) - dur(steps[i - 1])) <= 1, "recovery $i ${dur(steps[i])} vs rep ${dur(steps[i - 1])}")
        }
    }

    @Test
    fun `replay 1km repeats - 3 x 1000 m, 120 s recoveries`() {
        val steps = structuredLaps("replay_1km_repeats", 5)
        assertDistance("replay_1km_repeats", steps) { if (it % 2 == 0) 1000.0 else null }
        assertEquals(listOf(120_000L, 120_000L), steps.filterIndexed { i, _ -> i % 2 == 1 }.map { dur(it) })
    }

    @Test
    fun `replay parkrun - no warm-up, auto-stopped at 5 00 km, one lap`() {
        val laps = laps(fixture("replay_parkrun"))
        assertEquals(1, laps.size, laps.toString())
        assertEquals(0L, laps[0]["t0"])
        assertTrue(dist(laps[0]) in 5_000.0..5_004.5, "5 km lap ${dist(laps[0])} m")
    }

    @Test
    fun `replay cooper - START REPS at 60 s, a 12-minute test`() {
        val m = fixture("replay_cooper")
        assertEquals("cooper", m["mode"])
        val laps = laps(m)
        assertEquals(60_000L, laps[0]["t1"], laps.toString())
        assertTrue(laps.any { it["kind"] == "auto" && dur(it) == 720_000L }, "no 12-minute test lap: ${laps.map { dur(it) }}")
    }

    @Test
    fun `replay fartlek - a Laps run with 5 manual segments`() {
        val m = fixture("replay_fartlek")
        assertEquals("laps", m["mode"])
        assertEquals(listOf(120_000L, 150_000L, 300_000L, 345_000L), laps(m).dropLast(1).map { it["t1"] })
        assertTrue(laps(m).all { it["kind"] == "manual" })
    }
}
