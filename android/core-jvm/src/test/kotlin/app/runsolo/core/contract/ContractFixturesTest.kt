package app.runsolo.core.contract

import app.runsolo.core.json.list
import app.runsolo.core.model.LapKind
import app.runsolo.core.run.RunFile
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ContractFixturesTest {
    @Test
    fun `checked-in contract fixtures match the generator byte for byte`() {
        for ((name, f) in ContractFixtures.all()) {
            val file = File(ContractFixtures.DIR, "$name.json")
            assertTrue(file.exists(), "missing ${file.path}; regenerate with ContractFixturesKt.main")
            assertEquals(ContractFixtures.json(f) + "\n", file.readText(), "$name drifted; regenerate and copy to run_engine")
        }
    }

    @Test
    fun `4x4 preset fixture has 10 laps, 8 auto, HR on every sample`() {
        val f = ContractFixtures.all().getValue("four_by_four_preset_auto_hr")
        assertEquals(10, f.laps.size)
        assertEquals(8, f.laps.count { it.kind == LapKind.auto })
        assertEquals(LapKind.manual, f.laps.first().kind)
        assertEquals(LapKind.manual, f.laps.last().kind)
        assertEquals(60_000, f.laps[0].t1)
        assertEquals(300_000, f.laps[1].t1)
        assertEquals(240.0 * 4.2, f.laps[1].d1 - f.laps[1].d0, 2.0)
        assertTrue(f.samples.all { it.hr != null && it.hasFix })
        assertEquals(f.samples.size, f.fixCount)
        assertEquals(mapOf("reps" to 4, "workSeconds" to 240, "recoverySeconds" to 180), f.preset!!.toJson())
    }

    @Test
    fun `treadmill fixture has HR, no fixes, zero distance, 2 laps`() {
        val f = ContractFixtures.all().getValue("treadmill_no_fix_hr")
        assertEquals(600, f.samples.size)
        assertEquals(0, f.fixCount)
        assertEquals(0.0, f.distanceM)
        assertEquals(2, f.laps.size)
        assertEquals(150, f.samples.last().hr)
        val row = RunFile.readJson(f.toGzipBytes()).list("samples")[0] as List<*>
        assertEquals(listOf(1000L, null, null, null, null, null, 0L, 120L), row)
    }

    @Test
    fun `dropout fixture keeps HR through 46 no-fix ticks and distance catches up`() {
        val f = ContractFixtures.all().getValue("gps_dropout_hr")
        assertEquals(361, f.samples.size)
        assertEquals(361 - 46, f.fixCount)
        assertTrue(f.samples.all { it.hr == 150 })
        assertEquals(360 * 3.0, f.distanceM, 3.0)
        val during = f.samples.filter { it.t in 120_000..165_000 }
        assertTrue(during.all { !it.hasFix && it.distM == during.first().distM })
    }

    @Test
    fun `pause fixture has one 20 s pause and 3 laps`() {
        val f = ContractFixtures.all().getValue("free_run_pause_manual_laps")
        assertEquals(listOf(270_000L, 290_000L), f.pauses.single().asList())
        assertEquals(3, f.laps.size)
        assertEquals(listOf(0L, 180_000L, 360_000L), f.laps.map { it.t0 })
        assertEquals(540_000, f.laps.last().t1)
    }
}
