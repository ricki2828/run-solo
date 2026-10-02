package app.runsolo.core.record

import app.runsolo.core.gps.MovingDetector
import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.journal.JournalReplay
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LocationFix
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import app.runsolo.core.record.RecorderCore.LapDecision
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Auto-pause: the detector's stop/go rule, where the core allows it, and what it does to the clock and laps. */
class AutoPauseTest {
    private val mPerDegLat = 111_000.0

    /** Feeds the auto-pause detector 1 Hz samples; returns the moving flag after each. */
    private class Feed(val d: MovingDetector = MovingDetector.forAutoPause()) {
        var t = 0L
        var dist = 0.0
        var lat = 0.0

        /** One second of running at [mps], reporting [speed] (null = no Doppler speed on the fix). */
        fun run(seconds: Int, mps: Double, speed: Double? = mps): Boolean {
            repeat(seconds) {
                t += 1000
                dist += mps
                lat += mps / 111_000.0
                d.update(t, dist, speed, lat, 0.0)
            }
            return d.moving
        }

        /** Standing: positions wander within [radiusM] of where the runner stands, path length grows. */
        fun stand(seconds: Int, radiusM: Double = 1.5, speed: Double? = 0.1): Boolean {
            val lat0 = lat
            repeat(seconds) { i ->
                t += 1000
                val a = i * 2.1
                val dx = radiusM * cos(a)
                val dy = radiusM * sin(a)
                dist += 1.2 // jitter adds path length
                d.update(t, dist, speed, lat0 + dy / 111_000.0, dx / 111_000.0)
            }
            return d.moving
        }
    }

    @Test
    fun `detector - stops after 4_5 s of standing, not before`() {
        val f = Feed()
        assertTrue(f.run(20, 3.0))
        assertTrue(f.stand(4), "4 s at a light is still moving")
        assertFalse(f.stand(1), "the 5th second stops it")
    }

    @Test
    fun `detector - restarts only after three strides, one is a wobble`() {
        val f = Feed()
        f.run(20, 3.0)
        f.stand(10)
        assertFalse(f.run(1, 3.0))
        assertFalse(f.run(1, 3.0))
        assertTrue(f.run(1, 3.0))
    }

    @Test
    fun `detector - GPS jitter while standing neither resumes nor starts, with or without a reported speed`() {
        for (speed in listOf(0.2, null)) {
            val f = Feed()
            f.run(20, 3.0)
            f.stand(10, speed = speed)
            assertFalse(f.d.moving, "stopped (speed=$speed)")
            // 60 s of jitter on a 1.5 m circle: path length 72 m, speed estimates of 1.2 m/s each second.
            assertFalse(f.stand(60, radiusM = 1.5, speed = speed), "jitter must not resume (speed=$speed)")
        }
    }

    @Test
    fun `detector - a dropout is not a stop`() {
        val f = Feed()
        f.run(20, 3.0)
        f.t += 12_000 // a tunnel: no samples at all
        f.dist += 36.0
        f.d.update(f.t, f.dist, 3.0, f.lat, 0.0)
        assertTrue(f.run(2, 3.0), "still moving after a 12 s gap")
    }

    @Test
    fun `detector - walking on to the next light keeps it moving`() {
        val f = Feed()
        f.run(10, 3.0)
        assertTrue(f.run(30, 1.2), "a 1.2 m/s walk is above the stall speed")
    }

    // ---- where it applies ----

    private fun started(mode: RunMode, spec: SessionSpec?): RecorderCore =
        RecorderCore(mode, spec).also { it.start(0) }

    @Test
    fun `free and laps runs auto-pause, goal runs too`() {
        for (c in listOf(started(RunMode.free, null), started(RunMode.laps, null), started(RunMode.laps, SessionSpec.FARTLEK), started(RunMode.intervals, SessionSpec.goalDistance(10_000, "10 K")), started(RunMode.intervals, SessionSpec.goalTime(1_800, "30 min")))) {
            c.tick(10_000, 30.0)
            assertTrue(c.autoPause(12_000), "${c.mode} ${c.spec?.templateId}")
            assertEquals(RecorderState.paused, c.state)
            assertTrue(c.autoPaused)
        }
    }

    @Test
    fun `a 4x4 never auto-pauses in a rep or a recovery, and may in the warm-up and cool-down`() {
        val c = started(RunMode.intervals, SessionSpec.norwegian4x4())
        assertEquals(Phase.warmup, c.phase)
        assertTrue(c.autoPauseAllowed(), "warm-up")
        c.lap(LapSource.button, 1_000)
        assertEquals(Phase.work, c.phase)
        assertFalse(c.autoPauseAllowed(), "rep 1")
        assertFalse(c.autoPause(5_000))
        assertEquals(RecorderState.recording, c.state)
        // Through every rep and recovery by their own clock; auto-pause must never act in any.
        var t = 1_000L
        var sawCooldown = false
        while (t < 3_000_000L && !sawCooldown) {
            t += 1_000
            c.tick(t, (t / 1000) * 3.0)
            if (c.phase == Phase.work || c.phase == Phase.recovery) assertFalse(c.autoPauseAllowed(), "${c.phase} at $t")
            sawCooldown = c.phase == Phase.cooldown
        }
        assertTrue(sawCooldown)
        assertTrue(c.autoPauseAllowed(), "cool-down")
    }

    @Test
    fun `the Cooper test never auto-pauses, warm-up included`() {
        val c = started(RunMode.cooper, SessionSpec.COOPER)
        assertFalse(c.autoPauseAllowed())
        assertFalse(c.autoPause(5_000))
        c.startReps(6_000)
        for (t in 7_000L..720_000L step 1_000) {
            c.tick(t, (t / 1000) * 3.0)
            assertFalse(c.autoPause(t), "Cooper at $t")
        }
        assertEquals(RecorderState.recording, c.state)
    }

    @Test
    fun `an event or any unknown template never auto-pauses`() {
        val event = SessionSpec.norwegian4x4().copy(templateId = SessionSpec.EVENT_ID)
        val c = started(RunMode.intervals, event)
        assertFalse(c.autoPauseAllowed())
        c.lap(LapSource.button, 1_000)
        assertFalse(c.autoPauseAllowed())
    }

    // ---- what it does ----

    @Test
    fun `auto-pause stops the active clock, elapsed keeps running, resume restores it`() {
        val c = started(RunMode.free, null)
        c.tick(60_000, 180.0)
        assertTrue(c.autoPause(61_000))
        assertEquals(61_000L, c.pausedAtElapsedMs)
        c.tick(91_000, 181.0)
        val st = c.status(91_000)
        assertEquals(91_000L, st.elapsedMs)
        assertEquals(61_000L, st.activeMs)
        assertTrue(c.autoResume(92_000))
        assertFalse(c.autoPaused)
        assertEquals(RecorderState.recording, c.state)
        assertEquals(61_000L, c.status(92_000).activeMs)
        assertEquals(66_000L, c.status(97_000).activeMs)
        assertEquals(97_000L, c.status(97_000).elapsedMs)
    }

    @Test
    fun `a manual LAP during an auto-pause works in a Laps run`() {
        val c = started(RunMode.laps, null)
        c.tick(60_000, 180.0)
        c.autoPause(61_000)
        val (decision, out) = c.lap(LapSource.button, 70_000)
        assertEquals(LapDecision.accepted, decision)
        assertEquals(1, out.size)
        assertEquals(1, c.lapCount)
        assertEquals(RecorderState.paused, c.state, "a lap does not resume a Laps run")
        assertTrue(c.autoPaused)
    }

    @Test
    fun `a manual pause is not an auto-pause and still ignores laps`() {
        val c = started(RunMode.laps, null)
        c.tick(60_000, 180.0)
        c.pause(61_000)
        assertFalse(c.autoPaused)
        assertEquals(LapDecision.ignoredPaused, c.lap(LapSource.button, 70_000).first)
        assertFalse(c.autoPause(65_000), "already paused")
        assertFalse(c.autoResume(66_000), "an auto edge never ends the runner's pause")
        assertEquals(RecorderState.paused, c.state)
    }

    @Test
    fun `PAUSE on top of an auto-pause makes it the runner's, still beginning at the auto-pause`() {
        val c = started(RunMode.free, null)
        c.tick(60_000, 180.0)
        c.autoPause(61_000)
        c.pause(80_000)
        assertFalse(c.autoPaused)
        assertEquals(RecorderState.paused, c.state)
        assertEquals(61_000L, c.pausedAtElapsedMs)
        assertFalse(c.autoResume(90_000), "the runner resumes this one")
        c.resume(95_000)
        assertEquals(61_000L, c.status(95_000).activeMs)
    }

    @Test
    fun `no auto-lap fires on stationary drift, the step ends once the runner is moving`() {
        val c = started(RunMode.intervals, SessionSpec.goalDistance(1_000, "1 K"))
        assertEquals(Phase.work, c.phase)
        c.tick(10_000, 900.0)
        assertTrue(c.autoPause(11_000))
        // The phone drifts 150 m over a long wait at the lights: past the 1 km target on paper.
        val driftOut = (12_000L..60_000L step 1_000).flatMap { c.tick(it, 1_050.0) }
        assertEquals(emptyList(), driftOut)
        assertEquals(Phase.work, c.phase)
        c.autoResume(61_000)
        val after = c.tick(62_000, 1_053.0)
        assertTrue(after.isNotEmpty(), "the goal step ends on the first tick that is moving again")
    }

    @Test
    fun `distance and goal totals do not grow while standing with GPS jitter, and resuming loses no ground`() {
        val ticker = SampleTicker(wall = { 0L })
        val core = started(RunMode.intervals, SessionSpec.goalDistance(1_000, "1 K"))
        val mPerDeg = 111_320.0
        fun fix(t: Long, eastM: Double, northM: Double = 0.0, speed: Double = 3.0) = LocationFix(t, northM / mPerDeg, eastM / mPerDeg, null, 5.0, speed)
        fun second(t: Long, f: LocationFix): List<RecorderCore.Output> {
            ticker.onFix(f)
            ticker.tick(t)
            return core.tick(t, ticker.distanceM)
        }
        for (s in 1..20) second(s * 1000L, fix(s * 1000L, 3.0 * s))
        val before = ticker.distanceM
        val remainingBefore = core.status(20_000).stepRemainingM!!
        assertTrue(core.autoPause(21_000))
        ticker.onAutoPause()
        // 30 s standing: the fix wanders on a 1.2 m circle, 2.3 m between fixes, reporting 0.1 m/s.
        var out = emptyList<RecorderCore.Output>()
        for (s in 22..51) {
            val a = s * 2.1
            out = out + second(s * 1000L, fix(s * 1000L, 60.0 + 1.2 * cos(a), 1.2 * sin(a), 0.1))
        }
        assertEquals(before, ticker.distanceM, 0.0, "the filter's distance is frozen")
        assertEquals(before, core.distanceM, 0.0, "so is the core's")
        assertEquals(remainingBefore, core.status(51_000).stepRemainingM!!, 0.0, "and the goal's metres to go")
        assertEquals(emptyList(), out)
        // Moving again: no re-anchor, so the first fix steps from where the runner stopped.
        assertTrue(core.autoResume(52_000))
        ticker.onAutoResume()
        for (s in 53..55) second(s * 1000L, fix(s * 1000L, 60.0 + 3.0 * (s - 52)))
        assertEquals(before + 9.0, ticker.distanceM, 2.5, "about 9 m run since the stop, none of the jitter")
        assertEquals(RecorderState.recording, core.state)
    }

    @Test
    fun `a LAP that starts a rep ends an auto-pause in the warm-up`() {
        val c = started(RunMode.intervals, SessionSpec.norwegian4x4())
        c.tick(30_000, 60.0)
        assertTrue(c.autoPause(31_000))
        val (decision, _) = c.startReps(40_000)
        assertEquals(LapDecision.accepted, decision)
        assertEquals(Phase.work, c.phase)
        assertFalse(c.autoPaused)
        assertEquals(RecorderState.recording, c.state)
    }

    // ---- kill and restore ----

    private fun journal(vararg lines: JournalLine): ByteArray =
        (listOf<JournalLine>(JournalLine.Header(0, 1_000, "p", "d", "a", "UTC", RunMode.laps, null, Units.km)) + lines)
            .joinToString("") { JournalCodec.encode(it) + "\n" }.toByteArray()

    @Test
    fun `restore after a kill in an auto-pause comes back auto-paused, a manual lap included`() {
        val bytes = journal(
            JournalLine.Sample(30_000, 31_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.AutoPause(40_000, 41_000),
            JournalLine.Lap(45_000, 46_000, LapSource.button),
            JournalLine.Sample(55_000, 56_000, 0.0, 0.0, null, 5.0, null, null),
        )
        val replay = JournalReplay.read(bytes)
        assertTrue(replay.isPaused)
        val restored = RecorderCore.restore(replay, nowT = 9_000_000)
        assertEquals(RecorderState.paused, restored.state)
        assertTrue(restored.autoPaused)
        assertEquals(1, restored.lapCount, "a lap pressed during the auto-pause is kept")
        assertEquals(40_000L, restored.pausedAtElapsedMs)
    }

    @Test
    fun `restore after aresume is recording with the pause out of the active clock`() {
        val bytes = journal(
            JournalLine.Sample(30_000, 31_000, 0.0, 0.0, null, 5.0, null, null),
            JournalLine.AutoPause(40_000, 41_000),
            JournalLine.AutoResume(70_000, 71_000),
            JournalLine.Sample(80_000, 81_000, 0.0, 0.0, null, 5.0, null, null),
        )
        val replay = JournalReplay.read(bytes)
        assertFalse(replay.isPaused)
        val restored = RecorderCore.restore(replay, nowT = 9_000_000)
        assertEquals(RecorderState.recording, restored.state)
        assertFalse(restored.autoPaused)
        assertEquals(50_000L, restored.status(9_000_000).activeMs)
    }
}
