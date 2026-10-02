package app.runsolo.core.route

import app.runsolo.core.route.RouteTestKit.Runner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RouteTurnsTest {
    private fun path(vararg corners: Pair<Double, Double>) = RoutePath(RouteTestKit.route(corners.toList()))

    @Test
    fun `a straight route has no turns`() {
        assertTrue(path(0.0 to 0.0, 2_000.0 to 0.0).turns.isEmpty())
    }

    @Test
    fun `a gentle bend is not a turn`() {
        // 30 degrees over a long bend.
        assertTrue(path(0.0 to 0.0, 500.0 to 0.0, 1_000.0 to 290.0).turns.isEmpty())
    }

    @Test
    fun `a right angle to the right is one right turn at the corner`() {
        val turns = path(0.0 to 0.0, 500.0 to 0.0, 500.0 to -500.0).turns
        assertEquals(1, turns.size)
        val t = turns[0]
        assertTrue(t.right)
        assertEquals(TurnKind.turn, t.kind)
        assertEquals(500.0, t.atM, 15.0)
        assertEquals(90.0, t.angleDeg, 8.0)
        assertEquals("Right turn", RouteWords.turnLabel(t))
    }

    @Test
    fun `a left turn is a left turn`() {
        val t = path(0.0 to 0.0, 500.0 to 0.0, 500.0 to 500.0).turns.single()
        assertTrue(!t.right)
        assertEquals("Left turn", RouteWords.turnLabel(t))
    }

    @Test
    fun `a 60 degree bend is keep right and a hairpin is a u-turn`() {
        val keep = path(0.0 to 0.0, 500.0 to 0.0, 750.0 to -433.0).turns.single()
        assertEquals(TurnKind.keep, keep.kind)
        assertEquals("Keep right", RouteWords.turnLabel(keep))
        val u = path(0.0 to 0.0, 500.0 to 0.0, 0.0 to 20.0).turns.single()
        assertEquals(TurnKind.uTurn, u.kind)
        assertEquals("U-turn", RouteWords.turnLabel(u))
    }

    @Test
    fun `an s-bend is two turns on opposite sides`() {
        val turns = path(0.0 to 0.0, 400.0 to 0.0, 400.0 to -300.0, 800.0 to -300.0, 800.0 to 100.0).turns
        assertEquals(3, turns.size)
        assertEquals(listOf(true, false, false), turns.map { it.right })
    }

    @Test
    fun `a jittery straight route does not invent turns`() {
        val rnd = kotlin.random.Random(7)
        val pts = RouteTestKit.densify(listOf(0.0 to 0.0, 2_000.0 to 0.0), 10.0).map { (x, y) -> x to y + (rnd.nextDouble() * 2 - 1) * 3.0 }
        val ll = ArrayList<Double>()
        for ((x, y) in pts) { ll.add(RouteTestKit.lat(y)); ll.add(RouteTestKit.lon(x)) }
        assertTrue(RoutePath(FollowRoute("j", "jitter", ll)).turns.isEmpty())
    }

    @Test
    fun `the cue comes about 50 m ahead, once, with the distance`() {
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 500.0 to 0.0, 500.0 to -500.0)))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 500.0 to 0.0, 500.0 to -200.0))
        assertEquals(listOf("Right turn in 50 m"), r.turnCues)
        val at = r.events.first { it.second is RouteFollower.Event.Turn }
        // It fired while the corner was still about 50 m away.
        val progressThen = r.progress[(at.first / 1_000).toInt()]
        assertEquals(450.0, progressThen, 12.0)
    }

    @Test
    fun `a keep says no distance`() {
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 500.0 to 0.0, 750.0 to -433.0, 1_000.0 to -866.0)))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 500.0 to 0.0, 598.0 to -170.0))
        assertEquals(listOf("Keep right"), r.turnCues)
    }

    @Test
    fun `no turn cue while off the route and none for a turn already passed`() {
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 500.0 to 0.0, 500.0 to -500.0)))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        // Wanders off the line for a minute, past the corner's distance, then rejoins beyond the corner.
        r.run(listOf(300.0 to 0.0, 300.0 to 120.0))
        r.hold(300.0, 120.0, 20)
        assertTrue(r.turnCues.isEmpty())
        r.run(listOf(300.0 to 120.0, 520.0 to 120.0, 500.0 to -60.0))
        // Rejoined past the corner: the missed cue is not said late.
        assertTrue(r.turnCues.isEmpty(), "said ${r.turnCues}")
    }

    @Test
    fun `next turn distance is exposed for the strip`() {
        val f = RouteTestKit.follower(RouteTestKit.route(listOf(0.0 to 0.0, 500.0 to 0.0, 500.0 to -500.0)))
        val r = Runner(f)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        assertEquals(200.0, f.nextTurnInM!!, 12.0)
        assertEquals(TurnKind.turn, f.nextTurn!!.kind)
    }

    @Test
    fun `cue words round to ten metres and never say less than ten`() {
        val turn = RouteTurn(100.0, 90.0, TurnKind.turn)
        assertEquals("Right turn in 50 m", RouteWords.turnCue(turn, 52.0))
        assertEquals("Right turn in 10 m", RouteWords.turnCue(turn, 3.0))
        assertEquals("Off route", RouteWords.OFF_ROUTE)
        assertEquals("Back on route", RouteWords.BACK_ON_ROUTE)
    }
}
