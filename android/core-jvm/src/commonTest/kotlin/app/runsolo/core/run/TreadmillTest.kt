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
}
