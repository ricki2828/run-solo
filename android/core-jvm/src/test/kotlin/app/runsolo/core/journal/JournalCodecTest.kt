package app.runsolo.core.journal

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.SessionSpec
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
        tz = "Australia/Sydney", mode = RunMode.intervals, session = SessionSpec.norwegian4x4(), units = Units.km,
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
    fun `schema-3 header carries the full session and round trips it`() {
        val text = JournalCodec.encode(header)
        assertTrue(text.contains("\"schema\":3"), text)
        assertTrue(text.contains("\"mode\":\"intervals\",\"session\":{\"templateId\":\"norwegian-4x4\""), text)
        assertFalse(text.contains("preset"), text)
        assertEquals(header, JournalCodec.decode(text))
    }

    @Test
    fun `header without a session (laps, free), cooper and fartlek sessions`() {
        for (m in listOf(RunMode.laps, RunMode.free)) {
            val h = header.copy(mode = m, session = null)
            assertEquals(h, JournalCodec.decode(JournalCodec.encode(h)))
        }
        for (h in listOf(header.copy(mode = RunMode.cooper, session = SessionSpec.COOPER), header.copy(mode = RunMode.laps, session = SessionSpec.FARTLEK))) {
            assertEquals(h, JournalCodec.decode(JournalCodec.encode(h)))
        }
    }

    private fun legacy(schema: Int, mode: String, preset: String) =
        JournalCodec.decode("""{"k":"hdr","schema":$schema,"t":1,"w":2,"id":"x","device":"d","app":"a","tz":"UTC","mode":"$mode","preset":$preset,"units":"km"}""") as JournalLine.Header

    @Test
    fun `old journals - fourByFour + preset map to intervals + the norwegian-4x4 spec`() {
        val h = legacy(2, "fourByFour", """{"reps":3,"workSeconds":240,"recoverySeconds":150}""")
        assertEquals(RunMode.intervals, h.mode)
        assertEquals(SessionSpec.norwegian4x4(3, 240, 150), h.session)
        val s = h.session!!
        assertEquals(listOf("work" to 240, "recovery" to 150, "work" to 240, "recovery" to 150, "work" to 240), s.steps.map { it.kind.name to it.value })
        assertEquals(listOf(1, 1, 2, 2, 3), s.steps.map { it.rep })
        assertEquals(0.85 to 0.95, s.hrBand)
        // No preset: the standard 4 × 240/180.
        assertEquals(SessionSpec.norwegian4x4(4, 240, 180), legacy(2, "fourByFour", "null").session)
        assertEquals(SessionSpec.norwegian4x4(), legacy(1, "fourByFour", "null").session)
        // Schema-2 cooper → the Cooper spec; laps/free → none; schema-1 free → laps.
        assertEquals(SessionSpec.COOPER, legacy(2, "cooper", "null").session)
        assertEquals(null, legacy(2, "laps", "null").session)
        assertEquals(RunMode.laps, legacy(1, "free", "null").mode)
        assertEquals(null, legacy(1, "free", "null").session)
    }

    @Test
    fun `schema-1 free maps to laps, schema-2 free stays free, newer schema or unknown mode is NewerSchema`() {
        fun hdr(schema: Int, mode: String) =
            """{"k":"hdr","schema":$schema,"t":1,"w":2,"id":"x","device":"d","app":"a","tz":"UTC","mode":"$mode","preset":null,"units":"km"}"""
        assertEquals(RunMode.laps, (JournalCodec.decode(hdr(1, "free")) as JournalLine.Header).mode)
        assertEquals(RunMode.free, (JournalCodec.decode(hdr(2, "free")) as JournalLine.Header).mode)
        assertEquals(RunMode.laps, (JournalCodec.decode(hdr(2, "laps")) as JournalLine.Header).mode)
        assertFailsWith<JournalCodec.NewerSchema> { JournalCodec.decode(hdr(3, "fourByFour")) }
        assertFailsWith<JournalCodec.NewerSchema> { JournalCodec.decode(hdr(4, "intervals")) }
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
