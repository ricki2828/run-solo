package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Voice coaching (Run Supreme brand build): smoothing, two off-band checks, timing, throttling,
 * priority and silence when on pace twice. Driven at 1 Hz like the recorder tick.
 */
class VoiceCoachTest {
    private val target = 300.0 // 5:00 per km, band +-5

    private fun status(full: Boolean = true, slowerIsFine: Boolean = false, band: Double = 5.0) =
        VoiceCoach(VoiceCoach.Config(full, targetPaceSecPerKm = target, bandSecPerKm = band, slowerIsFine = slowerIsFine))

    private fun at(
        t: Long,
        pace: Double? = target,
        segment: Int? = 0,
        active: Long = t,
        hr: Double? = null,
        toEnd: Long? = null,
        busyUntil: Long = 0,
        wide: Boolean = false,
    ) = VoiceCoach.Input(t, segment, active, pace, hr, toEnd, busyUntil, wide)

    private fun VoiceCoach.say(i: VoiceCoach.Input) = tick(i)?.text

    /** Ticks each second from [fromS] to [toS] inclusive, [pace] as given per second; the lines said, by second. */
    private fun VoiceCoach.run(
        fromS: Int,
        toS: Int,
        hr: Double? = null,
        segment: Int? = 0,
        wide: Boolean = false,
        pace: (Int) -> Double? = { target },
    ): List<Pair<Int, String>> = (fromS..toS).mapNotNull { s ->
        tick(at(s * 1_000L, pace = pace(s), segment = segment, hr = hr, wide = wide))?.let { s to it.text }
    }

    @Test
    fun `first status about 30 s into a segment, not before`() {
        val c = status()
        assertEquals(emptyList(), c.run(0, 29))
        assertEquals(listOf(30 to "On pace"), c.run(30, 31))
    }

    @Test
    fun `status words, with the band edges and plural`() {
        assertEquals(listOf(30 to "Ease off, 8 seconds fast"), status().run(0, 30) { 292.0 })
        assertEquals(listOf(30 to "Pick it up, 8 seconds slow"), status().run(0, 30) { 308.0 })
        assertEquals(listOf(30 to "Ease off, 1 second fast"), status(band = 0.4).run(0, 30) { 299.0 })
        assertEquals(listOf(30 to "On pace"), status().run(0, 30) { 295.0 }, "exactly the band is on pace")
        assertEquals(listOf(30 to "On pace"), status().run(0, 30) { 305.0 })
        assertEquals(listOf(30 to "Ease off, 5 seconds fast"), status().run(0, 30) { 294.6 })
    }

    @Test
    fun `the pace is smoothed over about 30 s, one noisy stretch does not make a line`() {
        // Two quick ticks (a gate, a gap in the trees) inside an on-pace window: the mean stays on pace.
        val c = status()
        val said = c.run(0, 60) { s -> if (s in 5..6) 270.0 else target }
        assertTrue(said.none { it.second.startsWith("Ease off") }, "$said")
    }

    @Test
    fun `needs two off-band checks in a row, and a check back in the band resets that`() {
        // Off at the 15 s check, on at 30 s: nothing; then off twice again: the line comes at the second.
        val c = status()
        val said = c.run(0, 75) { s -> if (s < 15) 290.0 else if (s < 45) target else 290.0 }
        assertTrue(said.none { it.second.startsWith("Ease off") && it.first < 60 }, "$said")
        // Straight off-band from the start: the first possible line is at 30 s (checks at 15 s and 30 s).
        assertEquals(30, status().run(0, 60) { 290.0 }.first().first)
    }

    @Test
    fun `at most every 60 s after the first`() {
        val c = status()
        val said = c.run(0, 200) { 290.0 }
        assertEquals(listOf(30, 90, 150), said.map { it.first })
    }

    @Test
    fun `silent when on pace twice in a row, speaks again when off pace, and on pace again after that`() {
        val c = status()
        val said = c.run(0, 330) { s -> if (s in 180..239) 320.0 else target }
        assertEquals(30 to "On pace", said.first())
        assertEquals(listOf("On pace", "Pick it up, 20 seconds slow", "On pace"), said.map { it.second }, "$said")
        assertTrue(said[1].first in 180..240, "$said")
    }

    @Test
    fun `a new rep starts the clock, the smoothing and the on-pace streak again`() {
        val c = status()
        assertEquals(listOf(30 to "On pace"), c.run(0, 30))
        assertNull(c.say(at(31_000, segment = null, active = 0)), "recovery: nothing")
        val rep2 = (40..70).mapNotNull { s -> c.tick(at(s * 1_000L, segment = 2, active = (s - 40) * 1_000L))?.let { s to it.text } }
        assertEquals(listOf(70 to "On pace"), rep2)
    }

    @Test
    fun `no pace now waits for one rather than skipping the slot`() {
        val c = status()
        assertEquals(emptyList(), c.run(0, 45) { null })
        assertEquals(emptyList(), c.run(46, 50) { 290.0 }, "needs ~10 smoothed ticks first")
        assertEquals(1, c.run(51, 70) { 290.0 }.size)
    }

    @Test
    fun `easy-run ceiling, slow is on target and fast is not`() {
        val c = status(slowerIsFine = true)
        assertEquals(listOf(30 to "On pace"), c.run(0, 30) { 340.0 })
        val fast = c.run(31, 150) { 288.0 }
        assertEquals("Ease off, 12 seconds fast", fast.first().second)
    }

    @Test
    fun `wider band on trail or steep ground`() {
        // 7 s/km fast: off the 5 band, inside the 8 band.
        assertEquals(listOf(30 to "Ease off, 7 seconds fast"), status().run(0, 30) { 293.0 })
        assertEquals(listOf(30 to "On pace"), status().run(0, 30, wide = true) { 293.0 })
        assertEquals(listOf(30 to "Ease off, 9 seconds fast"), status().run(0, 30, wide = true) { 291.0 })
    }

    @Test
    fun `Minimal detail and no target say no status`() {
        assertEquals(emptyList(), status(full = false).run(0, 100) { 250.0 })
        assertEquals(emptyList(), VoiceCoach(VoiceCoach.Config(true)).run(0, 100) { 250.0 })
    }

    @Test
    fun `speech already queued drops a due status once it is 3 s stale`() {
        val c = status()
        for (s in 0..29) c.say(at(s * 1_000L, pace = 290.0))
        assertNull(c.say(at(30_000, pace = 290.0, busyUntil = 40_000)), "due but busy: wait")
        assertNull(c.say(at(32_999, pace = 290.0, busyUntil = 40_000)))
        assertNull(c.say(at(33_001, pace = 290.0)), "stale: dropped, though speech has cleared")
        for (s in 34..92) assertNull(c.say(at(s * 1_000L, pace = 290.0)), "t=$s")
        assertEquals("Ease off, 10 seconds fast", c.say(at(93_001, pace = 290.0)))
    }

    @Test
    fun `busy for under 3 s is still said`() {
        val c = status()
        for (s in 0..29) c.say(at(s * 1_000L, pace = 290.0))
        assertNull(c.say(at(30_000, pace = 290.0, busyUntil = 31_500)))
        assertEquals("Ease off, 10 seconds fast", c.say(at(31_500, pace = 290.0, busyUntil = 31_500)))
    }

    @Test
    fun `nothing is said within 12 s of a part ending, the next-step cue owns it`() {
        val c = status()
        for (s in 0..29) c.say(at(s * 1_000L, pace = 290.0))
        assertNull(c.say(at(30_000, pace = 290.0, toEnd = 12_000)))
        assertNull(c.say(at(31_000, pace = 290.0, toEnd = 11_000)))
        assertEquals("Ease off, 10 seconds fast", c.say(at(32_000, pace = 290.0, toEnd = 12_001)))
    }

    // ---- zone drift ----

    // Zones 2..5 bottoms for max 190: 114, 133, 152, 171.
    private val bottoms = listOf(114.0, 133.0, 152.0, 171.0)

    private fun drift() = VoiceCoach(VoiceCoach.Config(true, zoneBottomsBpm = bottoms, plannedMaxZone = 2))

    @Test
    fun `drift after 60 s continuously above the planned zone`() {
        val c = drift()
        assertNull(c.say(at(0, hr = 160.0)))
        assertNull(c.say(at(59_999, hr = 160.0)))
        assertEquals("Heart rate in zone 4. Ease back to zone 2.", c.say(at(60_000, hr = 160.0)))
    }

    @Test
    fun `dipping back into the zone restarts the minute`() {
        val c = drift()
        assertNull(c.say(at(0, hr = 140.0)))
        assertNull(c.say(at(50_000, hr = 140.0)))
        assertNull(c.say(at(51_000, hr = 120.0)), "zone 2 again")
        assertNull(c.say(at(52_000, hr = 140.0)))
        assertNull(c.say(at(111_999, hr = 140.0)))
        assertEquals("Heart rate in zone 3. Ease back to zone 2.", c.say(at(112_000, hr = 140.0)))
    }

    @Test
    fun `drift at most once every 3 minutes`() {
        val c = drift()
        c.say(at(0, hr = 160.0))
        assertEquals("Heart rate in zone 4. Ease back to zone 2.", c.say(at(60_000, hr = 160.0)))
        for (s in 61..239) assertNull(c.say(at(s * 1_000L, hr = 160.0)), "t=$s")
        assertEquals("Heart rate in zone 5. Ease back to zone 2.", c.say(at(240_000, hr = 175.0)))
    }

    @Test
    fun `no strap is silent, and losing the strap restarts the minute`() {
        val c = drift()
        for (s in 0..200 step 10) assertNull(c.say(at(s * 1_000L, hr = null)))
        val d = drift()
        d.say(at(0, hr = 160.0))
        assertNull(d.say(at(40_000, hr = null)))
        assertNull(d.say(at(41_000, hr = 160.0)))
        assertNull(d.say(at(100_999, hr = 160.0)))
        assertEquals("Heart rate in zone 4. Ease back to zone 2.", d.say(at(101_000, hr = 160.0)))
    }

    @Test
    fun `drift is off with no planned zone, and in Minimal`() {
        val noPlan = VoiceCoach(VoiceCoach.Config(true, zoneBottomsBpm = bottoms))
        assertNull(noPlan.say(at(0, hr = 180.0)))
        assertNull(noPlan.say(at(120_000, hr = 180.0)))
        val minimal = VoiceCoach(VoiceCoach.Config(false, zoneBottomsBpm = bottoms, plannedMaxZone = 2))
        assertNull(minimal.say(at(0, hr = 180.0)))
        assertNull(minimal.say(at(120_000, hr = 180.0)))
    }

    @Test
    fun `a pause restarts the minute`() {
        val c = drift()
        c.say(at(0, hr = 160.0))
        assertNull(c.say(at(30_000, segment = null, hr = 160.0)))
        assertNull(c.say(at(31_000, hr = 160.0)))
        assertNull(c.say(at(90_999, hr = 160.0)))
        assertEquals("Heart rate in zone 4. Ease back to zone 2.", c.say(at(91_000, hr = 160.0)))
    }

    // ---- priority ----

    private fun both() = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target, zoneBottomsBpm = bottoms, plannedMaxZone = 2))

    @Test
    fun `drift outranks status when both are due, and a status due while it speaks goes stale`() {
        val c = both()
        // On pace and under zone 3 to 30 s ("On pace" said), then fast and above the zone from 31 s.
        for (s in 0..29) c.say(at(s * 1_000L, pace = target, hr = 120.0))
        assertEquals("On pace", c.say(at(30_000, pace = target, hr = 120.0)))
        for (s in 31..89) assertNull(c.say(at(s * 1_000L, pace = 290.0, hr = 160.0)), "t=$s")
        // 90 s: the status slot and the drift (above since 31 s... due at 91 s) are both near; drift is first.
        val line = c.tick(at(91_000, pace = 290.0, hr = 160.0))
        assertEquals(VoiceCoach.Kind.drift, line?.kind)
        assertNull(c.say(at(92_000, pace = 290.0, hr = 160.0, busyUntil = 95_000)), "status waits behind the drift line")
        assertNull(c.say(at(95_001, pace = 290.0, hr = 160.0)), "and went stale, not said late")
    }

    @Test
    fun `a drift line that is waiting for speech to clear goes first once it does`() {
        val c = both()
        for (s in 0..29) c.say(at(s * 1_000L, pace = target, hr = 120.0))
        assertEquals("On pace", c.say(at(30_000, pace = target, hr = 120.0)))
        for (s in 31..90) assertNull(c.say(at(s * 1_000L, pace = target, hr = 160.0)), "t=$s")
        assertNull(c.say(at(91_000, pace = target, hr = 160.0, busyUntil = 92_000)), "busy: nothing speaks")
        assertEquals(VoiceCoach.Kind.drift, c.tick(at(92_000, pace = target, hr = 160.0))?.kind)
    }
}
