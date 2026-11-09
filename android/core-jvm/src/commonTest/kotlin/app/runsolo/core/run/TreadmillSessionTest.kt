package app.runsolo.core.run

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import kotlin.test.*

/** A session (the 12-minute test, intervals) run on a treadmill: its own mode plus an incline in the header. */
class TreadmillSessionTest {
    private val w0 = 1700000000000
    private fun header(mode: RunMode, spec: SessionSpec?, incline: Double?) =
        JournalLine.Header(0, w0, "belt", "phone", "test", "UTC", mode, spec, Units.km, incline)

    private fun replay(lines: List<JournalLine>) =
        JournalReplay.read(lines.joinToString("", transform = { JournalCodec.encode(it) + "\n" }).encodeToByteArray())

    @Test fun `the header carries the incline and an outdoor header carries none`() {
        val belt = header(RunMode.cooper, SessionSpec.COOPER, 1.0)
        assertTrue(JournalCodec.encode(belt).contains("\"ti\""))
        assertEquals(belt, JournalCodec.decode(JournalCodec.encode(belt)))
        assertTrue(belt.indoor)
        val outdoor = header(RunMode.cooper, SessionSpec.COOPER, null)
        assertFalse(JournalCodec.encode(outdoor).contains("\"ti\""))
        assertNull((JournalCodec.decode(JournalCodec.encode(outdoor)) as JournalLine.Header).treadmillInclinePct)
        assertFalse(outdoor.indoor)
    }

    @Test fun `a free treadmill run is indoor without an incline`() {
        assertTrue(header(RunMode.treadmill, null, null).indoor)
    }

    @Test fun `a belt test keeps its mode and writes the incline distance and schema 9`() {
        val h = header(RunMode.cooper, SessionSpec.COOPER, 2.0)
        val restored = replay(listOf(h,
            JournalLine.Sample.noFix(1000, w0 + 1000, 140),
            JournalLine.Sample.noFix(60000, w0 + 60000, 150),
            JournalLine.TreadmillMark(30000, w0 + 30000, 500.0, 30000),
            JournalLine.TreadmillDistance(61000, w0 + 61000, 2800.0)))
        assertEquals(2.0, restored.header.treadmillInclinePct)
        val run = RunFile.fromReplay(restored, w0 + 60000)
        assertEquals(RunMode.cooper, run.mode)
        assertTrue(run.onTreadmill)
        assertEquals(2800.0, run.distanceM)
        assertEquals(1, run.treadmillMarks.size)
        val json = run.toJson()
        assertEquals(9, json["schema"])
        assertEquals(2.0, json["treadmillInclinePct"])
        assertEquals(2800.0, json["treadmillDistanceM"])
        assertEquals("cooper", json["mode"])
    }

    @Test fun `a belt intervals run keeps its session and a kill before the distance keeps the incline`() {
        val spec = SessionSpec.norwegian4x4()
        val restored = replay(listOf(header(RunMode.intervals, spec, 1.0),
            JournalLine.Sample.noFix(1000, w0 + 1000, 140)))
        val run = RunFile.fromReplay(restored, w0 + 1000)
        assertEquals(RunMode.intervals, run.mode)
        assertEquals(spec.templateId, run.session?.templateId)
        assertEquals(1.0, run.treadmillInclinePct)
        assertNull(run.treadmillDistanceM)
        assertEquals(0.0, run.distanceM)
        assertTrue(run.samples.all { !it.hasFix })
    }

    @Test fun `an outdoor run writes no incline and drops a stray distance line`() {
        val restored = replay(listOf(header(RunMode.cooper, SessionSpec.COOPER, null),
            JournalLine.Sample.noFix(1000, w0 + 1000, 140),
            JournalLine.TreadmillDistance(2000, w0 + 2000, 100.0)))
        val run = RunFile.fromReplay(restored, w0 + 1000)
        assertFalse(run.onTreadmill)
        val json = run.toJson()
        assertFalse(json.containsKey("treadmillInclinePct"))
        assertFalse(json.containsKey("treadmillDistanceM"))
        assertNotEquals(9, json["schema"])
    }
}
