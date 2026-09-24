package app.runsolo.core.journal

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunPaths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class JournalWriterTest {
    private val fs = FakeFileSystem()
    private val header = JournalLine.Header(0, 1, "r1", "d", "a", "UTC", RunMode.free, null, Units.km)

    private fun sample(t: Long) = JournalLine.Sample(t, 1, 0.0, 0.0, null, 5.0, null, null)

    @Test
    fun `writes one line per record and fsyncs on header laps pauses and every 10 s`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val w = JournalWriter(fs, "r1")
        w.open()
        w.append(header) // fsync 1 (forced)
        for (s in 1..25) w.append(sample(s * 1000L)) // fsync at 10 s, 20 s → 2 more
        w.append(JournalLine.Lap(25_500, 1, LapSource.button)) // forced → 4
        w.append(JournalLine.Pause(26_000, 1)) // forced → 5
        w.append(JournalLine.Resume(27_000, 1)) // forced → 6
        w.close() // → 7
        assertEquals(7, fs.fsyncCount)
        assertEquals(29, w.linesWritten)
        val text = fs.readBytes(RunPaths.journal("r1")).toString(Charsets.UTF_8)
        assertEquals(29, text.lines().size - 1)
        assertTrue(text.endsWith("\n"))
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("r1")))
        assertEquals(28, replay.events.size)
    }

    @Test
    fun `write failure is reported once and the writer goes quiet`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        var failures = 0
        val w = JournalWriter(fs, "r1", onWriteFailed = { failures++ })
        w.open()
        w.append(header)
        fs.failAppendWrites = true
        w.append(sample(1000))
        w.append(sample(2000))
        assertFalse(w.ok)
        assertEquals(1, failures)
        assertEquals(1, w.linesWritten)
    }
}
