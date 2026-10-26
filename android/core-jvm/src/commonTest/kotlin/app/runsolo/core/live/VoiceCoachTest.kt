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
    fun `first status about 30 s into a segment not before`() {
        val c = status()
        assertEquals(emptyList(), c.run(0, 29))
        assertEquals(listOf(30 to "On pace"), c.run(30, 31))
    }

    @Test
    fun `status words with the band edges and plural`() {
        assertEquals(listOf(30 to "Ease off, 8 seconds fast"), status().run(0, 30) { 292.0 })
        assertEquals(listOf(30 to "Pick it up, 8 seconds slow"), status().run(0, 30) { 308.0 })
        assertEquals(listOf(30 to "Ease off, 1 second fast"), status(band = 0.4).run(0, 30) { 299.0 })
        assertEquals(listOf(30 to "On pace"), status().run(0, 30) { 295.0 }, "exactly the band is on pace")
        assertEquals(listOf(30 to "On pace"), status().run(0, 30) { 305.0 })
        assertEquals(listOf(30 to "Ease off, 5 seconds fast"), status().run(0, 30) { 294.6 })
    }

    @Test
    fun `the pace is smoothed over about 30 s one noisy stretch does not make a line`() {
        // Two quick ticks (a gate, a gap in the trees) inside an on-pace window: the mean stays on pace.
        val c = status()
        val said = c.run(0, 60) { s -> if (s in 5..6) 270.0 else target }
        assertTrue(said.none { it.second.startsWith("Ease off") }, "$said")
    }

    @Test
    fun `needs two off-band checks in a row and a check back in the band resets that`() {
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
    fun `silent when on pace twice in a row speaks again when off pace and on pace again after that`() {
        val c = status()
        val said = c.run(0, 330) { s -> if (s in 180..239) 320.0 else target }
        assertEquals(30 to "On pace", said.first())
        assertEquals(listOf("On pace", "Pick it up, 20 seconds slow", "On pace"), said.map { it.second }, "$said")
        assertTrue(said[1].first in 180..240, "$said")
    }

    @Test
    fun `a new rep starts the clock the smoothing and the on-pace streak again`() {
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
    fun `easy-run ceiling slow is on target and fast is not`() {
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
    fun `nothing is said within 12 s of a part ending the next-step cue owns it`() {
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
    fun `no strap is silent and losing the strap restarts the minute`() {
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
    fun `drift is off with no planned zone and in Minimal`() {
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
    fun `drift outranks status when both are due and a status due while it speaks goes stale`() {
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

    // ---- goal run with a target time: descriptive, never "Ease off" (26-Oct goal-run voice) ----

    private val goalMs = 1_470_000L // 24:30 for 5 km: 294 s/km
    private val goalTarget = app.runsolo.core.model.LiveTarget(5_000.0, goalMs, predicted = true) // a goal target is always a prediction in production

    private fun goalCoach() = VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = 294.0))

    /** A run at 1 Hz: [pace] (s/km) at each distance; the lines said, with the second. */
    private fun VoiceCoach.goalRun(untilM: Double, jumpAtS: Int? = null, pace: (Double) -> Double): List<Pair<Int, String>> {
        val said = ArrayList<Pair<Int, String>>()
        var d = 0.0
        var s = 0
        while (d < untilM) {
            s++
            val p = pace(d)
            d += 1_000.0 / p
            if (s == jumpAtS) d += 150.0 // a GPS leap: 150 m that were never run
            val t = s * 1_000L
            tick(VoiceCoach.Input(t, 0, t, p, null, null, 0, false, VoiceCoach.GoalProgress(goalTarget, d, t)))?.let { said.add(s to it.text) }
        }
        return said
    }

    @Test
    fun `replay 30 s ahead at 2 km then losing 8 s per km never says ease off and names 24-30 and shrinking`() {
        // 279 s/km to 2 km (558 s, 30 s up on 294 s/km), then 302 s/km: the lead drops 8 s each km.
        val said = goalCoach().goalRun(4_600.0) { d -> if (d < 2_000.0) 279.0 else 302.0 }
        assertTrue(said.isNotEmpty(), "$said")
        for ((_, text) in said) {
            assertTrue(text.contains("24:30"), text)
            assertTrue(!text.contains("ease", ignoreCase = true) && !text.contains("pick it up", ignoreCase = true), text)
            assertTrue(CueWordsCount.of(text) <= 9, text)
        }
        assertTrue(said.any { it.second.endsWith("ahead of 24:30, margin shrinking") }, "$said")
    }

    @Test
    fun `a goal run says nothing before the first km and an on-goal run says on 24-30 pace once`() {
        val said = goalCoach().goalRun(4_000.0) { 294.0 }
        assertTrue(said.first().first >= 294, "first line after km 1: $said")
        assertEquals(listOf("On your predicted 24:30 pace"), said.map { it.second }, "predicted once, and a level run says nothing more")
        assertEquals(1, said.size, "the same line is not said twice running: $said")
    }

    @Test
    fun `behind and holding is described not ordered and ease off being picked does not silence it`() {
        val c = goalCoach()
        c.applyEffect(PromptEffect.EASE)
        // 10 s down after km 1 (304 s/km), then level with the goal pace: the gap holds.
        val said = c.goalRun(4_000.0) { d -> if (d < 1_000.0) 304.0 else 294.0 }
        assertTrue(said.isNotEmpty(), "$said")
        assertTrue(said.all { it.second.contains("behind") && it.second.contains("24:30") }, "$said")
        assertTrue(said.any { it.second.endsWith("holding") }, "$said")
    }

    @Test
    fun `predicted is said once on the first line then the time is bare`() {
        val said = goalCoach().goalRun(4_600.0) { d -> if (d < 2_000.0) 279.0 else 302.0 }.map { it.second }
        assertTrue(said.first().contains("your predicted 24:30"), said.first())
        assertTrue(said.drop(1).none { it.contains("predicted") }, "$said")
    }

    @Test
    fun `a creeping margin does not talk every minute - at most a line a km`() {
        // 10 s up after km 1, then 1 s/km more: the number creeps, the trend is steady, nothing changes.
        val said = goalCoach().goalRun(4_600.0) { d -> if (d < 1_000.0) 284.0 else 293.0 }
        assertTrue(said.size in 1..5, "one a km at most, not one a minute: $said")
        assertTrue(said.zipWithNext().all { (a, b) -> b.first - a.first >= 60 }, "$said")
    }

    @Test
    fun `a fade that turns the trend is said inside the next km`() {
        // 20 s up at km 1, level to km 2, then -6 s a km: the trend turns at km 3.
        val said = goalCoach().goalRun(4_600.0) { d -> if (d < 1_000.0) 274.0 else if (d < 2_000.0) 294.0 else 300.0 }
        assertTrue(said.any { it.second.endsWith("margin shrinking") }, "$said")
    }

    @Test
    fun `far behind is said once a km at most`() {
        // 36 s a km behind: past a minute from km 2. Each km a line, not a line a minute.
        val said = goalCoach().goalRun(4_600.0) { 330.0 }
        // Past a minute behind (about 510 s on): the new-km floor only, km 2, 3 and 4.
        assertTrue(said.filter { it.first > 600 }.size <= 3, "once a km: $said")
        assertTrue(said.all { it.second.contains("behind") }, "$said")
    }

    @Test
    fun `on pace has hysteresis - a margin wobbling around 3 s does not flip the line`() {
        // Level for km 1 and 2, then about 4 s ahead (inside the 5 s exit): still level, no new line.
        val said = goalCoach().goalRun(3_900.0) { d -> if (d < 2_000.0) 294.0 else if (d < 3_000.0) 290.0 else 294.0 }
        assertTrue(said.all { it.second.startsWith("On ") }, "$said")
    }

    @Test
    fun `a dropout catch-up - flat for 30 s then 100 m in one tick - leaves the margin sane and says nothing behind`() {
        val c = goalCoach()
        val said = ArrayList<Pair<Int, String>>()
        var d = 0.0
        var t = 0
        while (d < 3_500.0) {
            t++
            when (t) {
                in 442..471 -> Unit // no fixes: the distance stands still
                472 -> d += 31 * 1_000.0 / 294 // the first good fix: the whole span lands at once
                else -> d += 1_000.0 / 294
            }
            val ms = t * 1_000L
            c.tick(VoiceCoach.Input(ms, 0, ms, 294.0, null, null, 0, false, VoiceCoach.GoalProgress(goalTarget, d, ms)))?.let { said.add(t to it.text) }
        }
        val after = said.filter { it.first >= 472 }
        assertTrue(after.isNotEmpty() || said.isNotEmpty(), "$said")
        assertTrue(after.none { it.second.contains("behind") || it.second.contains("slipping") }, "no false behind after the catch-up: $said")
        assertTrue(said.all { it.second.startsWith("On ") }, "level on pace throughout the lines said: $said")
    }

    @Test
    fun `level but losing ground says so - on pace and slipping`() {
        // +2 s at km 1 (level), 4 s lost in km 2: -2 s is still level, but the trend is shrinking.
        val said = goalCoach().goalRun(3_500.0) { d -> if (d < 1_000.0) 292.0 else if (d < 2_000.0) 298.0 else 294.0 }.map { it.second }
        assertEquals("On your predicted 24:30 pace", said.first())
        assertTrue(said.contains("On 24:30 pace, slipping"), "$said")
    }

    @Test
    fun `plus 3 s and losing 8 s a km says slipping at the first line after the km`() {
        val said = goalCoach().goalRun(3_500.0) { d -> if (d < 1_000.0) 292.0 else 302.0 }
        assertEquals("On your predicted 24:30 pace", said.first().second)
        // Km 2 ends at 594 s; the first line after it carries the trend.
        assertTrue(said.first { it.first >= 594 }.second.endsWith("slipping"), "$said")
    }

    @Test
    fun `without a goal the same fast pace still says ease off`() {
        // The gate: only a goal run with a target time changes. Everything else is as before.
        assertEquals(listOf(30 to "Ease off, 15 seconds fast"), VoiceCoach(VoiceCoach.Config(true, targetPaceSecPerKm = 294.0)).run(0, 30) { 279.0 })
    }

    private fun free() = VoiceCoach(VoiceCoach.Config(true, zoneBottomsBpm = bottoms))

    /** Ticks each second from [fromS] to [toS] at [hr]; the lines said, by second. */
    private fun VoiceCoach.hrRun(fromS: Int, toS: Int, hr: (Int) -> Double?, busyUntil: Long = 0) =
        (fromS..toS).mapNotNull { s -> tick(at(s * 1_000L, pace = null, hr = hr(s), busyUntil = busyUntil))?.let { s to it.text } }

    @Test
    fun `zone up says each zone from 3 the first time it is held 20 s`() {
        val said = free().hrRun(0, 600, hr = { s ->
            when {
                s < 100 -> 125.0 // zone 2: never said
                s < 200 -> 140.0 // zone 3
                s < 300 -> 125.0 // back to 2
                s < 400 -> 140.0 // zone 3 again: already said
                else -> 160.0 // zone 4
            }
        })
        assertEquals(listOf(120 to "Heart rate up to zone 3.", 420 to "Heart rate up to zone 4."), said)
    }

    @Test
    fun `a spike under 20 s is not a new zone`() {
        val said = free().hrRun(0, 300, hr = { s -> if (s in 100..115) 160.0 else 125.0 })
        assertTrue(said.isEmpty(), "$said")
    }

    @Test
    fun `climbing straight through a zone says only the one held`() {
        val said = free().hrRun(0, 300, hr = { s -> if (s < 10) 140.0 else 175.0 })
        assertEquals(listOf(20 to "Heart rate up to zone 5."), said)
        assertTrue(free().hrRun(0, 60, hr = { 175.0 }).size == 1)
    }

    @Test
    fun `zone up waits for a quiet moment and is said once`() {
        val c = free()
        assertTrue(c.hrRun(0, 60, hr = { 140.0 }, busyUntil = Long.MAX_VALUE).isEmpty())
        assertEquals(listOf(61 to "Heart rate up to zone 3."), c.hrRun(61, 200, hr = { 140.0 }))
    }

    @Test
    fun `on an easy run drift says the zone above plan, not zone up`() {
        val said = drift().hrRun(0, 120, hr = { 140.0 })
        assertEquals(listOf(60 to "Heart rate in zone 3. Ease back to zone 2."), said)
    }

    @Test
    fun `no zone up in a recovery or without zones`() {
        val c = free()
        for (s in 0..60) assertNull(c.say(at(s * 1_000L, pace = null, segment = null, hr = 160.0)))
        assertNull(c.say(at(80_000, pace = null, hr = 160.0)), "the 20 s starts with the rep")
        assertEquals("Heart rate up to zone 4.", c.say(at(100_000, pace = null, hr = 160.0)))
        val off = VoiceCoach(VoiceCoach.Config(true))
        for (s in 0..60) assertNull(off.say(at(s * 1_000L, pace = null, hr = 160.0)))
    }
}

private object CueWordsCount {
    fun of(s: String) = s.trim().split(Regex("\\s+")).size
}

