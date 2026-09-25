package app.runsolo.core.run

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.json.list
import app.runsolo.core.model.LapKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.Preset
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.replay.TraceFixture
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RunFileTest {
    private val t0 = 50_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.fourByFour, Preset.DEFAULT_4X4, Units.km)

    /** 20 s at 3 m/s, lap, 20 s at 3 m/s, pause 5 s, 10 s more. */
    private fun journal(): ByteArray {
        val fixes = TraceFixture.straightLine(listOf(50 to 3.0), startT = t0)
        val sb = StringBuilder(JournalCodec.encode(header)).append('\n')
        for (f in fixes) {
            val runT = f.t - t0
            if (runT == 20_000L) sb.append(JournalCodec.encode(JournalLine.Lap(f.t, w0 + runT, LapSource.button))).append('\n')
            if (runT == 40_000L) sb.append(JournalCodec.encode(JournalLine.Pause(f.t, w0 + runT))).append('\n')
            if (runT == 45_000L) sb.append(JournalCodec.encode(JournalLine.Resume(f.t, w0 + runT))).append('\n')
            val hr = if (runT in 30_000..35_000) 150 else null
            sb.append(JournalCodec.encode(JournalLine.Sample(f.t, w0 + runT, f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, hr))).append('\n')
        }
        return sb.toString().toByteArray()
    }

    @Test
    fun `laps are segments between markers with cumulative distance`() {
        val r = JournalReplay.read(journal())
        val f = RunFile.fromReplay(r, w0 + 50_000)
        assertEquals(2, f.laps.size)
        assertEquals(RunFile.Lap(0, 0, 20_000, 0.0, f.laps[0].d1, LapKind.manual), f.laps[0])
        assertEquals(20_000, f.laps[1].t0)
        assertEquals(50_000, f.laps[1].t1)
        assertEquals(LapKind.manual, f.laps[1].kind)
        assertEquals(60.0, f.laps[0].d1, 0.5) // 20 steps; the candidate at t=0 is confirmed by t=1, so that step counts
        assertEquals(132.0, f.laps[1].d1, 1.0) // 5 paused steps excluded, one step re-anchors after resume
        assertEquals(f.laps[0].d1, f.laps[1].d0)
        assertEquals(1, f.pauses.size)
        assertEquals(listOf(40_000L, 45_000L), f.pauses[0].asList())
        assertEquals(0, f.gaps.size)
        assertEquals(51, f.samples.size)
        assertEquals(w0, f.startEpochMs)
        assertEquals(50_000, f.elapsedMs)
    }

    @Test
    fun `gzip json round trip matches schema v2`() {
        val f = RunFile.fromReplay(JournalReplay.read(journal()), w0 + 50_000)
        val m = RunFile.readJson(f.toGzipBytes())
        assertEquals(2L, m["schema"])
        assertEquals("id1", m["id"])
        assertEquals("fourByFour", m["mode"])
        assertEquals("km", m["units"])
        assertEquals("2023-11-14T22:13:20Z", m["start"])
        assertEquals(mapOf("reps" to 4L, "workSeconds" to 240L, "recoverySeconds" to 180L), m["preset"])
        val laps = m.list("laps")
        assertEquals(2, laps.size)
        val lap0 = laps[0] as Map<*, *>
        assertEquals(setOf("i", "t0", "t1", "d0", "d1", "kind"), lap0.keys)
        val samples = m.list("samples")
        assertEquals(51, samples.size)
        val s30 = samples[30] as List<*>
        assertEquals(8, s30.size)
        assertEquals(30_000L, s30[0])
        assertEquals(150L, s30[7])
        assertNull((samples[0] as List<*>)[7])
        assertEquals(listOf(listOf(40_000L, 45_000L)), m["pauses"])
        assertEquals(emptyList<Any>(), m["gaps"])
    }

    @Test
    fun `an auto lap marker gives an auto lap and an open pause closes at the end`() {
        val text = listOf(
            header,
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Lap(t0 + 2000, w0 + 2000, LapSource.auto),
            JournalLine.Pause(t0 + 3000, w0 + 3000),
            JournalLine.Sample(t0 + 4000, w0 + 4000, 0.0, 0.0, null, 5.0, null, null),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val f = RunFile.fromReplay(JournalReplay.read(text.toByteArray()), w0 + 4000)
        assertEquals(LapKind.auto, f.laps[0].kind)
        assertEquals(LapKind.manual, f.laps[1].kind)
        assertEquals(listOf(3000L, 4000L), f.pauses.single().asList())
        assertTrue(f.distanceM == 0.0)
    }

    @Test
    fun `samples are strictly increasing in t and hr is never 0`() {
        val text = listOf(
            header,
            JournalLine.Sample(t0 + 9000, w0 + 9000, 0.0, 0.0, null, 5.0, null, 0),
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, 150), // clock went back 8 s → clamped to 9000 → dropped
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null), // duplicate t → dropped
            JournalLine.Sample(t0 + 2000, w0 + 2000, 0.0, 0.0, null, 5.0, null, 151), // 1 s after the clamp point
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val f = RunFile.fromReplay(JournalReplay.read(text.toByteArray()), w0 + 6000)
        assertEquals(listOf(9000L, 10_000L), f.samples.map { it.t })
        assertEquals(listOf(null, 151), f.samples.map { it.hr })
    }

    @Test
    fun `no-fix ticks keep time and HR and repeat the distance`() {
        val fixes = TraceFixture.straightLine(listOf(3 to 3.0), startT = t0)
        val lines = ArrayList<JournalLine>()
        lines.add(header.copy(mode = RunMode.free, preset = null))
        for (f in fixes) lines.add(JournalLine.Sample(f.t, w0 + (f.t - t0), f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, 140))
        // Tunnel: 3 s without a fix, strap still reporting.
        for (s in 4..6) lines.add(JournalLine.Sample.noFix(t0 + s * 1000L, w0 + s * 1000L, 150 + s))
        lines.add(JournalLine.Sample(t0 + 7000, w0 + 7000, fixes.last().lat, fixes.last().lon, null, 5.0, null, null))
        val f = RunFile.fromReplay(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), w0 + 7000)
        assertEquals(8, f.samples.size)
        assertEquals(5, f.fixCount)
        assertEquals(listOf(154, 155, 156), f.samples.subList(4, 7).map { it.hr })
        assertTrue(f.samples.subList(4, 7).all { !it.hasFix && it.lat == null && it.accuracyM == null })
        assertEquals(9.0, f.samples[3].distM, 0.1)
        assertEquals(f.samples[3].distM, f.samples[6].distM, "distance repeats through the dropout")
        assertEquals(f.samples[3].distM, f.samples[7].distM, 0.01)
        val row = (RunFile.readJson(f.toGzipBytes()).list("samples")[5] as List<*>)
        assertEquals(listOf(5000L, null, null, null, null, null, row[6], 155L), row)
    }

    @Test
    fun `treadmill run - no fixes at all, HR present, zero distance`() {
        val lines = ArrayList<JournalLine>()
        lines.add(header.copy(mode = RunMode.free, preset = null))
        for (s in 1..5) lines.add(JournalLine.Sample.noFix(t0 + s * 1000L, w0 + s * 1000L, 130 + s))
        val f = RunFile.fromReplay(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), w0 + 5000)
        assertEquals(5, f.samples.size)
        assertEquals(0, f.fixCount)
        assertEquals(0.0, f.distanceM)
        assertEquals(135, f.samples.last().hr)
    }

    @Test
    fun `movement while paused is journaled but not measured`() {
        // 30 s @3 m/s, pause, 20 s walking @1.5 m/s (30 m), resume, 30 s @3 m/s.
        val fixes = TraceFixture.straightLine(listOf(30 to 3.0, 20 to 1.5, 30 to 3.0), startT = t0)
        val lines = ArrayList<JournalLine>()
        lines.add(header.copy(mode = RunMode.free, preset = null))
        for (f in fixes) {
            val s = (f.t - t0) / 1000
            if (s == 30L) lines.add(JournalLine.Pause(f.t, w0 + s * 1000))
            if (s == 50L) lines.add(JournalLine.Resume(f.t, w0 + s * 1000))
            lines.add(JournalLine.Sample(f.t, w0 + s * 1000, f.lat, f.lon, f.altM, f.accuracyM, f.speedMps, null))
        }
        val f = RunFile.fromReplay(JournalReplay.read(lines.joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()), w0 + 80_000)
        assertEquals(81, f.samples.size, "paused samples are still in the file")
        val atPause = f.samples.first { it.t == 30_000L }.distM
        val atResume = f.samples.first { it.t == 50_000L }.distM
        assertEquals(atPause, atResume, "distance frozen through the pause")
        // 29 steps before (anchor consumes one, sample 30 is already paused) + 30 after (50 re-anchors, 51..80 count) = 177 m; the 30 m walked never.
        assertEquals(29 * 3.0 + 30 * 3.0, f.distanceM, 1.0)
    }

    @Test
    fun `gap span is carried into gaps`() {
        val text = listOf(
            header,
            JournalLine.Sample(t0 + 1000, w0 + 1000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.Gap(10, w0 + 61_000, 60_000),
            JournalLine.Sample(1010, w0 + 62_000, 0.0, 0.0, null, 5.0, null, null),
        ).joinToString("") { JournalCodec.encode(it) + "\n" }
        val f = RunFile.fromReplay(JournalReplay.read(text.toByteArray()), w0 + 62_000)
        assertEquals(listOf(1000L, 61_000L), f.gaps.single().asList())
        assertEquals(62_000, f.samples.last().t)
    }
}
