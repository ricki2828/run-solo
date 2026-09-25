package app.runsolo.core.journal

import app.runsolo.core.model.LapSource
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class JournalReplayTest {
    private val t0 = 100_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.intervals, SessionSpec.norwegian4x4(), Units.km)

    private fun enc(vararg lines: JournalLine) = lines.joinToString("") { JournalCodec.encode(it) + "\n" }

    private fun sample(t: Long) = JournalLine.Sample(t, w0 + (t - t0), 1.0, 2.0, null, 5.0, 3.0, null)

    @Test
    fun `run timeline starts at zero and follows device t`() {
        val r = JournalReplay.read(enc(header, sample(t0 + 1000), JournalLine.Lap(t0 + 2500, w0 + 2500, LapSource.button)).toByteArray())
        assertEquals(listOf(1000L, 2500L), r.events.map { it.t })
        assertEquals(2500, r.endT)
        assertEquals(w0 + 2500, r.lastWallMs)
        assertEquals(t0 + 2500, r.lastDeviceT)
        assertFalse(r.truncatedTail)
        assertEquals(0, r.badLines)
    }

    @Test
    fun `truncated last line is dropped and flagged`() {
        val full = enc(header, sample(t0 + 1000), sample(t0 + 2000))
        val cut = full.substring(0, full.length - 7) // mid-way through the last line, no newline
        val r = JournalReplay.read(cut.toByteArray())
        assertTrue(r.truncatedTail)
        assertEquals(1, r.events.size)
        assertEquals(1000, r.endT)
        assertEquals(0, r.badLines)
    }

    @Test
    fun `truncation inside a multibyte character does not crash`() {
        val h = header.copy(device = "Pixel ★ 8")
        val bytes = enc(h, sample(t0 + 1000)).toByteArray()
        val r = JournalReplay.read(bytes.copyOf(bytes.size - 3))
        assertTrue(r.truncatedTail)
        assertEquals(0, r.events.size)
    }

    @Test
    fun `bad middle line is skipped and counted`() {
        val text = enc(header, sample(t0 + 1000)) + "{\"k\":\"s\",\"t\":garbage}\n" + enc(sample(t0 + 3000))
        val r = JournalReplay.read(text.toByteArray())
        assertEquals(1, r.badLines)
        assertFalse(r.truncatedTail)
        assertEquals(listOf(1000L, 3000L), r.events.map { it.t })
    }

    @Test
    fun `gap line rebases the timeline after a reboot`() {
        // Ran for 10 s, killed; phone rebooted so elapsedRealtime restarted at 3 000; dark for 2 min.
        val text = enc(
            header,
            sample(t0 + 10_000),
            JournalLine.Gap(3_000, w0 + 130_000, wallGapMs = 120_000),
            sample(4_000),
            JournalLine.Lap(5_000, w0 + 132_000, LapSource.button),
        )
        val r = JournalReplay.read(text.toByteArray())
        val gap = r.events[1]
        assertIs<RunEvent.Gap>(gap)
        assertEquals(10_000, gap.t)
        assertEquals(130_000, gap.endT)
        assertEquals(131_000, r.events[2].t)
        assertEquals(132_000, r.events[3].t)
        assertEquals(132_000, r.endT)
        assertEquals(0, r.clockJumps)
    }

    @Test
    fun `backwards clock by more than 5 s without a gap is clamped and counted`() {
        val text = enc(header, sample(t0 + 9000), sample(t0 + 1000), sample(t0 + 2000))
        val r = JournalReplay.read(text.toByteArray())
        assertEquals(1, r.clockJumps)
        assertEquals(0, r.outOfOrder)
        assertEquals(listOf(9000L, 9000L, 10_000L), r.events.map { it.t })
    }

    @Test
    fun `a slightly late line (back-dated auto lap) is re-sorted, not re-based`() {
        val text = enc(
            header,
            sample(t0 + 1000),
            sample(t0 + 2000),
            JournalLine.Lap(t0 + 1500, w0 + 2100, LapSource.auto), // written after the 2 s sample, stamped on the boundary
            sample(t0 + 3000),
        )
        val r = JournalReplay.read(text.toByteArray())
        assertEquals(0, r.clockJumps)
        assertEquals(1, r.outOfOrder)
        assertEquals(listOf(1000L, 1500L, 2000L, 3000L), r.events.map { it.t })
        assertIs<RunEvent.Lap>(r.events[1])
        assertEquals(3000, r.endT)
    }

    @Test
    fun `a journal from a newer schema is rejected as newer (never discardable)`() {
        val newer = JournalCodec.encode(header).replace("\"schema\":${JournalCodec.SCHEMA}", "\"schema\":${JournalCodec.SCHEMA + 1}")
        assertFailsWith<JournalReplay.NewerJournal> { JournalReplay.read((newer + "\n").toByteArray()) }
        val unknownMode = JournalCodec.encode(header).replace("\"mode\":\"intervals\"", "\"mode\":\"hyrox\"")
        assertFailsWith<JournalReplay.NewerJournal> { JournalReplay.read((unknownMode + "\n").toByteArray()) }
    }

    @Test
    fun `a schema-1 free journal replays as laps (plan 18-7 B1)`() {
        val v1 = """{"k":"hdr","schema":1,"t":$t0,"w":$w0,"id":"id1","device":"d","app":"a","tz":"UTC","mode":"free","preset":null,"units":"km"}"""
        val r = JournalReplay.read((v1 + "\n" + enc(sample(t0 + 1000))).toByteArray())
        assertEquals(RunMode.laps, r.header.mode)
        // Schema 2 keeps `free` as written.
        val v2 = JournalCodec.encode(header.copy(mode = RunMode.free, session = null))
        assertEquals(RunMode.free, JournalReplay.read((v2 + "\n").toByteArray()).header.mode)
    }

    @Test
    fun `negative wall gap is clamped to zero`() {
        val text = enc(header, sample(t0 + 1000), JournalLine.Gap(9_000, w0, wallGapMs = -5_000), sample(10_000))
        val r = JournalReplay.read(text.toByteArray())
        assertEquals(RunEvent.Gap(1000, 1000), r.events[1])
        assertEquals(2000, r.events[2].t)
    }

    @Test
    fun `paused state is derived from the tail`() {
        val paused = JournalReplay.read(enc(header, JournalLine.Pause(t0 + 1, w0)).toByteArray())
        assertTrue(paused.isPaused)
        val resumed = JournalReplay.read(enc(header, JournalLine.Pause(t0 + 1, w0), JournalLine.Resume(t0 + 2, w0)).toByteArray())
        assertFalse(resumed.isPaused)
    }

    @Test
    fun `no header is fatal`() {
        assertFailsWith<JournalReplay.NoHeader> { JournalReplay.read(enc(sample(t0)).toByteArray()) }
        assertFailsWith<JournalReplay.NoHeader> { JournalReplay.read(ByteArray(0)) }
        assertFailsWith<JournalReplay.NoHeader> { JournalReplay.read("{\"k\":\"hdr\",\"t\":1".toByteArray()) }
    }

    @Test
    fun `header only journal replays to an empty run`() {
        val r = JournalReplay.read(enc(header).toByteArray())
        assertEquals(0, r.events.size)
        assertEquals(0, r.endT)
        assertEquals(w0, r.lastWallMs)
    }
}
