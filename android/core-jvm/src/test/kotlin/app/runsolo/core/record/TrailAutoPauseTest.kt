package app.runsolo.core.record

import app.runsolo.core.gps.MovingDetector
import app.runsolo.core.model.RecorderState
import app.runsolo.core.model.RunMode
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The trail auto-pause profile: stationary is under 0.3 m/s for 10 s, a hike never pauses, jitter is ignored. */
class TrailAutoPauseTest {
    private class Feed(val d: MovingDetector = MovingDetector.forAutoPause(RunMode.trail)) {
        var t = 0L
        var dist = 0.0
        var lat = 0.0

        fun move(seconds: Int, mps: Double, speed: Double? = mps): Boolean {
            repeat(seconds) {
                t += 1000
                dist += mps
                lat += mps / 111_000.0
                d.update(t, dist, speed, lat, 0.0)
            }
            return d.moving
        }

        /** Standing with GPS jitter: positions wander within [radiusM], reported speed [speeds] cycled. */
        fun stand(seconds: Int, radiusM: Double = 1.5, speeds: List<Double?> = listOf(0.1)): Boolean {
            val lat0 = lat
            repeat(seconds) { i ->
                t += 1000
                val a = i * 2.1
                dist += 1.2
                d.update(t, dist, speeds[i % speeds.size], lat0 + radiusM * sin(a) / 111_000.0, radiusM * cos(a) / 111_000.0)
            }
            return d.moving
        }
    }

    @Test
    fun `the trail mode gets the trail profile, every other mode the road one`() {
        // 5 s of standing stops the road profile and not the trail one.
        for ((mode, stoppedAt5s) in listOf(RunMode.free to true, RunMode.laps to true, RunMode.trail to false)) {
            val f = Feed(MovingDetector.forAutoPause(mode))
            f.move(20, 3.0)
            assertEquals(stoppedAt5s, !f.stand(5), "$mode after 5 s")
        }
    }

    @Test
    fun `a power-hike at 2 km per h never pauses`() {
        val f = Feed()
        f.move(20, 1.5)
        val hike = 2.0 / 3.6
        repeat(300) { assertTrue(f.move(1, hike), "paused at second ${it + 1} of the hike") }
        // Slower still, a steep scramble at 0.4 m/s, is above standing.
        repeat(120) { assertTrue(f.move(1, 0.4), "paused on the scramble at ${it + 1}") }
    }

    @Test
    fun `standing 10 s pauses, 9 s does not`() {
        val f = Feed()
        f.move(20, 1.5)
        assertTrue(f.stand(9), "9 s is still moving")
        assertFalse(f.stand(1), "the 10th second stops it")
    }

    @Test
    fun `GPS jitter while standing neither resumes nor holds off the pause`() {
        val f = Feed()
        f.move(20, 1.5)
        // A lone Doppler blip at 0.35 m/s every few seconds must not restart the 10 s.
        assertFalse(f.stand(12, speeds = listOf(0.1, 0.1, 0.35, 0.1, 0.1, 0.1)), "blips do not hold off the pause")
        for (speed in listOf(0.2, null)) {
            val g = Feed()
            g.move(20, 1.5)
            g.stand(12, speeds = listOf(speed))
            assertFalse(g.d.moving, "stopped (speed=$speed)")
            assertFalse(g.stand(90, radiusM = 1.5, speeds = listOf(speed)), "jitter must not resume (speed=$speed)")
        }
    }

    @Test
    fun `it resumes on real movement, at a hike pace, not on one stride`() {
        val f = Feed()
        f.move(20, 1.5)
        f.stand(12)
        assertFalse(f.d.moving)
        assertFalse(f.move(1, 0.6))
        assertFalse(f.move(1, 0.6))
        assertTrue(f.move(1, 0.6), "three samples of hiking resume")
    }

    @Test
    fun `a steep scramble at 0_4 m per s resumes after a stop, a 0_2 m per s wobble does not`() {
        val f = Feed()
        f.move(20, 1.5)
        f.stand(12)
        assertFalse(f.d.moving)
        assertFalse(f.move(40, 0.2), "0.2 m/s is standing")
        assertFalse(f.move(2, 0.4))
        assertTrue(f.move(1, 0.4), "three samples of scrambling resume")
        repeat(60) { assertTrue(f.move(1, 0.4), "and it stays going at ${it + 1}") }
    }

    @Test
    fun `a trail run auto-pauses through the recorder like a free run`() {
        val c = RecorderCore(RunMode.trail, null).also { it.start(0) }
        c.tick(10_000, 15.0)
        assertTrue(c.autoPauseAllowed())
        assertTrue(c.autoPause(12_000))
        assertEquals(RecorderState.paused, c.state)
        assertTrue(c.autoPaused)
        assertTrue(c.autoResume(20_000))
        assertEquals(RecorderState.recording, c.state)
    }

    @Test
    fun `trail takes LAP input never, and no session`() {
        assertFalse(RunMode.trail.lapInput)
        assertFalse(RunMode.trail.followsSteps)
        assertFalse(RunMode.trail.volumeKeyLapsDefault)
        assertEquals(null, RecorderCore.unsupported(RunMode.trail, null))
        assertTrue(RecorderCore.unsupported(RunMode.trail, app.runsolo.core.model.SessionSpec.norwegian4x4()) != null)
    }
}
