package app.runsolo.core.record

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import kotlin.test.*

class TreadmillMarksTest {
    @Test fun `a mark is refused while paused`() {
        val m = TreadmillMarks()
        assertFalse(m.accepts(500.0, 180_000, paused = true))
        assertTrue(m.accepts(500.0, 180_000, paused = false))
    }

    @Test fun `marks across a pause and resume keep moving time and the speed after it is right`() {
        val core = RecorderCore(RunMode.treadmill, null)
        core.start(0)
        val m = TreadmillMarks()
        // 0.5 km at 3:00 of moving time
        assertTrue(m.accepts(500.0, core.status(180_000).activeMs, core.state == app.runsolo.core.model.RecorderState.paused))
        m.add(500.0, core.status(180_000).activeMs)
        core.pause(180_000)
        // 60 s paused: the mark is refused and the moving time has not moved
        val pausedActive = core.status(240_000).activeMs
        assertEquals(180_000L, pausedActive)
        assertFalse(m.accepts(1000.0, pausedActive, paused = core.state == app.runsolo.core.model.RecorderState.paused))
        core.resume(240_000)
        // 2:30 more of moving time: 1.0 km at 5:30 moving time (wall 7:30)
        val active = core.status(390_000).activeMs
        assertEquals(330_000L, active)
        assertTrue(m.accepts(1000.0, active, paused = false))
        m.add(1000.0, active)
        // the second stretch: 500 m in 150 s moving, not 210 s with the pause
        assertEquals(listOf(180_000.0, 500.0, 330_000.0, 1000.0), m.flat())
    }

    @Test fun `a second mark at the same moving time or not past the last distance is refused`() {
        val m = TreadmillMarks()
        m.add(500.0, 180_000)
        assertFalse(m.accepts(1000.0, 180_000, paused = false))
        assertFalse(m.accepts(500.0, 200_000, paused = false))
        assertFalse(m.accepts(400.0, 200_000, paused = false))
        assertTrue(m.accepts(1000.0, 180_001, paused = false))
    }

    @Test fun `bad distances are refused`() {
        val m = TreadmillMarks()
        for (bad in listOf(0.0, -5.0, Double.NaN, Double.POSITIVE_INFINITY, 500_001.0)) {
            assertFalse(m.accepts(bad, 1000, paused = false), "$bad")
        }
    }

    @Test fun `recovery then undo removes the latest mark`() {
        val header = JournalLine.Header(0, 1700000000000, "treadmill", "phone", "test", "UTC", RunMode.treadmill, null, Units.km)
        val lines = listOf(
            header,
            JournalLine.TreadmillMark(150000, header.w + 150000, 500.0, 150000),
            JournalLine.TreadmillMark(290000, header.w + 290000, 1000.0, 290000),
            JournalLine.TreadmillMark(430000, header.w + 430000, 1500.0, 430000),
            JournalLine.TreadmillMarkUndo(431000, header.w + 431000),
        )
        val replayed = JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.encodeToByteArray())
        val m = TreadmillMarks(replayed.treadmillMarks)
        assertEquals(listOf(150000.0, 500.0, 290000.0, 1000.0), m.flat())
        assertTrue(m.undo())
        assertEquals(listOf(150000.0, 500.0), m.flat())
        assertTrue(m.undo())
        assertFalse(m.undo())
        assertTrue(m.flat().isEmpty())
    }
}
