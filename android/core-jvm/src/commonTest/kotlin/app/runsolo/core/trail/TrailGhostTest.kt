package app.runsolo.core.trail

import app.runsolo.core.route.RouteFollower
import app.runsolo.core.route.RouteWords
import app.runsolo.core.trail.TrailGhostKit.Runner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TrailGhostTest {
    private val straight = listOf(0.0 to 0.0, 2_000.0 to 0.0)

    @Test
    fun `a run on a known trail is matched early and not before it is real`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 600.0 to 0.0))
        val firstMatch = r.states.indexOfFirst { it != null }
        assertTrue(firstMatch in 1..100, "matched at fix $firstMatch")
        // Not on the first fixes: 300 m of progress is the bar (4 m/s, so about 75 s).
        assertTrue(r.states.take(60).all { it == null })
        assertEquals("t1", r.states.last()?.trailId)
    }

    @Test
    fun `a run alongside the trail but 100 m away never matches`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 100.0, 1_500.0 to 100.0))
        assertTrue(r.states.all { it == null })
        assertTrue(g.candidateIds.isEmpty())
    }

    @Test
    fun `the trail run the other way round never matches`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(2_000.0 to 0.0, 0.0 to 0.0))
        assertTrue(r.states.all { it == null })
    }

    @Test
    fun `a run that joins a one way trail halfway along is not picked up`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(900.0 to 0.0, 1_800.0 to 0.0))
        assertTrue(r.states.all { it == null })
    }

    @Test
    fun `a different trail with a similar shape that parts company is ruled out`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        // 200 m shared, then it bends away: never 300 m of progress on the trail.
        r.run(listOf(0.0 to 0.0, 200.0 to 0.0, 300.0 to 400.0, 1_500.0 to 400.0))
        assertTrue(r.states.all { it == null })
    }

    @Test
    fun `ahead of the best at the same point is positive and behind is negative`() {
        // Best 4 m/s, last 3.5 m/s. A runner at 5 m/s over 1000 m is 1000/4 - 1000/5 = 50 s ahead of the best.
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 5.0)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0))
        val s = r.states.last()!!
        assertEquals(50_000.0, s.aheadBestMs!!.toDouble(), 3_000.0)
        // The last run was slower still: 1000/3.5 - 1000/5 = 85.7 s.
        assertEquals(85_700.0, s.aheadLastMs!!.toDouble(), 3_500.0)
        assertFalse(s.lastIsBest)

        val g2 = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val slow = Runner(g2, mps = 3.0)
        slow.run(listOf(0.0 to 0.0, 600.0 to 0.0))
        val b = slow.states.last()!!
        assertTrue(b.aheadBestMs!! < -30_000, "behind the best: ${b.aheadBestMs}")
        assertTrue(b.aheadLastMs!! < 0)
    }

    @Test
    fun `a stop does not count against the runner and a run at the reference pace stays level`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 4.0)
        r.run(listOf(0.0 to 0.0, 500.0 to 0.0))
        r.hold(500.0, 0.0, 30) // paused / auto-paused: active time does not run
        r.run(listOf(500.0 to 0.0, 1_000.0 to 0.0))
        assertEquals(0.0, r.states.last()!!.aheadBestMs!!.toDouble(), 2_500.0)
    }

    @Test
    fun `the time is compared over the same stretch even when the run joined late`() {
        // Joins the trail 200 m in (a loop style start): only the joined stretch is compared. Loop trail so it is allowed.
        val loop = listOf(0.0 to 0.0, 600.0 to 0.0, 600.0 to 600.0, 0.0 to 600.0, 0.0 to 20.0)
        val g = TrailGhost(listOf(TrailGhostKit.trail(loop)))
        val r = Runner(g, mps = 5.0)
        r.run(listOf(300.0 to 0.0, 600.0 to 0.0, 600.0 to 600.0))
        val s = r.states.last()!!
        // 900 m covered at 5 m/s against 4 m/s: 900/4 - 900/5 = 45 s ahead, whatever the first 300 m cost the reference.
        assertEquals(45_000.0, s.aheadBestMs!!.toDouble(), 3_000.0)
    }

    @Test
    fun `no figure on the first 100 m or beyond where the reference went`() {
        val short = TrailGhostKit.trail(straight)
        val cut = short.best.ms.mapIndexed { i, v -> if (i > 60) -1L else v }
        val g = TrailGhost(listOf(short.copy(best = short.best.copy(ms = cut))))
        val r = Runner(g)
        r.run(straight)
        val matched = r.states.filterNotNull()
        assertNull(matched.last().aheadBestMs) // 2000 m is past vertex 60 (1500 m)
        assertNotNull(matched.last().aheadLastMs)
    }

    @Test
    fun `an out and back trail says turn around once at the reference turnaround`() {
        val oab = listOf(0.0 to 0.0, 1_000.0 to 0.0, 1_000.0 to 6.0, 0.0 to 6.0)
        val g = TrailGhost(listOf(TrailGhostKit.trail(oab, turnAlongM = 1_000.0)))
        val r = Runner(g)
        r.run(oab)
        assertEquals(1, r.turnEvents.size)
        val e = r.turnEvents[0].second as RouteFollower.Event.RouteEnd
        assertEquals(RouteFollower.EndKind.turnAround, e.kind)
        assertEquals(RouteWords.END_TURN_AROUND, e.text)
        // At about 1000 m of running (250 s at 4 m/s), not at the start or the finish.
        assertTrue(r.turnEvents[0].first in 235_000L..255_000L, "fired at ${r.turnEvents[0].first}")
        // The cue is up for a while, then clears once the runner is heading back.
        val cueAt = r.states.indexOfFirst { it?.turnCue == true }
        assertTrue(cueAt > 0)
        assertFalse(r.states.last()!!.turnCue)
        // The way back is followed too: progress passes the turnaround.
        assertTrue(r.states.last()!!.alongM > 1_500.0, "along ${r.states.last()!!.alongM}")
    }

    @Test
    fun `jitter at the turnaround never fires it twice`() {
        val oab = listOf(0.0 to 0.0, 1_000.0 to 0.0, 1_000.0 to 6.0, 0.0 to 6.0)
        val g = TrailGhost(listOf(TrailGhostKit.trail(oab, turnAlongM = 1_000.0)))
        val r = Runner(g, noiseM = 10.0)
        r.run(listOf(0.0 to 0.0, 1_000.0 to 0.0), accuracyM = 10.0)
        r.hold(1_000.0, 0.0, 40)
        r.run(listOf(1_000.0 to 6.0, 500.0 to 6.0), accuracyM = 10.0)
        assertEquals(1, r.turnEvents.size)
    }

    @Test
    fun `a poor fix near the turnaround does not announce it`() {
        val oab = listOf(0.0 to 0.0, 1_000.0 to 0.0, 1_000.0 to 6.0, 0.0 to 6.0)
        val g = TrailGhost(listOf(TrailGhostKit.trail(oab, turnAlongM = 1_000.0)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 990.0 to 0.0), accuracyM = 25.0)
        assertEquals(0, r.turnEvents.size)
    }

    @Test
    fun `a trail with no turnaround never says it`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(straight)
        assertEquals(0, r.turnEvents.size)
        assertNull(r.states.last()!!.toTurnM)
    }

    @Test
    fun `two trails that share a start lead by who confirms first and hand over when it is left`() {
        val a = TrailGhostKit.trail(listOf(0.0 to 0.0, 800.0 to 0.0, 800.0 to 800.0), id = "a")
        val b = TrailGhostKit.trail(listOf(0.0 to 0.0, 800.0 to 0.0, 1_600.0 to 0.0), id = "b")
        val g = TrailGhost(listOf(a, b))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 800.0 to 0.0, 1_600.0 to 0.0))
        assertEquals("a", r.states.first { it != null }!!.trailId)
        assertEquals("b", r.states.last()!!.trailId)
    }

    @Test
    fun `leaving the trail after a match drops the figures and returning brings them back`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 600.0 to 0.0))
        r.run(listOf(600.0 to 0.0, 600.0 to 120.0))
        assertTrue(r.states.last()!!.off)
        assertNull(r.states.last()!!.aheadBestMs)
        r.run(listOf(600.0 to 120.0, 600.0 to 0.0, 1_000.0 to 0.0))
        assertFalse(r.states.last()!!.off)
        assertNotNull(r.states.last()!!.aheadBestMs)
    }

    @Test
    fun `a bad fix changes nothing`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        assertTrue(g.offer(0, 0.0, 0.0, 80.0, 0, 0.0).isEmpty())
        assertTrue(g.offer(0, Double.NaN, 0.0, 5.0, 0, 0.0).isEmpty())
        assertNull(g.state)
    }

    @Test
    fun `six full size trails stay cheap and bounded for an hour of fixes`() {
        val trails = (1..TrailRef.MAX_TRAILS).map { i ->
            TrailGhostKit.trail(listOf(0.0 to 0.0, 9_975.0 to 0.0), id = "t$i", stepM = 25.0)
        }
        assertEquals(400, trails[0].latLon.size / 2)
        val g = TrailGhost(trails)
        val r = Runner(g, mps = 2.8)
        r.run(listOf(0.0 to 0.0, 9_975.0 to 0.0))
        assertTrue(r.states.size >= 3_000)
        assertNotNull(r.states.last())
    }

    @Test
    fun `the feed passes the ghost through and switches it off when building it fails`() {
        var failures = 0
        val ok = TrailGhostFeed(listOf(TrailGhostKit.trail(straight)), onFailure = { failures++ })
        assertTrue(ok.active)
        assertNull(ok.failure)
        val none = TrailGhostFeed(emptyList(), onFailure = { failures++ })
        assertFalse(none.active)
        assertTrue(none.offer(0, 0.0, 0.0, 5.0, 0, 0.0).isEmpty())
        val broken = TrailGhostFeed(listOf(TrailGhostKit.trail(straight)), onFailure = { failures++ }, build = { error("boom") })
        assertFalse(broken.active)
        assertNotNull(broken.failure)
        assertTrue(broken.offer(0, 0.0, 0.0, 5.0, 0, 0.0).isEmpty())
        assertNull(broken.state)
        assertEquals(1, failures)
    }

    @Test
    fun `a trail ref that breaks its contract is refused`() {
        val ok = TrailGhostKit.trail(straight)
        val short = ok.best.copy(ms = ok.best.ms.drop(1))
        val r = runCatching { ok.copy(best = short) }
        assertTrue(r.isFailure)
        assertTrue(runCatching { ok.copy(latLon = ok.latLon + listOf(0.0)) }.isFailure)
        assertTrue(runCatching { ok.copy(turnAlongM = -1.0) }.isFailure)
    }

    // 2 km straight: flat to 600 m, a 40 m climb to 1000 m, flat to 1400 m, then down 20 m.
    private fun hill(d: Double) = when {
        d < 600 -> 0.0
        d < 1000 -> (d - 600) / 400 * 40
        d < 1400 -> 40.0
        else -> 40 - (d - 1400) / 600 * 20
    }
    private val hillClimb = TrailClimb(startM = 600.0, endM = 1_000.0, gainM = 40.0, avgGradePct = 10.0)

    @Test
    fun `the elevation profile and climbs ride the state and the runner is told where the next climb starts`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight, elev = ::hill, climbs = listOf(hillClimb))))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 1_300.0 to 0.0))
        // Early (about 400 m along): 200 m to go to the climb, not on it.
        val early = r.states[100]!!
        assertEquals(TrailGhost.PROFILE_POINTS, early.elevProfile!!.size)
        assertEquals(2_000.0 / (TrailGhost.PROFILE_POINTS - 1), early.elevStepM!!, 1.0)
        assertEquals(listOf(hillClimb), early.climbs)
        assertFalse(early.inClimb)
        assertEquals(600.0 - early.alongM, early.toClimbM!!, 1.0)
        // The profile is the trail's: flat at the start, 40 m up at 1.2 km.
        assertEquals(0.0, early.elevProfile!!.first(), 0.1)
        assertEquals(40.0, early.elevProfile!![(1_200.0 / early.elevStepM!!).toInt()], 1.5)
        // On the climb: in it, nothing ahead.
        val on = r.states.first { it != null && it.alongM in 700.0..900.0 }!!
        assertTrue(on.inClimb)
        assertNull(on.toClimbM)
        // Past the top: out of it, no climb ahead.
        val past = r.states.last()!!
        assertFalse(past.inClimb)
        assertNull(past.toClimbM)
    }

    @Test
    fun `a trail with no elevation has no profile and no climbs`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 600.0 to 0.0))
        val s = r.states.last()!!
        assertNull(s.elevProfile)
        assertNull(s.elevStepM)
        assertTrue(s.climbs.isEmpty())
        assertNull(s.toClimbM)
        assertFalse(s.inClimb)
    }

    @Test
    fun `an elevation profile that does not fit the trail is ignored and the ghost still works`() {
        val ok = TrailGhostKit.trail(straight, elev = ::hill, climbs = listOf(hillClimb))
        val bad = ok.copy(elevM = ok.elevM!!.drop(3))
        val nan = ok.copy(elevM = ok.elevM!!.mapIndexed { i, v -> if (i == 5) Double.NaN else v })
        for (t in listOf(bad, nan)) {
            val g = TrailGhost(listOf(t))
            val r = Runner(g)
            r.run(listOf(0.0 to 0.0, 600.0 to 0.0))
            val s = r.states.last()!!
            assertEquals("t1", s.trailId)
            assertNull(s.elevProfile)
            assertTrue(s.climbs.isEmpty())
        }
    }

    @Test
    fun `odd climbs are dropped and the rest kept`() {
        val odd = listOf(
            hillClimb,
            TrailClimb(900.0, 800.0, 10.0, 5.0),
            TrailClimb(0.0, 100.0, Double.NaN, 5.0),
            TrailClimb(1_100.0, 1_300.0, -3.0, 2.0),
        )
        val ref = TrailGhostKit.trail(straight, elev = ::hill, climbs = odd)
        assertEquals(listOf(hillClimb), ref.sensibleClimbs)
    }

    @Test
    fun `elevation and climbs survive the journal and an old trail without them reads`() {
        val ref = TrailGhostKit.trail(straight, elev = ::hill, climbs = listOf(hillClimb))
        assertEquals(ref, TrailRef.fromJson(ref.toJson()))
        val plain = TrailGhostKit.trail(straight)
        assertFalse(plain.toJson().containsKey("elev"))
        assertFalse(plain.toJson().containsKey("climbs"))
        assertEquals(plain, TrailRef.fromJson(plain.toJson()))
    }

    // Best 4 m/s, last 3.5 m/s over a 2 km straight. A runner at 3 m/s is behind both: best by d/12 s, last by d/21 s.
    @Test
    fun `the ghost starts against the best`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 300.0 to 0.0))
        assertTrue(r.states.filterNotNull().all { it.racing == TrailGhost.Racing.best })
        assertTrue(g.drainSwitches().isEmpty())
    }

    @Test
    fun `clearly behind the best for two minutes slips to the last run once`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 900.0 to 0.0))
        val s = r.states.last()!!
        assertEquals(TrailGhost.Racing.last, s.racing)
        // Both figures are still there.
        assertTrue(s.aheadBestMs!! < s.aheadLastMs!!)
        val sw = g.drainSwitches()
        assertEquals(1, sw.size)
        assertTrue(sw[0].toLast)
        assertTrue(g.drainSwitches().isEmpty())
        // Not before the hold: the margin (30 s) is crossed at 360 m (120 s), the switch is 120 s after that.
        val first = r.states.indexOfFirst { it?.racing == TrailGhost.Racing.last }
        assertTrue(first in 235..250, "switched at fix $first")
    }

    @Test
    fun `a short bad patch does not slip`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 480.0 to 0.0))
        assertTrue(r.states.filterNotNull().all { it.racing == TrailGhost.Racing.best })
        assertTrue(g.drainSwitches().isEmpty())
    }

    @Test
    fun `recovering within the floor goes back to the best`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val slow = Runner(g, mps = 3.0)
        slow.run(listOf(0.0 to 0.0, 800.0 to 0.0))
        assertEquals(TrailGhost.Racing.last, slow.states.last()!!.racing)
        val fast = Runner(g, mps = 6.0, startActiveMs = slow.activeMs).also { it.t = slow.t; it.distM = slow.distM }
        fast.run(listOf(800.0 to 0.0, 2_000.0 to 0.0))
        assertEquals(TrailGhost.Racing.best, fast.states.last()!!.racing)
        assertEquals(listOf(true, false), g.drainSwitches().map { it.toLast })
    }

    @Test
    fun `hovering between the two margins never flaps`() {
        // Behind the best by about 20 s: inside the 30 s enter margin, so it stays on the best for ever.
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 200.0 to 0.0))
        // 200 m at 3 m/s: 66.7 s vs 50 s, so 16.7 s behind. Now match the best's pace (4 m/s) for the rest.
        val level = Runner(g, mps = 4.0, startActiveMs = r.activeMs).also { it.t = r.t; it.distM = r.distM }
        level.run(listOf(200.0 to 0.0, 1_900.0 to 0.0))
        assertTrue(level.states.filterNotNull().all { it.racing == TrailGhost.Racing.best })
        assertTrue(g.drainSwitches().isEmpty())
    }

    @Test
    fun `when the last run is the best there is nothing to slip to`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight, lastMps = null)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 900.0 to 0.0))
        assertTrue(r.states.filterNotNull().all { it.racing == TrailGhost.Racing.best })
        assertTrue(g.drainSwitches().isEmpty())
    }

    @Test
    fun `between the exit and enter margins the lead stays where it is`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val slow = Runner(g, mps = 3.0)
        slow.run(listOf(0.0 to 0.0, 800.0 to 0.0))
        // 330 m at 8 m/s wins back about 41 s of the 67 s: about 26 s behind, past the 30 s enter margin but not inside half of it.
        val surge = Runner(g, mps = 8.0, startActiveMs = slow.activeMs).also { it.t = slow.t; it.distM = slow.distM }
        surge.run(listOf(800.0 to 0.0, 1_130.0 to 0.0))
        val level = Runner(g, mps = 4.0, startActiveMs = surge.activeMs).also { it.t = surge.t; it.distM = surge.distM }
        level.run(listOf(1_130.0 to 0.0, 1_900.0 to 0.0))
        assertTrue(level.states.filterNotNull().all { it.racing == TrailGhost.Racing.last })
        assertEquals(listOf(true), g.drainSwitches().map { it.toLast })
    }

    @Test
    fun `a shortcut is never time gained`() {
        val u = listOf(0.0 to 0.0, 800.0 to 0.0, 800.0 to 400.0, 0.0 to 400.0)
        // Best and last both at 4 m/s; the runner too, but cuts the corner (566 m instead of 800 m of trail).
        val g = TrailGhost(listOf(TrailGhostKit.trail(u, bestMps = 4.0, lastMps = null)))
        val r = Runner(g, mps = 4.0)
        r.run(listOf(0.0 to 0.0, 800.0 to 0.0, 400.0 to 400.0, 0.0 to 400.0))
        val figures = r.states.filterNotNull().mapNotNull { it.aheadBestMs }
        assertTrue(figures.isNotEmpty())
        // At the best's own pace the figure stays level; the skipped ground would have read about a minute ahead.
        assertTrue(figures.all { it in -20_000..20_000 }, "figures $figures".take(300))
        // Right after the rejoin there is no figure until 100 m are covered again.
        val last = r.states.last()!!
        assertTrue(last.alongM > 1_400)
    }

    @Test
    fun `a pause or a gap does not count towards the hold`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 3.0)
        // 480 m: well past the 30 s margin, 100 s of the 120 s hold.
        r.run(listOf(0.0 to 0.0, 480.0 to 0.0))
        assertTrue(g.drainSwitches().isEmpty())
        // Five minutes with no fixes (a pause, a dropout): the active clock stands still.
        val after = Runner(g, mps = 3.0, startActiveMs = r.activeMs).also { it.t = r.t + 300_000; it.distM = r.distM }
        after.run(listOf(480.0 to 0.0, 520.0 to 0.0))
        assertTrue(g.drainSwitches().isEmpty(), "the first fixes after the gap must not switch")
        after.run(listOf(520.0 to 0.0, 800.0 to 0.0))
        assertEquals(listOf(true), g.drainSwitches().map { it.toLast })
    }

    @Test
    fun `a shortcut while racing the last run is not a recovery`() {
        val u = listOf(0.0 to 0.0, 800.0 to 0.0, 800.0 to 400.0, 0.0 to 400.0)
        val g = TrailGhost(listOf(TrailGhostKit.trail(u, bestMps = 4.0, lastMps = 3.5)))
        val r = Runner(g, mps = 3.0)
        r.run(listOf(0.0 to 0.0, 800.0 to 0.0))
        assertEquals(listOf(true), g.drainSwitches().map { it.toLast })
        // Cut the corner, then carry on at the same slow pace for 100 s.
        r.run(listOf(800.0 to 0.0, 400.0 to 400.0, 250.0 to 400.0))
        assertTrue(g.drainSwitches().none { !it.toLast }, "no Back to your best from a cut corner")
        assertEquals(TrailGhost.Racing.last, r.states.last()!!.racing)
    }

    @Test
    fun `a warm up wobble before the trail is confirmed does not end it`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g, mps = 2.0)
        // On the line at the car park, then 15 s of GPS drift far off it, then the run proper.
        repeat(3) { r.fix(5.0, 0.0) }
        repeat(15) { r.fix(5.0, 90.0) }
        r.run(listOf(5.0 to 0.0, 700.0 to 0.0))
        assertEquals("t1", r.states.last()?.trailId)
    }

    @Test
    fun `lead changes queued while a run is rebuilt are drained and never come back`() {
        // The recorder replays a killed run's fixes through the ghost, then drains: the switches the replay queued are
        // gone, so the first live tick says nothing about them.
        val feed = TrailGhostFeed(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(TrailGhost(listOf(TrailGhostKit.trail(straight))), mps = 3.0)
        r.run(listOf(0.0 to 0.0, 900.0 to 0.0))
        for (i in 0..300) feed.offer(i * 1_000L, 0.0, 0.0, 5.0, i * 1_000L, 0.0)
        assertTrue(feed.drainSwitches().isEmpty())
        assertTrue(r.ghost.drainSwitches().isNotEmpty())
        assertTrue(r.ghost.drainSwitches().isEmpty(), "drained once, gone")
    }

    @Test
    fun `gone a long way the readout goes quiet instead of saying off the trail`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 700.0 to 0.0))
        assertEquals("t1", r.states.last()?.trailId)
        // Leaves the line and keeps going away: off first, with the figures gone...
        r.run(listOf(700.0 to 0.0, 700.0 to 300.0))
        assertTrue(r.states.last()!!.off)
        // ...then, 500 m on, the readout goes quiet (dormant), not off the trail for ever.
        r.run(listOf(700.0 to 300.0, 700.0 to 900.0))
        assertNull(r.states.last())
        assertTrue(r.states.takeLast(30).all { it == null })
    }

    @Test
    fun `a short detour comes back to the readout`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 700.0 to 0.0, 700.0 to 120.0, 700.0 to 0.0, 1_100.0 to 0.0))
        assertEquals("t1", r.states.last()?.trailId)
        assertFalse(r.states.last()!!.off)
    }

    @Test
    fun `800 m away and back on the trail the readout returns after a clean rejoin`() {
        val g = TrailGhost(listOf(TrailGhostKit.trail(straight)))
        val r = Runner(g)
        r.run(listOf(0.0 to 0.0, 700.0 to 0.0, 700.0 to 800.0))
        assertNull(r.states.last(), "quiet while far away")
        // Back to the line at 700 m: still quiet until 100 m of clean progress on it...
        r.run(listOf(700.0 to 800.0, 700.0 to 0.0))
        r.run(listOf(700.0 to 0.0, 760.0 to 0.0))
        assertNull(r.states.last())
        // ...then it is back, with figures only after the usual 100 m since the compare restarted.
        r.run(listOf(760.0 to 0.0, 1_400.0 to 0.0))
        val s = r.states.last()!!
        assertEquals("t1", s.trailId)
        assertFalse(s.off)
    }
}
