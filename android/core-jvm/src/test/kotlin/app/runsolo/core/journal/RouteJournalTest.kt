package app.runsolo.core.journal

import app.runsolo.core.model.RunMode
import app.runsolo.core.model.Units
import app.runsolo.core.route.FollowRoute
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

/** Follow a route: the `route` journal line, so a restore after a kill keeps following. */
class RouteJournalTest {
    private val t0 = 100_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.trail, null, Units.km)
    private val route = FollowRoute(
        "r1", "Hill loop",
        listOf(-33.86, 151.2, -33.861, 151.201, -33.862, 151.202),
        listOf(10.0, 12.5, 15.0),
    )

    private fun enc(vararg lines: JournalLine) = lines.joinToString("") { JournalCodec.encode(it) + "\n" }

    @Test
    fun `the route line round trips with and without elevation`() {
        val a = JournalLine.RouteLine(t0, w0, route)
        val back = (JournalCodec.decode(JournalCodec.encode(a)) as JournalLine.RouteLine).route
        assertEquals(route.latLon, back.latLon)
        assertEquals(route.elevM, back.elevM)
        assertEquals("Hill loop", back.name)
        val flat = FollowRoute("r2", "Flat", route.latLon)
        assertNull((JournalCodec.decode(JournalCodec.encode(JournalLine.RouteLine(t0, w0, flat))) as JournalLine.RouteLine).route.elevM)
    }

    @Test
    fun `replay hands the route back and keeps it off the run timeline`() {
        val bytes = enc(header, JournalLine.RouteLine(t0, w0, route), JournalLine.Sample(t0 + 1_000, w0 + 1_000, -33.86, 151.2, null, 5.0, 3.0, null)).toByteArray()
        val replay = JournalReplay.read(bytes)
        assertEquals(route.latLon, replay.route!!.latLon)
        assertEquals(1, replay.events.size)
        assertEquals(0, replay.badLines)
    }

    @Test
    fun `a journal with no route line replays with no route`() {
        assertNull(JournalReplay.read(enc(header).toByteArray()).route)
    }

    @Test
    fun `a route must be pairs, finite, in range and one elevation per point`() {
        assertFailsWith<IllegalArgumentException> { FollowRoute("x", "x", listOf(1.0)) }
        assertFailsWith<IllegalArgumentException> { FollowRoute("x", "x", listOf(1.0, 2.0)) }
        assertFailsWith<IllegalArgumentException> { FollowRoute("x", "x", listOf(95.0, 2.0, 1.0, 2.0)) }
        assertFailsWith<IllegalArgumentException> { FollowRoute("x", "x", listOf(Double.NaN, 2.0, 1.0, 2.0)) }
        assertFailsWith<IllegalArgumentException> { FollowRoute("x", "x", listOf(1.0, 2.0, 1.0, 3.0), listOf(1.0)) }
    }
}
