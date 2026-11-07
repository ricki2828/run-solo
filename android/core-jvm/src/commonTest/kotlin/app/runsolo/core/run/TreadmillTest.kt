package app.runsolo.core.run

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore
import kotlin.test.*

class TreadmillTest {
    private val header = JournalLine.Header(0, 1700000000000, "treadmill", "phone", "test", "UTC", RunMode.treadmill, null, Units.km)
    private fun replay(lines: List<JournalLine>) = JournalReplay.read(lines.joinToString("", transform = { JournalCodec.encode(it) + "\n" }).encodeToByteArray())

    @Test fun `no fix recording retains time HR and distance after replay and paused finish`() {
        val lines = listOf(header,
            JournalLine.Sample.noFix(1000, header.w + 1000, 140),
            JournalLine.Sample.noFix(60000, header.w + 60000, 150),
            JournalLine.Pause(60000, header.w + 60000),
            JournalLine.TreadmillDistance(65000, header.w + 65000, 250.0))
        val restored = replay(lines)
        assertEquals(250.0, restored.treadmillDistanceM)
        val run = RunFile.fromReplay(restored, header.w + 60000)
        assertEquals(RunMode.treadmill, run.mode)
        assertEquals(250.0, run.distanceM)
        assertEquals(60000L, run.elapsedMs)
        assertTrue(run.samples.all { !it.hasFix && it.distM == 0.0 })
        assertEquals(listOf(140, 150), run.samples.map { it.hr })
        assertEquals(9, run.toJson()["schema"])
        assertEquals(250.0, run.toJson()["treadmillDistanceM"])
        assertNull(RecorderCore.unsupported(RunMode.treadmill, null))
        assertFalse(RunMode.treadmill.lapInput)
    }


    @Test fun `resuming after a failed save clears the old entered total`() {
        val restored = replay(listOf(header,
            JournalLine.Sample.noFix(1000, header.w + 1000, 140),
            JournalLine.TreadmillDistance(2000, header.w + 2000, 250.0),
            JournalLine.Resume(3000, header.w + 3000)))
        assertNull(restored.treadmillDistanceM)
    }

    @Test fun `recovery before entry stays explicitly treadmill with unknown distance`() {
        val run = RunFile.fromReplay(replay(listOf(header, JournalLine.Sample.noFix(1000, header.w + 1000, 140))), header.w + 1000)
        assertEquals(RunMode.treadmill, run.mode)
        assertNull(run.treadmillDistanceM)
        assertEquals(0.0, run.distanceM)
        for (bad in listOf(-1.0, 0.0, Double.NaN, Double.POSITIVE_INFINITY, 500001.0)) {
            assertFailsWith<IllegalArgumentException> { JournalLine.TreadmillDistance(1000, header.w + 1000, bad) }
        }
    }

    @Test fun `markers replay in order and undo takes the latest back`() {
        val restored = replay(listOf(header,
            JournalLine.Sample.noFix(1000, header.w + 1000, 140),
            JournalLine.TreadmillMark(150000, header.w + 150000, 500.0, 150000),
            JournalLine.TreadmillMark(290000, header.w + 290000, 1000.0, 290000),
            JournalLine.TreadmillMarkUndo(291000, header.w + 291000),
            JournalLine.TreadmillMark(300000, header.w + 300000, 1500.0, 300000)))
        assertEquals(listOf(500.0, 1500.0), restored.treadmillMarks.map { it.distanceM })
        assertEquals(listOf(150000L, 300000L), restored.treadmillMarks.map { it.activeMs })
    }

    @Test fun `markers survive a kill and reach the run file as pairs`() {
        val lines = listOf(header,
            JournalLine.Sample.noFix(1000, header.w + 1000, 140),
            JournalLine.TreadmillMark(150000, header.w + 150000, 500.0, 150000),
            JournalLine.Pause(160000, header.w + 160000),
            JournalLine.TreadmillDistance(170000, header.w + 170000, 600.0))
        val run = RunFile.fromReplay(replay(lines), header.w + 160000)
        assertEquals(1, run.treadmillMarks.size)
        assertEquals(listOf(listOf(150000L, 500.0)), run.toJson()["treadmillMarks"])
    }

    @Test fun `a run with no markers writes no marker key and an undo on none is harmless`() {
        val restored = replay(listOf(header, JournalLine.TreadmillMarkUndo(1000, header.w + 1000)))
        assertTrue(restored.treadmillMarks.isEmpty())
        assertFalse(RunFile.fromReplay(restored, header.w + 1000).toJson().containsKey("treadmillMarks"))
    }

    @Test fun `marker lines round trip and reject bad values`() {
        val m = JournalLine.TreadmillMark(5, header.w + 5, 500.0, 4000)
        assertEquals(m, JournalCodec.decode(JournalCodec.encode(m)))
        val u = JournalLine.TreadmillMarkUndo(6, header.w + 6)
        assertEquals(u, JournalCodec.decode(JournalCodec.encode(u)))
        for (bad in listOf(-1.0, 0.0, Double.NaN, 500001.0)) {
            assertFailsWith<IllegalArgumentException> { JournalLine.TreadmillMark(1, 1, bad, 0) }
        }
        assertFailsWith<IllegalArgumentException> { JournalLine.TreadmillMark(1, 1, 500.0, -1) }
    }
}
