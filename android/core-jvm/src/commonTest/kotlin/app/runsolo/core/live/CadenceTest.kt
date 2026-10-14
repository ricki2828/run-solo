package app.runsolo.core.live

import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.RunMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Cadence v1: the Coach km line, the news-only half km, the Voice detail levels and the trail moments. */
class CadenceTest {
    private val zones = listOf(120.0, 140.0, 160.0, 175.0)

    private fun plan(level: VoiceLevel) = CheckInPlan(CheckInMetric.DEFAULT, zones, level)

    private fun trailCoach(level: VoiceLevel = VoiceLevel.coach) =
        LiveCoach(LiveContext(boards = emptyList(), builtAtMs = 0, engineVersion = 1), RunMode.trail, null).also { it.checkIn = plan(level) }

    private fun at(coach: LiveCoach, prevD: Double, d: Double, atMs: Long, snap: CheckInSnapshot) =
        coach.onTick(atMs - 1_000, prevD, atMs, d, null, snap = { snap }) { it }

    @Test
    fun `a trail km with a ghost says the km and one lead`() {
        val coach = trailCoach()
        val k = assertNotNull(at(coach, 3_998.0, 4_002.0, 1_872_000, CheckInSnapshot(ghostAheadSec = 12.0, climbM = 85.0, hrZone = 3, hrZoneMs = 840_000)))
        assertEquals("4 k. 12 seconds up on your best.", k.base)
        assertNull(k.tail)
        assertEquals(CueSlot.km, k.slot)
        assertEquals("km:4", k.key)
    }

    @Test
    fun `a trail km with no ghost and a hill says the km and the time only`() {
        val coach = trailCoach()
        at(coach, 2_998.0, 3_002.0, 1_300_000, CheckInSnapshot(climbM = 100.0))
        val k = assertNotNull(at(coach, 3_998.0, 4_002.0, 1_872_000, CheckInSnapshot(climbM = 185.0)))
        assertEquals("4 k. 31 minutes 12.", k.base)
        assertNull(k.tail)
    }

    @Test
    fun `a half km with no news is silent`() {
        val coach = trailCoach()
        assertNull(at(coach, 490.0, 510.0, 150_000, CheckInSnapshot(hrZone = 2)))
        assertNotNull(at(coach, 998.0, 1_002.0, 300_000, CheckInSnapshot(hrZone = 2)), "the km itself is said")
        assertNull(at(coach, 1_490.0, 1_510.0, 450_000, CheckInSnapshot(hrZone = 2)))
    }

    @Test
    fun `a half km speaks a ghost gap that moved 15 seconds`() {
        val coach = trailCoach()
        assertNull(at(coach, 490.0, 510.0, 150_000, CheckInSnapshot(ghostAheadSec = 5.0)), "first sighting is a baseline")
        assertNotNull(at(coach, 998.0, 1_002.0, 300_000, CheckInSnapshot(ghostAheadSec = 5.0)))
        val h = assertNotNull(at(coach, 1_490.0, 1_510.0, 450_000, CheckInSnapshot(ghostAheadSec = 25.0)))
        assertEquals("25 seconds up on your best.", h.base)
        assertEquals(CueSlot.halfKm, h.slot)
        assertEquals("halfKm:gap", h.key)
        assertNull(h.fire)
    }

    @Test
    fun `a half km speaks a zone change once and not again within 1500 m`() {
        val coach = trailCoach()
        assertNull(at(coach, 490.0, 510.0, 150_000, CheckInSnapshot(hrZone = 2)))
        assertNotNull(at(coach, 998.0, 1_002.0, 300_000, CheckInSnapshot(hrZone = 2)))
        val h = assertNotNull(at(coach, 1_490.0, 1_510.0, 450_000, CheckInSnapshot(hrZone = 3)))
        assertEquals("Zone 3.", h.base)
        assertNotNull(at(coach, 1_998.0, 2_002.0, 600_000, CheckInSnapshot(hrZone = 3)))
        assertNull(at(coach, 2_490.0, 2_510.0, 750_000, CheckInSnapshot(hrZone = 4)), "the zone item was said 1000 m ago")
        assertTrue(CueComposer.words(h.base) <= HalfKmNews.MAX_WORDS)
    }

    @Test
    fun `minimal says the km word and no half km`() {
        val coach = trailCoach(VoiceLevel.minimal)
        assertNull(at(coach, 490.0, 510.0, 150_000, CheckInSnapshot(hrZone = 2)))
        val k = assertNotNull(at(coach, 3_998.0, 4_002.0, 1_872_000, CheckInSnapshot(ghostAheadSec = 12.0)))
        assertEquals("4 k.", k.base)
        assertNull(k.tail)
    }

    @Test
    fun `everything keeps today's km line and no half km`() {
        val coach = trailCoach(VoiceLevel.everything)
        assertNull(at(coach, 490.0, 510.0, 150_000, CheckInSnapshot(hrZone = 3)))
        val snap = CheckInSnapshot(avgPaceSecPerKm = 560.0, kmTrueFactor = 0.82, hrZone = 3, hrZoneMs = 22 * 60_000L, climbM = 212.0, heightVsStartM = 83.0)
        val k = assertNotNull(at(coach, 3_998.0, 4_002.0, 2_290_000, snap))
        val legacy = CheckInWords.build(plan(VoiceLevel.everything), 4, 2_290_000, null, snap)
        assertEquals(legacy.base, k.base)
        assertEquals(legacy.tail, k.tail)
    }

    @Test
    fun `the Voice detail rides the metric list and an old build ignores it`() {
        val keys = listOf("distance", "time", VoiceLevel.minimal.metricKey)
        assertEquals("voice:minimal", VoiceLevel.minimal.metricKey)
        assertEquals(VoiceLevel.minimal, VoiceLevel.fromMetricKeys(keys))
        // The check-in as a build from before this setting parses it: the reserved key is simply not a metric.
        assertEquals(setOf(CheckInMetric.distance, CheckInMetric.time), CheckInMetric.parse(keys))
        assertEquals(CheckInMetric.parse(keys - VoiceLevel.minimal.metricKey), CheckInMetric.parse(keys))
        assertNull(VoiceLevel.fromMetricKeys(listOf("distance")), "an app without the setting sends none")
        assertNull(VoiceLevel.fromMetricKeys(listOf("voice:loud")))
        assertEquals(VoiceLevel.coach, VoiceLevel.DEFAULT)
        for (level in VoiceLevel.entries) assertTrue(CheckInMetric.entries.none { it.key == level.metricKey })
    }

    @Test
    fun `a climb ahead is said once and not again within a km`() {
        val m = TrailMoments()
        val first = m.tick(MomentInput(nowMs = 0, distM = 3_000.0, climbAheadM = 70.0))
        assertEquals(listOf("Climb ahead. 70 metres up."), first.map { it.text })
        assertEquals(CueSlot.climbAhead, first.single().slot)
        assertTrue(m.tick(MomentInput(nowMs = 5_000, distM = 3_100.0, climbAheadM = 65.0)).isEmpty())
        assertTrue(m.tick(MomentInput(nowMs = 0, distM = 3_000.0, climbAheadM = 20.0)).isEmpty())
    }

    @Test
    fun `a climb is done when 30 m of gain levels out for 100 m`() {
        val m = TrailMoments()
        assertTrue(m.tick(MomentInput(nowMs = 0, distM = 1_000.0, ascentM = 100.0, grade = 0.06)).isEmpty())
        assertTrue(m.tick(MomentInput(nowMs = 1, distM = 1_100.0, ascentM = 140.0, grade = 0.01)).isEmpty())
        val done = m.tick(MomentInput(nowMs = 2, distM = 1_200.0, ascentM = 141.0, grade = 0.01))
        assertEquals(listOf("Climb done. 40 metres up."), done.map { it.text })
        assertTrue(m.tick(MomentInput(nowMs = 3, distM = 1_400.0, ascentM = 141.0, grade = 0.01)).isEmpty())
    }

    @Test
    fun `a hump under 30 m is not a climb`() {
        val m = TrailMoments()
        m.tick(MomentInput(nowMs = 0, distM = 1_000.0, ascentM = 100.0, grade = 0.06))
        m.tick(MomentInput(nowMs = 1, distM = 1_050.0, ascentM = 112.0, grade = 0.0))
        assertTrue(m.tick(MomentInput(nowMs = 2, distM = 1_200.0, ascentM = 112.0, grade = 0.0)).isEmpty())
    }

    @Test
    fun `the final push is one k from the end within 30 s of the best and said once`() {
        val m = TrailMoments()
        assertTrue(m.tick(MomentInput(nowMs = 0, distM = 8_000.0, ghostAheadSec = -14.0, toEndM = 1_500.0)).isEmpty())
        val push = m.tick(MomentInput(nowMs = 1, distM = 8_600.0, ghostAheadSec = -14.0, toEndM = 900.0))
        assertEquals(listOf("One k left. 14 seconds to find for your best."), push.map { it.text })
        assertTrue(m.tick(MomentInput(nowMs = 2, distM = 8_700.0, ghostAheadSec = -14.0, toEndM = 800.0)).isEmpty())
        assertTrue(TrailMoments().tick(MomentInput(nowMs = 1, distM = 8_600.0, ghostAheadSec = -45.0, toEndM = 900.0)).isEmpty())
    }

    @Test
    fun `no ghost fields means no ghost beats`() {
        val m = TrailMoments()
        for (i in 0 until 100) assertTrue(m.tick(MomentInput(nowMs = i * 1_000L, distM = i * 3.0)).isEmpty())
    }
}
