package app.runsolo.core.route

import app.runsolo.core.route.RouteTestKit.Runner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RouteFollowerTest {
    private val straight = listOf(0.0 to 0.0, 2_000.0 to 0.0)

    private fun near(expected: Double, actual: Double, tol: Double) =
        assertTrue(kotlin.math.abs(expected - actual) <= tol, "expected $expected within $tol, got $actual")

    @Test
    fun `progress and distance to go follow the runner along the route`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 600.0 to 2.0))
        near(600.0, f.progressM, 6.0)
        near(1_400.0, f.toGoM, 6.0)
        assertFalse(f.off)
        assertEquals(0, r.offAlerts)
    }

    @Test
    fun `climb to go counts the route's ascent still ahead`() {
        // 0..1000 m: +100 m climb spread along it; 1000..2000 m: flat.
        val route = RouteTestKit.route(straight, elev = { _, (x, _) -> if (x <= 1_000) x / 10.0 else 100.0 })
        val f = RouteTestKit.follower(route)
        assertEquals(100.0, f.path.totalClimbM!!, 4.0)
        assertEquals(100.0, f.climbToGoM!!, 4.0)
        Runner(f).run(listOf(0.0 to 0.0, 500.0 to 0.0))
        near(50.0, f.climbToGoM!!, 6.0)
        Runner(f).run(listOf(500.0 to 0.0, 1_500.0 to 0.0))
        near(0.0, f.climbToGoM!!, 5.0)
    }

    @Test
    fun `a route with no elevation has no climb to go`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        assertNull(f.path.totalClimbM)
        assertNull(f.climbToGoM)
    }

    @Test
    fun `GPS noise around the line never goes off route`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f, noiseM = 15.0)
        r.run(listOf(0.0 to 0.0, 1_500.0 to 0.0), accuracyM = 12.0)
        assertEquals(0, r.offAlerts)
        assertFalse(f.off)
        near(1_500.0, f.progressM, 40.0)
    }

    @Test
    fun `a spike of poor fixes never alerts`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        // 20 s of 80 m-off fixes that the phone itself calls 60 m accurate: ignored, not counted as off.
        repeat(20) { r.fix(300.0, 80.0, accuracyM = 60.0) }
        r.run(listOf(300.0 to 0.0, 400.0 to 0.0))
        assertEquals(0, r.offAlerts)
    }

    @Test
    fun `a short detour under ten seconds is not an alert`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 500.0 to 0.0))
        // Out to 50 m and back: about 6 s of being over the 40 m line.
        r.run(listOf(500.0 to 0.0, 504.0 to 30.0, 508.0 to 50.0, 512.0 to 50.0, 516.0 to 30.0, 520.0 to 0.0))
        r.run(listOf(520.0 to 0.0, 700.0 to 0.0))
        assertEquals(0, r.offAlerts)
        assertEquals(0, r.backAlerts)
        near(700.0, f.progressM, 6.0)
    }

    @Test
    fun `a wrong turn alerts once after ten seconds and says back on route when rejoined`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 500.0 to 0.0))
        val progressAtTurn = f.progressM
        // Left the line to the north, heading away at 4 m/s: 40 m at ~10 s, the alert ten seconds after that.
        r.run(listOf(500.0 to 0.0, 500.0 to 200.0))
        assertEquals(1, r.offAlerts)
        assertTrue(f.off)
        val alertAt = r.events.first { it.second is RouteFollower.Event.OffRoute }.first
        // Crossed 40 m at t = 125 + 10 s; alert at 135 + 10 s (fix times), allow a second of slack.
        assertTrue(alertAt in 143_000L..148_000L, "alert at $alertAt")
        // Progress did not creep along while off.
        near(progressAtTurn, f.progressM, 1.0)
        // Back down to the line and on: "back on route" once, three seconds after being near.
        r.run(listOf(500.0 to 200.0, 500.0 to 0.0, 700.0 to 0.0))
        assertEquals(1, r.backAlerts)
        assertFalse(f.off)
        near(700.0, f.progressM, 8.0)
    }

    @Test
    fun `staying off route repeats the alert only once a minute`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        r.hold(300.0, 120.0, 150)
        assertEquals(3, r.offAlerts) // at 10 s, then every 60 s
    }

    @Test
    fun `hysteresis a fix at the edge does not flip back and forth`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        r.hold(300.0, 80.0, 15)
        assertTrue(f.off)
        // Hovering 32 m out (between back 25 and off 40): still off, no "back on route".
        r.hold(300.0, 32.0, 30)
        assertTrue(f.off)
        assertEquals(0, r.backAlerts)
    }

    @Test
    fun `an out-and-back keeps progress monotonic and finishes at the end`() {
        // 1 km out along y = 0 and the same 1 km back.
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 1_000.0 to 0.0, 0.0 to 0.0)))
        assertEquals(2_000.0, f.path.totalM, 1.0)
        val r = Runner(f, noiseM = 3.0)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0, 0.0 to 0.0))
        for (i in 1 until r.progress.size) assertTrue(r.progress[i] >= r.progress[i - 1], "progress went back at $i")
        assertEquals(0, r.offAlerts)
        near(2_000.0, f.progressM, 25.0)
        // On the way out progress is the outward distance, never the return leg's.
        val outAt400 = r.progress[100] // 4 m/s: fix 100 is about 400 m out
        near(400.0, outAt400, 30.0)
    }

    @Test
    fun `an out-and-back's return leg is followed after the turnaround`() {
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 1_000.0 to 0.0, 0.0 to 0.0)))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0, 600.0 to 0.0))
        // 400 m back from the turn: route progress is 1,400 m, with 600 m to go.
        near(1_400.0, f.progressM, 40.0)
        near(600.0, f.toGoM, 40.0)
    }

    @Test
    fun `a loop that closes on its start does not jump to the end at the start`() {
        val loop = listOf(0.0 to 0.0, 500.0 to 0.0, 500.0 to 500.0, 0.0 to 500.0, 0.0 to 0.0)
        val f = RouteTestKit.follower(RouteTestKit.route(loop))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 200.0 to 0.0))
        near(200.0, f.progressM, 8.0)
        near(1_800.0, f.toGoM, 8.0)
        r.run(listOf(200.0 to 0.0, 500.0 to 0.0, 500.0 to 500.0, 0.0 to 500.0, 0.0 to 10.0))
        near(2_000.0, f.progressM, 25.0)
        assertEquals(0, r.offAlerts)
    }

    @Test
    fun `a route that crosses itself follows the route's order`() {
        // A figure of eight crossing at (250, 250): out the first diagonal, round, back through the same point.
        val route = listOf(0.0 to 0.0, 500.0 to 500.0, 500.0 to 0.0, 0.0 to 500.0)
        val f = RouteTestKit.follower(RouteTestKit.route(route))
        val r = Runner(f)
        r.run(route)
        near(f.path.totalM, f.progressM, 30.0)
        assertEquals(0, r.offAlerts)
        for (i in 1 until r.progress.size) assertTrue(r.progress[i] >= r.progress[i - 1])
    }

    @Test
    fun `resuming rebuilds progress quietly from earlier fixes`() {
        val route = RouteTestKit.route(straight)
        val a = RouteTestKit.follower(route)
        val live = Runner(a)
        live.run(listOf(0.0 to 0.0, 700.0 to 0.0))
        val b = RouteTestKit.follower(route)
        var t = 0L
        for (s in 0..175) {
            assertTrue(b.offer(t, RouteTestKit.lat(0.0), RouteTestKit.lon(s * 4.0), 5.0, quiet = true).isEmpty())
            t += 1_000
        }
        near(a.progressM, b.progressM, 8.0)
    }

    @Test
    fun `a fix with no accuracy or a non-finite position is ignored`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        assertTrue(f.offer(0, Double.NaN, 1.0, 5.0).isEmpty())
        assertTrue(f.offer(1000, RouteTestKit.lat(0.0), RouteTestKit.lon(0.0), Double.NaN).isEmpty())
        assertEquals(0.0, f.progressM)
    }

    @Test
    fun `the follower never walks backwards when the runner steps back a few metres`() {
        val f = RouteTestKit.follower(RouteTestKit.route(straight))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        val p = f.progressM
        r.fix(285.0, 0.0)
        assertEquals(p, f.progressM, 0.0001)
        assertNotNull(f.nextTurnInM?.let { 0 } ?: 0)
    }
}
