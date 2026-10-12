package app.runsolo.core.route

import app.runsolo.core.route.RouteTestKit.Runner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RouteEndTest {
    private val straight = listOf(0.0 to 0.0, 1_000.0 to 0.0)
    private val loop = listOf(0.0 to 0.0, 400.0 to 0.0, 400.0 to 400.0, 0.0 to 400.0, 0.0 to 10.0)

    private fun ends(r: Runner) = r.events.mapNotNull { it.second as? RouteFollower.Event.RouteEnd }

    @Test
    fun `reaching the end of an out route says turn around once`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0))
        r.hold(1_000.0, 0.0, 10)
        val e = ends(r)
        assertEquals(1, e.size)
        assertEquals(RouteFollower.EndKind.turnAround, e[0].kind)
        assertEquals("End of route. Turn around.", e[0].text)
        assertEquals(RouteFollower.EndKind.turnAround, f.endCue)
    }

    @Test
    fun `a loop that closes on its start says route done`() {
        val f = RouteTestKit.follower(RouteTestKit.route(loop))
        val r = Runner(f)
        r.run(loop)
        val e = ends(r)
        assertEquals(1, e.size)
        assertEquals(RouteFollower.EndKind.done, e[0].kind)
        assertEquals(RouteWords.END_DONE, e[0].text)
    }

    @Test
    fun `a loop does not end at the start`() {
        val f = RouteTestKit.follower(RouteTestKit.route(loop))
        val r = Runner(f)
        r.hold(0.0, 0.0, 30)
        assertEquals(0, ends(r).size)
        assertNull(f.endCue)
    }

    @Test
    fun `jitter at the end never fires again`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f, noiseM = 12.0)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0), accuracyM = 10.0)
        r.hold(1_000.0, 0.0, 60)
        assertEquals(1, ends(r).size)
    }

    @Test
    fun `a poor fix near the end does not announce it`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 900.0 to 0.0))
        r.fix(1_000.0, 0.0, accuracyM = 28.0)
        assertEquals(0, ends(r).size)
        r.fix(1_000.0, 0.0, accuracyM = 6.0)
        assertEquals(1, ends(r).size)
    }

    @Test
    fun `stopping short of the end says nothing`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 960.0 to 0.0))
        r.hold(960.0, 0.0, 30)
        assertEquals(0, ends(r).size)
    }

    @Test
    fun `heading back clears the cue and raises no off route alert`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0))
        assertEquals(RouteFollower.EndKind.turnAround, f.endCue)
        r.run(listOf(1_000.0 to 0.0, 700.0 to 0.0))
        assertNull(f.endCue)
        assertEquals(0, r.offAlerts)
        assertFalse(f.off)
    }

    @Test
    fun `the cue lapses after a minute of standing at the end`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0))
        r.hold(1_000.0, 0.0, 30)
        assertTrue(f.endCue != null)
        r.hold(1_000.0, 0.0, 40)
        assertNull(f.endCue)
    }

    @Test
    fun `a restored run at the end shows no cue and says nothing`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        for (i in 0..10) {
            val quiet = f.offer(i * 10_000L, RouteTestKit.lat(0.0), RouteTestKit.lon(i * 100.0), 5.0, quiet = true)
            assertTrue(quiet.isEmpty())
        }
        f.restartClock()
        assertNull(f.endCue)
        assertTrue(f.offer(1_000L, RouteTestKit.lat(0.0), RouteTestKit.lon(1_000.0), 5.0).isEmpty())
    }

    @Test
    fun `a finish short of the end and to the side still fires on loose fixes`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 940.0 to 0.0))
        // 25 m short of the end and 30 m to the side: toGo is over 20 m but the end point is within 40 m.
        r.fix(975.0, 30.0, accuracyM = 18.0)
        val e = ends(r)
        assertEquals(1, e.size)
        assertEquals(RouteFollower.EndKind.turnAround, e[0].kind)
        assertEquals(0, r.offAlerts)
        assertFalse(f.off)
    }

    @Test
    fun `off route then reaching the end ends the route and clears off route`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 940.0 to 0.0))
        r.hold(940.0, 120.0, 12)
        assertTrue(f.off)
        assertEquals(1, r.offAlerts)
        assertEquals(0, ends(r).size)
        r.hold(1_000.0, 20.0, 10)
        assertEquals(1, ends(r).size)
        assertFalse(f.off)
        assertEquals(1, r.offAlerts)
        assertEquals(0, r.backAlerts)
    }

    @Test
    fun `an out and back whose end sits near its middle does not fire early`() {
        // Out 1000 m east, 400 m north, then back west to finish 30 m from the midpoint of the first leg.
        val corners = listOf(0.0 to 0.0, 1_000.0 to 0.0, 1_000.0 to 400.0, 500.0 to 400.0, 500.0 to 30.0)
        val f = RouteTestKit.follower(RouteTestKit.route(corners))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0, 1_000.0 to 400.0, 520.0 to 400.0))
        assertEquals(0, ends(r).size)
        r.run(listOf(500.0 to 400.0, 500.0 to 30.0))
        assertEquals(1, ends(r).size)
    }
}
