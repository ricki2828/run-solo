package app.runsolo.core.contract

import app.runsolo.core.json.Json
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EventTraceFixtureTest {
    private fun lines(): List<Map<String, Any?>> = EventTraceFixture.generate().lineSequence().filter { it.isNotBlank() }.map { Json.parseObject(it) }.toList()

    @Test
    fun `checked-in event trace matches the generator byte for byte`() {
        val file = File(EventTraceFixture.DIR, "${EventTraceFixture.NAME}.ndjson")
        assertTrue(file.exists(), "missing ${file.path}; regenerate with EventTraceFixtureKt.main")
        assertEquals(EventTraceFixture.generate(), file.readText(), "event trace drifted; regenerate and copy to run_engine")
    }

    @Test
    fun `trace shape - 10 laps, pause, one kill gap, phases in order, ticks monotonic`() {
        val ev = lines()
        val laps = ev.filter { it["kind"] == "lap" }
        assertEquals(9, laps.size, "9 lap markers → 10 laps in the file")
        assertEquals(listOf("notification") + List(8) { "auto" }, laps.map { it["source"] })
        // Active lap time excludes the pause (rep 2 work) and the dark gap (rep 3 work): every work lap is 240 s.
        assertEquals(List(4) { 240_000L }, laps.filterIndexed { i, _ -> i % 2 == 1 }.map { it["activeMs"] })
        assertEquals(listOf(60_000L) + List(4) { 180_000L }, laps.filterIndexed { i, _ -> i % 2 == 0 }.map { it["activeMs"] })
        assertEquals(240_000L + 20_000L, (laps[3]["tMs"] as Long) - (laps[2]["tMs"] as Long), "wall time of rep 2 includes the pause")
        assertEquals(240_000L + 30_000L, (laps[5]["tMs"] as Long) - (laps[4]["tMs"] as Long), "wall time of rep 3 includes the gap")
        val phases = ev.filter { it["kind"] == "phase" }.map { it["phase"] }
        assertEquals(listOf("warmup", "work", "recovery", "work", "recovery", "work", "recovery", "work", "recovery", "cooldown"), phases)
        val states = ev.filter { it["kind"] == "state" }.map { it["state"] }
        assertEquals(listOf("recording", "paused", "recording", "recording", "finalising", "idle"), states)
        val ticks = ev.filter { it["kind"] == "tick" }
        val ts = ticks.map { it["elapsedMs"] as Long }
        assertTrue(ts.zipWithNext().all { (a, b) -> b > a }, "elapsed monotonic")
        // The kill: one jump of 30 s between consecutive ticks, nothing else larger than 1 s.
        val jumps = ts.zipWithNext().map { (a, b) -> b - a }.filter { it > 1000 }
        assertEquals(listOf(31_000L), jumps)
        // Paused ticks: state paused, distance frozen.
        val pausedTicks = ticks.filter { it["state"] == "paused" }
        assertEquals(20, pausedTicks.size)
        assertEquals(1, pausedTicks.map { it["totalDistanceM"] }.toSet().size)
        // Rep 3 work continues after the resume with its countdown intact.
        val afterResume = ticks.first { (it["elapsedMs"] as Long) > 960_000 + 31_000 }
        assertEquals("work", afterResume["phase"])
        assertEquals(3L, afterResume["repIndex"])
        assertTrue((afterResume["phaseRemainingMs"] as Long) in 170_000L..180_000L, "remaining ${afterResume["phaseRemainingMs"]}")
        // Cue lines keep `kind: cue` and carry the cue name in `cue`.
        val cues = ev.filter { it["kind"] == "cue" }.map { it["cue"] }
        assertEquals(4 * 8, cues.count { it != "stop" } - 1 + 1) // 4 cues per timed phase × 8 phases (rep 1's start rides with the LAP)
        assertEquals("stop", cues.last())
        // Status snapshots carry laps and mode.
        val status = ev.last { it["kind"] == "status" }
        assertEquals("fourByFour", status["mode"])
        assertEquals(9, (status["laps"] as List<*>).size)
    }
}
