package app.runsolo.core.journal

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.run.RunPaths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
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
    fun `a write failure degrades, buffers in memory, retries and flushes in order`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        var failures = 0
        val w = JournalWriter(fs, "r1", retryIntervalMs = 5_000, onWriteFailed = { failures++ })
        w.open()
        w.append(header)
        fs.failAppendWrites = true
        w.append(sample(1000)) // fails → degraded, buffered
        w.append(sample(2000)) // buffered, retry not due
        assertFalse(w.ok)
        assertEquals(1, failures, "reported once per episode")
        assertEquals(2, w.buffered)
        assertEquals(1, w.linesWritten)
        fs.failAppendWrites = false
        w.append(sample(3000)) // buffered; retry not due until t >= 6000
        assertFalse(w.ok)
        w.append(JournalLine.Lap(6000, 1, LapSource.button)) // retry due → reopen, flush 4 lines in order
        assertTrue(w.ok)
        assertEquals(0, w.buffered)
        assertEquals(5, w.linesWritten)
        assertEquals(0, w.dropped)
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("r1")))
        assertEquals(listOf(1000L, 2000L, 3000L, 6000L), replay.events.map { it.t })
    }

    @Test
    fun `while degraded the memory buffer is bounded and close makes a last attempt`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val w = JournalWriter(fs, "r1", bufferLimit = 3, retryIntervalMs = 1_000_000)
        w.open()
        w.append(header)
        fs.failAppendWrites = true
        for (s in 1..5) w.append(sample(s * 1000L))
        assertEquals(3, w.buffered)
        assertEquals(2, w.dropped)
        fs.failAppendWrites = false
        w.close()
        assertTrue(w.ok)
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("r1")))
        assertEquals(listOf(3000L, 4000L, 5000L), replay.events.map { it.t })
    }

    @Test
    fun `an unencodable line is dropped, not fatal`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val w = JournalWriter(fs, "r1")
        w.open()
        w.append(header)
        // NaN fields are sanitised by the codec to a no-fix tick rather than thrown.
        w.append(JournalLine.Sample(1000, 1, Double.NaN, 0.0, Double.POSITIVE_INFINITY, 5.0, Double.NaN, 140))
        assertTrue(w.ok)
        assertEquals(0, w.dropped)
        val s = JournalReplay.read(fs.readBytes(RunPaths.journal("r1"))).events.single()
        assertIs<RunEvent.Sample>(s)
        assertFalse(s.hasFix)
        assertEquals(140, s.hr)
    }

    @Test
    fun `resume after power loss drops the torn tail so the gap line stands alone`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        val w = JournalWriter(fs, "r1")
        w.open()
        w.append(header)
        w.append(sample(1000))
        w.close()
        // Power loss mid-write: half a line and some NULs, no newline.
        val torn = fs.readBytes(RunPaths.journal("r1")) + "{\"k\":\"s\",\"t\":20".toByteArray() + ByteArray(4)
        fs.writeBytes(RunPaths.journal("r1"), torn)
        val w2 = JournalWriter(fs, "r1")
        w2.open()
        assertEquals(19, w2.tornTailBytes)
        w2.append(JournalLine.Gap(50, 2, 120_000))
        w2.append(sample(1050))
        w2.close()
        val replay = JournalReplay.read(fs.readBytes(RunPaths.journal("r1")))
        assertEquals(0, replay.badLines)
        assertEquals(RunEvent.Gap(1000, 121_000), replay.events[1])
        assertEquals(122_000, replay.events[2].t)
    }
}
