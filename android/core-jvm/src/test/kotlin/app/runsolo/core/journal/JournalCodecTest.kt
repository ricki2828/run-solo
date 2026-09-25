package app.runsolo.core.journal

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class JournalCodecTest {
    private val header = JournalLine.Header(
        t = 5_000, w = 1_700_000_000_000, id = "abc-123", device = "Pixel 8", app = "1.0.0 (1)",
        tz = "Australia/Sydney", mode = RunMode.fourByFour, preset = Preset.DEFAULT_4X4, units = Units.km,
    )

    @Test
    fun `every line kind round trips`() {
        val lines = listOf(
            header,
            JournalLine.Sample(6_000, 1, -33.8688, 151.2093, 12.5, 4.0, 3.1, 150),
            JournalLine.Sample(7_000, 2, -33.8688, 151.2093, null, 25.0, null, null),
            JournalLine.Sample.noFix(7_500, 2, 148),
            JournalLine.Sample.noFix(8_500, 2, null),
            JournalLine.Lap(8_000, 3, LapSource.notification),
            JournalLine.Pause(9_000, 4),
            JournalLine.Resume(10_000, 5),
            JournalLine.Cue(11_000, 6, CueKind.thirtySeconds),
            JournalLine.Gap(500, 7, 120_000),
            JournalLine.HrLink(12_000, 8, true),
        )
        for (l in lines) {
            val text = JournalCodec.encode(l)
            assertFalse(text.contains('\n'), "one line per record: $text")
            assertEquals(l, JournalCodec.decode(text), text)
        }
    }

    @Test
    fun `nulls are omitted not written`() {
        val text = JournalCodec.encode(JournalLine.Sample(1, 1, 0.0, 0.0, null, 5.0, null, null))
        assertFalse(text.contains("hr"))
        assertFalse(text.contains("alt"))
        assertTrue(text.contains("\"k\":\"s\""))
    }

    @Test
    fun `no-fix sample carries only t and hr`() {
        val text = JournalCodec.encode(JournalLine.Sample.noFix(7_500, 2, 148))
        assertEquals("""{"k":"s","t":7500,"w":2,"hr":148}""", text)
        assertFalse(JournalCodec.decode(text).let { (it as JournalLine.Sample).hasFix })
    }

    @Test
    fun `preset reps are 3 to 6 on both sides`() {
        assertFailsWith<IllegalArgumentException> { Preset(2, 240, 180) }
        assertFailsWith<IllegalArgumentException> { Preset(7, 240, 180) }
        Preset(3, 240, 120)
        Preset(6, 240, 300)
    }

    @Test
    fun `header without preset (laps, free, cooper)`() {
        for (m in listOf(RunMode.laps, RunMode.free, RunMode.cooper)) {
            val h = header.copy(mode = m, preset = null)
            val text = JournalCodec.encode(h)
            assertTrue(text.contains("\"schema\":2"), text)
            assertEquals(h, JournalCodec.decode(text))
        }
    }

    @Test
    fun `schema-1 free maps to laps, schema-2 free stays free, newer schema or unknown mode is NewerSchema`() {
        fun hdr(schema: Int, mode: String) =
            """{"k":"hdr","schema":$schema,"t":1,"w":2,"id":"x","device":"d","app":"a","tz":"UTC","mode":"$mode","preset":null,"units":"km"}"""
        assertEquals(RunMode.laps, (JournalCodec.decode(hdr(1, "free")) as JournalLine.Header).mode)
        assertEquals(RunMode.free, (JournalCodec.decode(hdr(2, "free")) as JournalLine.Header).mode)
        assertEquals(RunMode.laps, (JournalCodec.decode(hdr(2, "laps")) as JournalLine.Header).mode)
        assertFailsWith<JournalCodec.NewerSchema> { JournalCodec.decode(hdr(3, "fourByFour")) }
        assertFailsWith<JournalCodec.NewerSchema> { JournalCodec.decode(hdr(2, "hyrox")) }
        // Schema 1 never wrote `laps`; if it appears, it is not a mapping case and decodes as itself.
        assertEquals(RunMode.laps, JournalCodec.decodeMode("laps", 1))
    }

    @Test
    fun `malformed lines throw`() {
        assertFailsWith<Exception> { JournalCodec.decode("""{"k":"lap","t":1}""") } // no src
        assertFailsWith<Exception> { JournalCodec.decode("""{"k":"zzz","t":1}""") }
        assertFailsWith<Exception> { JournalCodec.decode("""{"k":"s","t":1,"lat":"x","lon":1,"acc":2}""") }
        assertFailsWith<Exception> { JournalCodec.decode("""{"k":"s","t":1,"lat":1,"lon":2}""") } // partial fix
        assertFailsWith<Exception> { JournalCodec.decode("""{"k":"s","t":1,"lat":1,"lon":2,"acc":3""") }
    }
}
