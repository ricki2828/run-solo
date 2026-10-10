package app.runsolo.core.live

import app.runsolo.core.model.RunMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CheckInTest {
    private val zones = listOf(120.0, 140.0, 160.0, 175.0)
    private val all = CheckInPlan(CheckInMetric.DEFAULT, zones)

    @Test
    fun `distance time and pace alone are the legacy km split word for word`() {
        val plan = CheckInPlan(setOf(CheckInMetric.distance, CheckInMetric.time, CheckInMetric.pace))
        for ((km, active, split) in listOf(Triple(3, 920_000L, 307_000L), Triple(12, 3_840_000L, 320_000L), Triple(1, 300_000L, null))) {
            val s = CheckInWords.build(plan, km, active, split, CheckInSnapshot(hrZone = 3, climbM = 200.0))
            assertEquals(LiveWords.kmSplit(km, active, split), s.base)
            assertNull(s.tail)
        }
    }

    @Test
    fun `easy road run says the split then zone and average`() {
        val snap = CheckInSnapshot(avgPaceSecPerKm = 310.0, kmTrueFactor = 1.0, hrZone = 2, hrZoneMs = 12 * 60_000L, climbM = 6.0, heightVsStartM = 2.0)
        val s = CheckInWords.build(all, 3, 920_000, 307_000, snap)
        assertEquals("3 k, 15 minutes 20, pace 5:07.", s.base)
        assertEquals("Zone 2 for 12 minutes. Average 5:10.", s.tail)
    }

    @Test
    fun `hilly trail says height climb and true pace`() {
        val snap = CheckInSnapshot(avgPaceSecPerKm = 560.0, kmTrueFactor = 0.82, hrZone = 3, hrZoneMs = 22 * 60_000L, climbM = 212.0, heightVsStartM = 83.0)
        val s = CheckInWords.build(all, 4, 2_290_000, 570_000, snap)
        assertEquals("4 k, 38 minutes 10, pace 9:30.", s.base)
        assertEquals("Zone 3 for 22 minutes. 85 metres above the start. Climbed 210 metres. True pace 7:47. Average 9:20.", s.tail)
        assertTrue(CueComposer.words(s.tail) <= CheckInWords.MAX_EXTRA_WORDS)
    }

    @Test
    fun `no strap and no barometer skip those metrics`() {
        val s = CheckInWords.build(all, 2, 600_000, 300_000, CheckInSnapshot(avgPaceSecPerKm = 300.0))
        assertEquals("2 k, 10 minutes, pace 5:00.", s.base)
        assertEquals("Average 5:00.", s.tail)
    }

    @Test
    fun `below the start is said and near level is not`() {
        val below = CheckInWords.build(all, 2, 600_000, 300_000, CheckInSnapshot(heightVsStartM = -41.0))
        assertEquals("40 metres below the start.", below.tail)
        val level = CheckInWords.build(all, 2, 600_000, 300_000, CheckInSnapshot(heightVsStartM = 3.0, climbM = 10.0))
        assertNull(level.tail)
    }

    @Test
    fun `retrace phrase leads the extras`() {
        val snap = CheckInSnapshot(hrZone = 2, backToStartKm = 2.4, climbAheadM = 62.0)
        val s = CheckInWords.build(all, 5, 1_500_000, 300_000, snap)
        assertEquals("2 point 4 k back to the start, 60 metres of climb ahead. Zone 2.", s.tail)
    }

    @Test
    fun `a long line drops the least important metrics and never the first`() {
        val snap = CheckInSnapshot(
            avgPaceSecPerKm = 560.0, kmTrueFactor = 0.8, hrZone = 3, hrZoneMs = 90 * 60_000L, climbM = 400.0, heightVsStartM = -120.0,
            backToStartKm = 12.5, climbAheadM = 300.0,
        )
        val s = CheckInWords.build(all, 9, 5_000_000, 570_000, snap)
        assertTrue(s.tail!!.startsWith("12 point 5 k back to the start"))
        assertTrue(CueComposer.words(s.tail) <= CheckInWords.MAX_EXTRA_WORDS)
    }

    @Test
    fun `nothing chosen for the km line makes the extras the line`() {
        val plan = CheckInPlan(setOf(CheckInMetric.hrZone), zones)
        val s = CheckInWords.build(plan, 3, 900_000, 300_000, CheckInSnapshot(hrZone = 4))
        assertEquals("Zone 4.", s.base)
        assertNull(s.tail)
    }

    @Test
    fun `tracker zone time counts only offered ticks and smooths the zone`() {
        val t = CheckInTracker(zones)
        repeat(9) { t.tick(1_000, 3.0, 300.0, 300.0, 130.0) }
        assertNull(t.smoothedZone())
        repeat(60) { t.tick(1_000, 3.0, 300.0, 300.0, 130.0) }
        assertEquals(2, t.smoothedZone())
        assertTrue(t.zoneMsOf(2) >= 59_000)
        // A strap that drops ages out: no zone.
        repeat(40) { t.tick(1_000, 3.0, 300.0, 300.0, null) }
        assertNull(t.smoothedZone())
    }

    @Test
    fun `tracker true factor is distance weighted and resets per km`() {
        val t = CheckInTracker(null)
        repeat(300) { t.tick(1_000, 1.0, 300.0, 270.0, null) }
        assertEquals(0.9, t.closeKmFactor()!!, 1e-9)
        assertNull(t.closeKmFactor())
    }

    @Test
    fun `tracker height reads against the first height`() {
        val t = CheckInTracker(null)
        assertNull(t.heightVsStart(100.0))
        t.noteElevation(100.0, baro = true)
        t.noteElevation(130.0, baro = true)
        assertEquals(30.0, t.heightVsStart(130.0)!!, 1e-9)
    }

    @Test
    fun `coach says the plan on a trail run and the legacy split without one`() {
        val snap = CheckInSnapshot(hrZone = 2, hrZoneMs = 5 * 60_000L)
        val plain = LiveCoach(null, RunMode.trail, null)
        val a = plain.onTick(0, 0.0, 1_000, 1_000.0, snap = { snap }) { it }
        assertEquals(LiveWords.kmSplit(1, 1_000, 1_000), a!!.base)
        assertNull(a.tail)

        val planned = LiveCoach(null, RunMode.trail, null).also { it.checkIn = all }
        val b = planned.onTick(0, 0.0, 1_000, 1_000.0, snap = { snap }) { it }
        assertNotNull(b)
        assertEquals("Zone 2 for 5 minutes.", b.tail)
    }

    @Test
    fun `a GPS first reading never becomes the start height`() {
        val t = CheckInTracker(null)
        t.noteElevation(100.0, baro = false) // GPS only so far
        assertNull(t.heightVsStart(100.0))
        t.noteElevation(140.0, baro = true) // the barometer lands: the baseline
        t.noteElevation(150.0, baro = true)
        assertEquals(20.0, t.heightVsStart(160.0)!!, 1e-9)
    }

    @Test
    fun `height and climb are skipped without the barometer`() {
        val t = CheckInTracker(null)
        t.noteElevation(100.0, baro = true)
        val gps = t.snapshot(600_000, 2_000.0, baro = false, elevationM = 160.0, ascentM = 80.0)
        assertNull(gps.climbM)
        assertNull(gps.heightVsStartM)
        val baro = t.snapshot(600_000, 2_000.0, baro = true, elevationM = 160.0, ascentM = 80.0)
        assertEquals(80.0, baro.climbM!!, 1e-9)
        assertEquals(60.0, baro.heightVsStartM!!, 1e-9)
    }

    @Test
    fun `a restored tracker says Zone 3 with no minutes`() {
        val t = CheckInTracker(zones)
        t.partial = true
        repeat(120) { t.tick(1_000, 3.0, 300.0, 300.0, 150.0) }
        val snap = t.snapshot(600_000, 2_000.0, baro = false, elevationM = null, ascentM = null)
        assertEquals(3, snap.hrZone)
        assertNull(snap.hrZoneMs)
        assertEquals("Zone 3.", CheckInWords.build(CheckInPlan(setOf(CheckInMetric.hrZone), zones), 2, 600_000, 300_000, snap).base)
    }

    @Test
    fun `an unrestored tracker says the minutes`() {
        val t = CheckInTracker(zones)
        repeat(120) { t.tick(1_000, 3.0, 300.0, 300.0, 150.0) }
        val snap = t.snapshot(600_000, 2_000.0, baro = false, elevationM = null, ascentM = null)
        assertEquals("Zone 3 for 2 minutes.", CheckInWords.build(CheckInPlan(setOf(CheckInMetric.hrZone), zones), 2, 600_000, 300_000, snap).base)
    }
}
