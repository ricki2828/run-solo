package app.runsolo.core.record

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** #89 review P3: the finish screen's end time is the pause's start, live and after a kill while paused. */
class RecorderCorePauseTest {
    @Test
    fun `pausedAtElapsedMs - the pause's start, null when running, rebuilt by restore`() {
        val core = RecorderCore(RunMode.free, null)
        core.start(0)
        core.tick(30_000, 90.0)
        assertNull(core.pausedAtElapsedMs)
        core.pause(40_000)
        core.tick(55_000, 120.0)
        assertEquals(40_000L, core.pausedAtElapsedMs)
        core.resume(60_000)
        assertNull(core.pausedAtElapsedMs)

        val lines = listOf(
            JournalLine.Header(0, 1_000, "p", "d", "a", "UTC", RunMode.free, null, Units.km),
            JournalLine.Sample(30_000, 31_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Pause(40_000, 41_000),
            JournalLine.Sample(55_000, 56_000, 0.0, 0.0, null, 5.0, null, null),
        )
        val restored = RecorderCore.restore(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), nowT = 9_000_000)
        assertEquals(40_000L, restored.pausedAtElapsedMs, "killed while paused: the finish screen still ends at the pause")
    }
}
