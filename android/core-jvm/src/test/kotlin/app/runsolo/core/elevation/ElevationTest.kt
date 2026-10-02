package app.runsolo.core.elevation

import java.util.Random
import kotlin.math.pow
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ElevationTest {
    /** Pressure at [altM] on a standard day: the inverse of the fuser's formula. */
    private fun hpaAt(altM: Double): Double = 1013.25 * (1.0 - altM / 44_330.77).pow(1.0 / 0.190263)

    private class Result(val est: List<Double>, val ascentM: Double, val descentM: Double, val source: ElevSource?)

    /**
     * Runs a 1 Hz track through the fuser and a climb tracker at the source's own threshold.
     * [truth] is the real elevation at second i; the barometer reads it plus [baroDriftHpaPerHour]
     * and a little noise (null = no barometer); GPS reads it plus [gpsNoiseM] gaussian.
     */
    private fun run(
        seconds: Int,
        truth: (Int) -> Double,
        baro: Boolean,
        baroDriftHpaPerHour: Double = 0.0,
        baroNoiseHpa: Double = 0.06,
        gpsNoiseM: Double = 4.0,
        seed: Long = 7,
    ): Result {
        val rnd = Random(seed)
        val fuser = ElevationFuser()
        val est = ArrayList<Double>()
        val estimates = ArrayList<Double>()
        for (i in 0 until seconds) {
            val h = truth(i)
            val hpa = if (baro) hpaAt(h) + baroDriftHpaPerHour * i / 3600.0 + rnd.nextGaussian() * baroNoiseHpa else null
            val alt = h + rnd.nextGaussian() * gpsNoiseM
            fuser.offer(1_000L * i, hpa, alt, 8.0)?.let { est.add(it); estimates.add(it) }
        }
        val src = fuser.source
        val tracker = ClimbTracker(if (src == null) 3.0 else ClimbTracker.thresholdFor(src))
        for (e in est) tracker.offer(e)
        return Result(est, tracker.ascentM, tracker.descentM, src)
    }

    @Test
    fun `a flat run with barometer drift and noisy GPS stays level`() {
        // One hour; the pressure drifts 1 hPa (about 8 m of weather); GPS is +/-4 m of noise.
        val r = run(3_600, { 100.0 }, baro = true, baroDriftHpaPerHour = 1.0)
        assertEquals(ElevSource.baro, r.source)
        assertTrue(r.est.all { it in 94.0..106.0 }, "level drifted: ${r.est.minOrNull()}..${r.est.maxOrNull()}")
        assertTrue(r.ascentM + r.descentM <= 6.0, "weather and noise booked ${r.ascentM} up ${r.descentM} down")
    }

    @Test
    fun `the anchor follows a weather change without reading as a hill`() {
        // 2 hPa of drift in an hour, flat ground: the level moves toward GPS (which is right), the
        // climb totals stay under two thresholds.
        val r = run(3_600, { 40.0 }, baro = true, baroDriftHpaPerHour = 2.0, gpsNoiseM = 2.0)
        assertTrue(r.ascentM + r.descentM <= 9.0, "booked ${r.ascentM} up ${r.descentM} down")
        assertTrue(r.est.last() in 34.0..46.0, "ended at ${r.est.last()}")
    }

    @Test
    fun `a known climb is counted from the barometer`() {
        // A minute flat while the level is anchored, then 100 m up over 10 minutes, 100 s flat, 40 m down.
        val truth = { i: Int ->
            when {
                i < 60 -> 20.0
                i < 660 -> 20.0 + 100.0 * (i - 60) / 600
                i < 760 -> 120.0
                else -> 120.0 - 40.0 * (i - 760) / 300
            }
        }
        val r = run(1_060, truth, baro = true)
        assertEquals(100.0, r.ascentM, 5.0)
        assertEquals(40.0, r.descentM, 5.0)
    }

    @Test
    fun `hysteresis ignores a noisy flat`() {
        // +/-1.2 m of wobble, 0.1 Hz: nothing may be booked.
        val t = ClimbTracker(ClimbTracker.BARO_THRESHOLD_M)
        for (i in 0 until 3_600) t.offer(80.0 + 1.2 * sin(i * 0.63))
        assertEquals(0.0, t.ascentM)
        assertEquals(0.0, t.descentM)
    }

    @Test
    fun `hysteresis books a step once it is past the threshold`() {
        val t = ClimbTracker(3.0)
        for (e in listOf(0.0, 1.0, 2.9, 3.0, 4.0, 6.5, 6.0, 3.4, 3.0)) t.offer(e)
        // 0 -> 3.0 books 3.0; 3.0 -> 6.5 books 3.5; 6.5 -> 3.4 is -3.1: book it; 3.4 -> 3.0 not enough.
        assertEquals(6.5, t.ascentM, 1e-9)
        assertEquals(3.1, t.descentM, 1e-9)
    }

    @Test
    fun `held while paused books nothing`() {
        val t = ClimbTracker(3.0)
        t.offer(10.0)
        t.hold(50.0)
        t.offer(51.0)
        assertEquals(0.0, t.ascentM)
    }

    @Test
    fun `no barometer falls back to smoothed GPS and says so`() {
        // Flat but noisy first: GPS noise alone must not book climb under the larger GPS threshold.
        val flat = run(1_800, { 50.0 }, baro = false, gpsNoiseM = 4.0)
        assertEquals(ElevSource.gps, flat.source)
        assertEquals(0.0, flat.ascentM, 0.001)
        // Then a real 60 m climb: counted, roughly.
        val climb = run(900, { i -> 50.0 + 60.0 * i / 900 }, baro = false, gpsNoiseM = 4.0)
        assertEquals(ElevSource.gps, climb.source)
        assertTrue(climb.ascentM in 40.0..75.0, "got ${climb.ascentM}")
    }

    @Test
    fun `a barometer with no GPS fix has no level yet`() {
        val f = ElevationFuser()
        assertNull(f.offer(0, hpaAt(100.0), null, null))
        assertNull(f.source)
        // The mean of the first twenty usable fixes sets the level; the barometer carries it from there.
        var level: Double? = null
        for (i in 1..25) level = f.offer(1_000L * i, hpaAt(100.0), 103.0, 6.0)
        assertEquals(103.0, level!!, 0.5)
        assertEquals(ElevSource.baro, f.source)
        // Ten metres up (a few seconds for the low-pass to settle).
        var up = level
        for (i in 26..40) up = f.offer(1_000L * i, hpaAt(110.0), null, null)
        assertEquals(113.0, up!!, 1.0)
    }

    @Test
    fun `an unusable fix does not anchor the level`() {
        val f = ElevationFuser()
        assertNull(f.offer(0, hpaAt(100.0), 400.0, 80.0)) // accuracy 80 m: too poor
    }

    @Test
    fun `the barometer dropping out hands over to GPS without a jump`() {
        val f = ElevationFuser()
        var last: Double? = null
        for (i in 0 until 60) last = f.offer(1_000L * i, hpaAt(100.0), 100.0, 6.0)
        for (i in 60 until 120) last = f.offer(1_000L * i, null, 100.0, 6.0)
        assertEquals(100.0, last!!, 1.0)
        for (i in 120 until 180) last = f.offer(1_000L * i, hpaAt(100.0), 100.0, 6.0)
        assertEquals(100.0, last!!, 1.0)
    }

    @Test
    fun `grade needs a full window then reads the slope`() {
        val g = GradeWindow(50.0)
        var last: Double? = null
        var firstGradeAt = -1.0
        var d = 0.0
        while (d <= 300.0) {
            last = g.offer(d, 0.05 * d)
            if (last != null && firstGradeAt < 0) firstGradeAt = d
            d += 5.0
        }
        assertEquals(50.0, firstGradeAt, 1e-9)
        assertNotNull(last)
        assertEquals(0.05, last!!, 1e-9)
    }

    @Test
    fun `grade is clamped and negative downhill`() {
        val g = GradeWindow(10.0)
        g.offer(0.0, 0.0)
        assertEquals(GradeWindow.MAX_GRADE, g.offer(10.0, 100.0)!!, 1e-9)
        val h = GradeWindow(50.0)
        h.offer(0.0, 20.0)
        assertEquals(-0.1, h.offer(50.0, 15.0)!!, 1e-9)
    }

    @Test
    fun `live elevation books climb while moving and holds while paused`() {
        val live = LiveElevation()
        var d = 0.0
        for (i in 0 until 120) {
            d += 3.0
            live.offer(1_000L * i, hpaAt(10.0 + 0.1 * i), 10.0 + 0.1 * i, 6.0, d, paused = false)
        }
        val up = live.ascentM!!
        assertTrue(up in 8.0..13.0, "got $up")
        assertNotNull(live.grade)
        assertEquals(10.0 / 360.0, live.grade!!, 0.01) // 0.1 m/s over 3 m/s
        // A walk up a staircase while paused is not part of the run.
        for (i in 120 until 180) live.offer(1_000L * i, hpaAt(30.0 + 0.1 * i), 30.0 + 0.1 * i, 6.0, d, paused = true)
        assertEquals(up, live.ascentM!!, 1e-9)
    }

    @Test
    fun `pressure join picks the nearest reading within range`() {
        val j = PressureJoin(maxAgeMs = 3_000)
        j.offer(PressureReading(1_000, 1000.0))
        j.offer(PressureReading(2_000, 1001.0))
        assertEquals(1001.0, j.hpaAt(2_400))
        assertEquals(1000.0, j.hpaAt(1_400))
        assertNull(j.hpaAt(9_000))
    }
}
