package app.runsolo.core.live

import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.LiveTarget
import app.runsolo.core.model.NudgePlan
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.RepFadeRule
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.record.RecorderCore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LiveCoachTest {
    private fun split(vararg kmMs: Long) = kmMs.toList()

    private fun fiveK(vararg entries: List<Long>) = LiveBoard(
        key = "be:5k", label = "5K", kind = LiveBoardKind.distance, targetM = 5_000.0,
        entries = entries.mapIndexed { i, s -> LiveEntry("r$i", 0, fromStartSplitsMs = s, finalMetric = s.last().toDouble()) },
    )

    private fun ctx(vararg boards: LiveBoard, target: LiveTarget? = null, history: List<Double>? = null, muted: Boolean = false) =
        LiveContext(boards = boards.toList(), target = target, cooperHistory = history, coachingMuted = muted, builtAtMs = 0, engineVersion = 1)

    // Six 5Ks: km 3 at 870, 880, 890, 900, 910, 920 s.
    private val six = fiveK(*(0 until 6).map { i -> List(5) { k -> (k + 1) * (290_000L + i * 3_333L) } }.toTypedArray())

    /** A Free run at a steady speed: the tick where km [km] is crossed at run time [atMs]. */
    private fun cross(coach: LiveCoach, km: Int, atMs: Long) =
        coach.onTick(atMs - 500, km * 1_000.0 - 2.0, atMs + 500, km * 1_000.0 + 2.0) { it }

    @Test
    fun `free km 3 - the split, then number 2 of 7, off the best by the gap at km 3`() {
        val coach = LiveCoach(ctx(six), RunMode.free, null)
        val k = assertNotNull(cross(coach, 3, 875_000))
        assertEquals("3 k, 14 minutes 35.", k.base, "no pace: kms 1 and 2 were not seen")
        val f = assertNotNull(k.fire)
        assertEquals(listOf(2, 7), listOf(f.result.rank, f.result.of))
        assertEquals(875_000L - 870_000L, f.result.deltaMs)
        assertEquals("2nd of 7, 5 seconds off your best.", f.text)
        assertTrue(f.speak)
        assertNull(cross(coach, 3, 876_000), "each km once")
        assertEquals("4 k, 19 minutes 30, pace 4:55.", cross(coach, 4, 1_170_000)!!.base)
    }

    @Test
    fun `free km 5 - best of 7 so far`() {
        val coach = LiveCoach(ctx(six), RunMode.free, null)
        assertEquals("Best of 7 so far, 10 seconds up.", cross(coach, 5, 1_440_000)!!.fire!!.text)
    }

    @Test
    fun `laps run - no km cue, the compare goes to the overlay only`() {
        val coach = LiveCoach(ctx(fiveK(split(300_000, 600_000, 912_000, 1_210_000, 1_512_000))), RunMode.laps, null)
        val k = assertNotNull(cross(coach, 3, 900_000))
        assertNull(k.base)
        assertEquals("12 seconds up on last time.", k.fire!!.text)
        assertFalse(k.fire!!.speak)
        assertNull(cross(LiveCoach(null, RunMode.laps, null), 3, 900_000))
    }

    @Test
    fun `free km splits for everyone, compares only with a board - off in settings, nothing`() {
        val plain = LiveCoach(null, RunMode.free, null)
        assertEquals("1 k, 5 minutes 7, pace 5:07.", cross(plain, 1, 307_000)!!.base)
        assertEquals("2 k, 10 minutes, pace 4:53.", cross(plain, 2, 600_000)!!.base)
        assertNull(cross(plain, 2, 600_000)?.fire)
        assertEquals("12 k, 1 hour 4, pace 5:00.", LiveWords.kmSplit(12, 3_845_000, 300_000))
        val short = fiveK(split(290_000, 580_000))
        assertNull(cross(LiveCoach(ctx(short), RunMode.free, null), 3, 875_000)!!.fire, "no entry has a km-3 split")
        assertNull(cross(LiveCoach(ctx(six), RunMode.free, null), 6, 1_800_000)!!.fire, "km 6 races the 10K board, which is absent")
        val off = LiveCoach(null, RunMode.free, null).also { it.kmSplits = false }
        assertNull(cross(off, 1, 307_000))
        val offWithBoard = LiveCoach(ctx(six), RunMode.free, null).also { it.kmSplits = false }
        assertFalse(cross(offWithBoard, 3, 875_000)!!.fire!!.speak, "no km cue to ride: overlay only")
    }

    @Test
    fun `muted - fires (overlay, journal) but is not spoken`() {
        val coach = LiveCoach(ctx(six, muted = true), RunMode.free, null)
        assertFalse(cross(coach, 3, 875_000)!!.fire!!.speak)
    }

    @Test
    fun `restore - journaled compares and passed kms never fire again`() {
        val fired = listOf(JournalLine.CueFired(0, 0, JournalLine.FiredKind.compare, "be:5k", 3, 875_000))
        val coach = LiveCoach(ctx(six), RunMode.free, null, fired)
        assertNull(cross(coach, 3, 875_000)!!.fire, "fired before the kill")
        val resumed = LiveCoach(ctx(six), RunMode.free, null)
        resumed.resumeAt(3_400.0)
        assertNull(cross(resumed, 3, 875_000), "passed while dead: dropped, never late")
        val k4 = assertNotNull(cross(resumed, 4, 1_170_000))
        assertEquals("4 k, 19 minutes 30.", k4.base, "the first split after a restore has no pace")
        assertNotNull(k4.fire)
    }

    // ---- intervals ----

    private val fourHundreds = SessionSpec(
        templateId = "400s", templateVersion = 1, name = "4 × 400 m", warmupSeconds = null, cooldownSeconds = null,
        lapLockout = false, cueProfile = CueProfile.standard, hrBand = null,
        steps = (1..4).flatMap { r ->
            listOfNotNull(Step(StepKind.work, TargetKind.distance, 400, RecoveryStyle.run, r), if (r < 4) Step(StepKind.recovery, TargetKind.time, 90, RecoveryStyle.jog, r) else null)
        },
    )

    private fun reps(vararg paces: List<Double?>) = LiveBoard(
        key = "d400x*", label = "400s", kind = LiveBoardKind.intervals,
        entries = paces.mapIndexed { i, p -> LiveEntry("p$i", 0, liveRepPacesSecPerKm = p, finalMetric = 0.0) },
    )

    /** Laps as the shell publishes them: cumulative distance and active time, with the core's [RecorderCore.LapStep]. */
    private class Laps(val coach: LiveCoach) {
        var d = 0.0
        var a = 0L
        fun lap(step: RecorderCore.LapStep, metres: Double, ms: Long) {
            d += metres
            a += ms
            coach.lapEnded(step, d, a)
        }
        fun warmUp() = lap(RecorderCore.LapStep(null, true), 150.0, 60_000)
        /** Work step [step] (400 m) at [pace] s/km ends here. */
        fun rep(step: Int, pace: Double) = lap(RecorderCore.LapStep(step, true), 400.0, (pace * 400).toLong())
        fun recovery(step: Int) = lap(RecorderCore.LapStep(step, true), 180.0, 90_000)
    }

    private fun repEnd(coach: LiveCoach, recoveryStep: Int?, nextMs: Long? = 90_000, last: Boolean = false) =
        if (last) coach.atCue(CueKind.phaseEnd, null, null, Phase.cooldown, null, 0, null)
        else coach.atCue(CueKind.start, null, null, Phase.recovery, recoveryStep, 0, nextMs)

    @Test
    fun `rep ends - mean of reps 1 to r ranked, a prior with an unclean rep dropped for that r`() {
        val board = reps(listOf(240.0, 240.0, 240.0, 240.0), listOf(230.0, 250.0, 235.0), listOf(250.0, null, 245.0, 240.0))
        val coach = LiveCoach(ctx(board), RunMode.intervals, fourHundreds)
        val l = Laps(coach)
        l.warmUp()
        l.rep(0, 235.0)
        val r1 = assertNotNull(repEnd(coach, 1)).result
        assertEquals(listOf(2, 4), listOf(r1.rank, r1.of), "235: behind 230, ahead of 240 and 250")
        assertEquals(5.0, r1.deltaSecPerKm!!, 1e-9)
        l.recovery(1)
        l.rep(2, 245.0)
        val r2 = assertNotNull(repEnd(coach, 3)).result
        // Mean 240 vs 240 (first), 240 (second), third dropped (null in rep 2): of = 3.
        assertEquals(listOf(1, 3), listOf(r2.rank, r2.of))
    }

    @Test
    fun `short profile speaks only after the final rep, a short recovery is voice only`() {
        val short = fourHundreds.copy(cueProfile = CueProfile.short)
        val board = reps(listOf(240.0, 240.0, 240.0, 240.0), listOf(250.0, 250.0, 250.0, 250.0))
        val coach = LiveCoach(ctx(board), RunMode.intervals, short)
        val l = Laps(coach)
        l.warmUp()
        l.rep(0, 235.0)
        assertNull(repEnd(coach, 1))
        val std = LiveCoach(ctx(board), RunMode.intervals, fourHundreds)
        Laps(std).apply { warmUp(); rep(0, 235.0) }
        assertFalse(repEnd(std, 1, nextMs = 15_000)!!.overlay)
        for (step in listOf(2, 4, 6)) {
            l.recovery(step - 1)
            l.rep(step, 235.0)
        }
        val last = assertNotNull(repEnd(coach, null, last = true))
        assertEquals("Best start to this session you've had.", last.text)
    }

    @Test
    fun `best start is said once a run, and never on the rep a fade nudge fires (#79 review)`() {
        val slow = reps(listOf(250.0, 250.0, 250.0, 250.0), listOf(251.0, 251.0, 251.0, 251.0), listOf(252.0, 252.0, 252.0, 252.0))
        val once = LiveCoach(ctx(slow), RunMode.intervals, fourHundreds)
        val lo = Laps(once)
        lo.warmUp()
        lo.rep(0, 235.0)
        val r1 = assertNotNull(repEnd(once, 1))
        assertEquals("Best start to this session you've had.", r1.text)
        assertTrue(r1.speak)
        lo.recovery(1)
        lo.rep(2, 236.0)
        val r2 = assertNotNull(repEnd(once, 3))
        assertEquals(1, r2.result.rank)
        assertFalse(r2.speak, "said once; the overlay still shows it")
        assertTrue(r2.overlay)

        // Best for the first time at rep 3, the rep the fade nudge fires: quiet.
        val late = reps(listOf(230.0, 230.0, 270.0), listOf(231.0, 231.0, 272.0), listOf(232.0, 232.0, 275.0))
        val fade = RepFadeRule(listOf(null, null, 5.0, 5.0), "That one dropped off a bit. Hold your form on the next.")
        val coach = LiveCoach(ctx(late).copy(nudges = NudgePlan(version = 1, repFade = fade)), RunMode.intervals, fourHundreds)
        val l = Laps(coach)
        l.warmUp()
        l.rep(0, 235.0); repEnd(coach, 1); l.recovery(1)
        l.rep(2, 235.0); repEnd(coach, 3); l.recovery(3)
        l.rep(4, 245.0)
        val r3 = assertNotNull(repEnd(coach, 5))
        assertEquals(1, r3.result.rank)
        assertFalse(r3.speak, "a best line next to a fade nudge contradicts it")
        assertNotNull(coach.nudgeAtCue(CueKind.start, Phase.recovery), "the fade nudge still fires")
    }

    @Test
    fun `an unclean live rep has no compare, and the clean reps after it compare without it`() {
        val board = reps(listOf(240.0, 200.0, 240.0, 240.0), listOf(250.0, 250.0, 250.0, 250.0), listOf(230.0, null, 230.0, 230.0))
        val coach = LiveCoach(ctx(board), RunMode.intervals, fourHundreds)
        val l = Laps(coach)
        l.warmUp()
        l.lap(RecorderCore.LapStep(0, true), 0.0, 90_000) // rep 1: no distance, unclean
        assertNull(repEnd(coach, 1))
        l.recovery(1)
        l.rep(2, 245.0)
        // Rep 1 is left out on both sides: rep 2 alone, 245 vs 200, 250 and (null there) the third dropped.
        val r2 = assertNotNull(repEnd(coach, 3)).result
        assertEquals(listOf(2, 3), listOf(r2.rank, r2.of))
        assertEquals(45.0, r2.deltaSecPerKm!!, 1e-9)
    }

    @Test
    fun `a rep is its step - a 0 s recovery (no lap) and a volume-key lap mid-rep shift nothing (review P1)`() {
        val coach = LiveCoach(null, RunMode.intervals, fourHundreds)
        val l = Laps(coach)
        l.warmUp()
        // Rep 1 split by a volume-key lap (ends nothing, starts nothing): one rep over both parts.
        l.lap(RecorderCore.LapStep(null, false), 200.0, 50_000)
        l.lap(RecorderCore.LapStep(0, true), 200.0, 50_000)
        // A 0 s recovery: the next lap ends work step 2 directly after step 0 (no recovery lap).
        l.rep(2, 240.0)
        assertEquals(listOf(250.0, 240.0), coach.repPaces.map { it!! })
    }

    @Test
    fun `a rep with a kill gap inside it is unclean, the next one is clean again (review P2)`() {
        val coach = LiveCoach(null, RunMode.intervals, fourHundreds)
        val l = Laps(coach)
        l.warmUp()
        coach.gap()
        l.rep(0, 250.0)
        l.recovery(1)
        l.rep(2, 240.0)
        assertEquals(listOf(null, 240.0), coach.repPaces)
    }

    // ---- Cooper, target ----

    @Test
    fun `Cooper - rank against past tests at 3, 6 and 9 minutes only`() {
        val coach = LiveCoach(ctx(history = listOf(49.0, 52.0, 50.0)), RunMode.cooper, SessionSpec.COOPER)
        val metres = 504.9 + 44.73 * 51.0 // VO2 51: second of four
        assertNull(coach.atCue(CueKind.projection, 2, metres, Phase.work, 0, 120_000, null))
        val f = assertNotNull(coach.atCue(CueKind.projection, 3, metres, Phase.work, 0, 180_000, null))
        assertEquals("2nd of 4 so far.", f.text)
        assertNull(coach.atCue(CueKind.projection, 4, metres, Phase.work, 0, 240_000, null))
        val one = LiveCoach(ctx(history = listOf(49.4)), RunMode.cooper, SessionSpec.COOPER)
        assertEquals("Up 2 on last time.", one.atCue(CueKind.projection, 6, metres, Phase.work, 0, 360_000, null)!!.text)
    }

    @Test
    fun `parkrun km - against the predicted time's even split`() {
        val parkrun = SessionSpec(
            templateId = "parkrun", templateVersion = 1, name = "parkrun", warmupSeconds = null, cooldownSeconds = null, lapLockout = false,
            autoStop = true, cueProfile = CueProfile.standard, hrBand = null, steps = listOf(Step(StepKind.work, TargetKind.distance, 5_000, RecoveryStyle.run, 1)),
        )
        val coach = LiveCoach(ctx(target = LiveTarget(5_000.0, 1_470_000, predicted = true)), RunMode.intervals, parkrun)
        val f = assertNotNull(coach.atCue(CueKind.projection, 2, 1_440_000.0, Phase.work, 0, 580_000, null))
        assertEquals(580_000L - 588_000L, f.result.deltaMs)
        assertEquals("8 seconds up on your predicted 24:30.", f.text)
        assertTrue(coach.atCue(CueKind.projection, 2, 1_440_000.0, Phase.work, 0, 580_000, null) == null, "once per km")
    }
}
