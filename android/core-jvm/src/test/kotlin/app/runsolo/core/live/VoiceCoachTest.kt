package app.runsolo.core.live

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Voice coaching (Run Supreme brand build): timing, throttling, priority and silence when on pace twice. */
class VoiceCoachTest {
    private val target = 300.0 // 5:00 per km, band ±5

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
    ) = VoiceCoach.Input(t, segment, active, pace, hr, toEnd, busyUntil)

    private fun VoiceCoach.say(i: VoiceCoach.Input) = tick(i)?.text

    @Test
    fun `first status about 30 s into a segment, not before`() {
        val c = status()
        assertNull(c.say(at(29_000)))
        assertEquals("On pace", c.say(at(30_000)))
    }

    @Test
    fun `status words, with the band edges and plural`() {
        assertEquals("Ease off, 8 seconds fast", status().say(at(30_000, pace = 292.0)))
        assertEquals("Pick it up, 8 seconds slow", status().say(at(30_000, pace = 308.0)))
        assertEquals("Ease off, 1 second fast", status(band = 0.4).say(at(30_000, pace = 299.0)))
        assertEquals("On pace", status().say(at(30_000, pace = 295.0)), "exactly the band is on pace")
        assertEquals("On pace", status().say(at(30_000, pace = 305.0)))
        assertEquals("Ease off, 5 seconds fast", status().say(at(30_000, pace = 294.6)))
    }

    @Test
    fun `at most every 60 s after the first`() {
        val c = status()
        assertEquals("Ease off, 10 seconds fast", c.say(at(30_000, pace = 290.0)))
        for (s in 31..89) assertNull(c.say(at(s * 1_000L, pace = 290.0)), "t=$s")
        assertEquals("Ease off, 10 seconds fast", c.say(at(90_000, pace = 290.0)))
    }

    @Test
    fun `silent when on pace twice in a row, speaks again when off pace, and on pace again after that`() {
        val c = status()
        assertEquals("On pace", c.say(at(30_000)))
        assertNull(c.say(at(90_000)), "second on pace in a row")
        assertNull(c.say(at(150_000)), "and the third")
        assertEquals("Pick it up, 20 seconds slow", c.say(at(210_000, pace = 320.0)))
        assertEquals("On pace", c.say(at(270_000)), "back on pace after being off: said once")
        assertNull(c.say(at(330_000)))
    }

    @Test
    fun `a new rep starts the clock and the on-pace streak again`() {
        val c = status()
        assertEquals("On pace", c.say(at(30_000, segment = 0, active = 30_000)))
        assertNull(c.say(at(31_000, segment = null, active = 0)), "recovery: nothing")
        assertNull(c.say(at(40_000, segment = 2, active = 5_000)), "5 s into rep 2")
        assertEquals("On pace", c.say(at(65_000, segment = 2, active = 30_000)))
    }

    @Test
    fun `no pace now waits for one rather than skipping the slot`() {
        val c = status()
        assertNull(c.say(at(30_000, pace = null)))
        assertNull(c.say(at(40_000, pace = null)))
        assertEquals("On pace", c.say(at(41_000)))
    }

    @Test
    fun `easy-run ceiling, slow is on target and fast is not`() {
        val c = status(slowerIsFine = true)
        assertEquals("On pace", c.say(at(30_000, pace = 340.0)))
        assertEquals("Ease off, 12 seconds fast", c.say(at(90_000, pace = 288.0)))
    }

    @Test
    fun `Minimal detail and no target say no status`() {
        assertNull(status(full = false).say(at(30_000, pace = 250.0)))
        assertNull(VoiceCoach(VoiceCoach.Config(true)).say(at(30_000, pace = 250.0)))
    }

    @Test
    fun `speech already queued drops a due status once it is 3 s stale`() {
        val c = status()
        assertNull(c.say(at(30_000, pace = 290.0, busyUntil = 40_000)), "due but busy: wait")
        assertNull(c.say(at(32_999, pace = 290.0, busyUntil = 40_000)))
        assertNull(c.say(at(33_001, pace = 290.0, busyUntil = 40_000)), "stale: dropped, even though idle after")
        assertNull(c.say(at(41_000, pace = 290.0)), "the slot is gone; next at 60 s after")
        assertEquals("Ease off, 10 seconds fast", c.say(at(93_001, pace = 290.0)))
    }

    @Test
    fun `busy for under 3 s is still said`() {
        val c = status()
        assertNull(c.say(at(30_000, pace = 290.0, busyUntil = 31_500)))
        assertEquals("Ease off, 10 seconds fast", c.say(at(31_500, pace = 290.0, busyUntil = 31_500)))
    }

    @Test
    fun `nothing is said within 12 s of a part ending, the next-step cue owns it`() {
        val c = status()
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

    @Test
    fun `drift outranks status when both are due, and a status due while it speaks goes stale`() {
        val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target, zoneBottomsBpm = bottoms, plannedMaxZone = 2))
        assertNull(c.say(at(0, pace = target, hr = 160.0)))
        val line = c.tick(at(60_000, pace = 290.0, hr = 160.0))
        assertEquals(VoiceCoach.Kind.drift, line?.kind, "both were due: drift")
        assertNull(c.say(at(60_500, pace = 290.0, hr = 160.0, busyUntil = 63_500)), "the status waits behind the drift line")
        assertNull(c.say(at(63_501, pace = 290.0, hr = 160.0)), "and was dropped as stale (3 s), not said late")
    }

    @Test
    fun `status is never said over a drift line that is waiting for speech to clear`() {
        val c = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = target, zoneBottomsBpm = bottoms, plannedMaxZone = 2))
        c.say(at(0, pace = target, hr = 160.0))
        assertNull(c.say(at(60_000, pace = 290.0, hr = 160.0, busyUntil = 61_000)), "busy: neither speaks")
        val line = c.tick(at(61_000, pace = 290.0, hr = 160.0))
        assertEquals(VoiceCoach.Kind.drift, line?.kind, "drift first once idle")
    }
}
