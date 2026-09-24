package app.runsolo.core.run

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.json.list
import app.runsolo.core.model.LapKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.replay.TraceFixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RunFileTest {
    private val t0 = 50_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.fourByFour, Preset.DEFAULT_4X4, Units.km)

    /** 20 s at 3 m/s, lap, 20 s at 3 m/s, pause 5 s, 10 s more. */
    private fun journal(): ByteArray {
        val fixes = TraceFixture.straightLine(listOf(50 to 3.0), startT = t0)
        val sb = StringBuilder(JournalCodec.encode(header)).append('\n')
        for (f in fixes) {
            val runT = f.t - t0
            if (runT == 20_000L) sb.append(JournalCodec.encode(JournalLine.Lap(f.t, w0 + runT, LapSource.button))).append('\n')
            if (runT == 40_000L) sb.append(JournalCodec.encode(JournalLine.Pause(f.t, w0 + runT))).append('\n')
            if (runT == 45_000L) sb.append(JournalCodec.encode(JournalLine.Resume(f.t, w0 + runT))).append('\n')
            val hr = if (runT in 30_000..35_000) 150 else null
            sb.append(JournalCodec.encode(JournalLine.Sample(f.t, w0 + runT, f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, hr))).append('\n')
        }
        return sb.toString().toByteArray()
    }

    @Test
    fun `laps are segments between markers with cumulative distance`() {
        val r = JournalReplay.read(journal())
        val f = RunFile.fromReplay(r, w0 + 50_000)
        assertEquals(2, f.laps.size)
        assertEquals(RunFile.Lap(0, 0, 20_000, 0.0, f.laps[0].d1, LapKind.manual), f.laps[0])
        assertEquals(20_000, f.laps[1].t0)
        assertEquals(50_000, f.laps[1].t1)
        assertEquals(LapKind.manual, f.laps[1].kind)
        assertEquals(60.0, f.laps[0].d1, 0.5)
        assertEquals(150.0, f.laps[1].d1, 1.0)
        assertEquals(f.laps[0].d1, f.laps[1].d0)
        assertEquals(1, f.pauses.size)
        assertEquals(listOf(40_000L, 45_000L), f.pauses[0].asList())
        assertEquals(0, f.gaps.size)
        assertEquals(51, f.samples.size)
        assertEquals(w0, f.startEpochMs)
        assertEquals(50_000, f.elapsedMs)
    }

    @Test
    fun `gzip json round trip matches schema v1`() {
        val f = RunFile.fromReplay(JournalReplay.read(journal()), w0 + 50_000)
        val m = RunFile.readJson(f.toGzipBytes())
        assertEquals(1L, m["schema"])
        assertEquals("id1", m["id"])
        assertEquals("fourByFour", m["mode"])
        assertEquals("km", m["units"])
        assertEquals("2023-11-14T22:13:20Z", m["start"])
        assertEquals(mapOf("reps" to 4L, "workSeconds" to 240L, "recoverySeconds" to 180L), m["preset"])
        val laps = m.list("laps")
        assertEquals(2, laps.size)
        val lap0 = laps[0] as Map<*, *>
        assertEquals(setOf("i", "t0", "t1", "d0", "d1", "kind"), lap0.keys)
        val samples = m.list("samples")
        assertEquals(51, samples.size)
        val s30 = samples[30] as List<*>
        assertEquals(8, s30.size)
        assertEquals(30_000L, s30[0])
        assertEquals(150L, s30[7])
        assertNull((samples[0] as List<*>)[7])
        assertEquals(listOf(listOf(40_000L, 45_000L)), m["pauses"])
        assertEquals(emptyList<Any>(), m["gaps"])
    }

    @Test
    fun `an auto lap marker gives an auto lap and an open pause closes at the end`() {
        val text = listOf(
            header,
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Lap(t0 + 2000, w0 + 2000, LapSource.auto),
            JournalLine.Pause(t0 + 3000, w0 + 3000),
            JournalLine.Sample(t0 + 4000, w0 + 4000, 0.0, 0.0, null, 5.0, null, null),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val f = RunFile.fromReplay(JournalReplay.read(text.toByteArray()), w0 + 4000)
        assertEquals(LapKind.auto, f.laps[0].kind)
        assertEquals(LapKind.manual, f.laps[1].kind)
        assertEquals(listOf(3000L, 4000L), f.pauses.single().asList())
        assertTrue(f.distanceM == 0.0)
    }

    @Test
    fun `gap span is carried into gaps`() {
        val text = listOf(
            header,
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Gap(10, w0 + 61_000, 60_000),
            JournalLine.Sample(1010, w0 + 62_000, 0.0, 0.0, null, 5.0, null, null),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val f = RunFile.fromReplay(JournalReplay.read(text.toByteArray()), w0 + 62_000)
        assertEquals(listOf(1000L, 61_000L), f.gaps.single().asList())
        assertEquals(62_000, f.samples.last().t)
    }
}
