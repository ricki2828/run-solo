package app.runsolo.core.live

import app.runsolo.core.journal.JournalCodec
import app.runsolo.core.journal.JournalLine
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.FastStartRule
import app.runsolo.core.model.HrDriftRule
import app.runsolo.core.model.LiveContext
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
import kotlin.test.assertNull

/** CR1's native half: the engine's NudgePlan (#56 JSON) against live figures, the §3.5 limits. */
class LiveNudgeTest {
    private val fast = FastStartRule(km1MaxMs = 290_000, text = "Easy start. Your best 5K went out slower than this.")
    private val fade = RepFadeRule(listOf(null, null, 4.0, 6.0, null), "That one dropped off a bit. Hold your form on the next.")
    /** Three earlier runs at ~5:00 per km: km 4 HRs 152/155/158 (median 155), km 5 154/156/158 (156). */
    private val drift = HrDriftRule(
        kmSamples = listOf(
            emptyList(), emptyList(), emptyList(),
            listOf(298.0 to 152.0, 300.0 to 155.0, 303.0 to 158.0),
            listOf(298.0 to 154.0, 300.0 to 156.0, 303.0 to 158.0),
        ),
        text = "Heart rate's up for this pace today. Fine to ease a touch.",
    )

    private fun ctx(plan: NudgePlan, muted: Boolean = false) =
        LiveContext(boards = emptyList(), nudges = plan, coachingMuted = muted, builtAtMs = 0, engineVersion = 1)

    /**
     * A steady Free run: one tick a second, [secPerKm] pace, HR [hr] (null = no strap) per second;
     * returns every km cue. Km crossings interpolate as the service does.
     */
    private fun free(coach: LiveCoach, kms: Int, secPerKm: (Int) -> Int, hr: (Int, Int) -> Int?): List<LiveCoach.KmCue> {
        val out = ArrayList<LiveCoach.KmCue>()
        var t = 0L
        var d = 0.0
        for (km in 1..kms) {
            val s = secPerKm(km)
            for (i in 1..s) {
                val prevT = t
                val prevD = d
                t += 1_000
                d += 1_000.0 / s
                coach.onTick(prevT, prevD, t, d + if (i == s) 0.001 else 0.0, hr(km, i)) { it }?.let { out.add(it) }
            }
        }
        return out
    }

    @Test
    fun `fast start - km 1 under the limit, said once, blocked when said last run, off when muted`() {
        val plan = NudgePlan(version = 1, fastStart = fast)
        val cues = free(LiveCoach(ctx(plan), RunMode.free, null), 3, { if (it == 1) 280 else 300 }) { _, _ -> null }
        assertEquals(listOf(NudgePlan.FAST_START to 1), cues.mapNotNull { it.nudge }.map { it.rule to it.index })
        assertEquals(fast.text, cues.first().nudge!!.text)
        val slow = free(LiveCoach(ctx(plan), RunMode.free, null), 1, { 295 }) { _, _ -> null }
        assertNull(slow.single().nudge, "295 s is not under 290 s")
        val blocked = free(LiveCoach(ctx(plan.copy(blocked = listOf("fast_start:1"))), RunMode.free, null), 1, { 280 }) { _, _ -> null }
        assertNull(blocked.single().nudge)
        assertNull(free(LiveCoach(ctx(plan, muted = true), RunMode.free, null), 1, { 280 }) { _, _ -> null }.single().nudge)
        val laps = free(LiveCoach(ctx(plan), RunMode.laps, null), 1, { 280 }) { _, _ -> null }
        assertEquals(emptyList(), laps, "a Laps run has no km cue to ride")
    }

    @Test
    fun `hr drift - from firstKm, like with like, HR at least 5 over the similar runs' median`() {
        val plan = NudgePlan(version = 1, hrDrift = drift)
        // km 4 at 300 s/km with HR 161 (median 155 + 5 = 160): fires; km 5 too (156 + 5); km 3 is before firstKm.
        val cues = free(LiveCoach(ctx(plan), RunMode.free, null), 5, { 300 }) { km, _ -> if (km >= 3) 161 else 150 }
        assertEquals(listOf(NudgePlan.HR_DRIFT to 4, NudgePlan.HR_DRIFT to 5), cues.mapNotNull { it.nudge }.map { it.rule to it.index })
        // At 320 s/km no earlier run was within 5 %: fewer than 3 similar, no nudge.
        val offPace = free(LiveCoach(ctx(plan), RunMode.free, null), 4, { if (it == 4) 320 else 300 }) { _, _ -> 170 }
        assertNull(offPace.last().nudge)
        // Under half the km's samples carry HR: null HR, no nudge (the engine's kmHr rule).
        val patchy = free(LiveCoach(ctx(plan), RunMode.free, null), 4, { 300 }) { km, i -> if (km == 4 && i % 5 < 3) null else 170 }
        assertNull(patchy.last().nudge)
        // Exactly half with HR still counts.
        val half = free(LiveCoach(ctx(plan), RunMode.free, null), 4, { 300 }) { km, i -> if (km == 4 && i % 2 == 0) null else 170 }
        assertEquals(NudgePlan.HR_DRIFT, half.last().nudge?.rule)
    }

    @Test
    fun `firesAt mirrors the engine's cases (coaching_test, #56 review P2)`() {
        // Median HR of the similar-pace runs at km 4 is 154: fires at 159, not 158; never at km 3.
        val h = HrDriftRule(kmSamples = listOf(emptyList(), emptyList(), emptyList(), listOf(300.0 to 152.0, 305.0 to 154.0, 310.0 to 156.0)), text = "t")
        assertEquals(true, h.firesAt(4, 305.0, 159.0))
        assertEquals(false, h.firesAt(4, 305.0, 158.0))
        assertEquals(false, h.firesAt(3, 305.0, 190.0))
        // Mixed history: three hard 5Ks at 4:30 and HR 170, three easy at 6:00 and HR 140.
        val km4 = List(3) { 270.0 to 170.0 } + List(3) { 360.0 to 140.0 }
        val mixed = HrDriftRule(kmSamples = listOf(km4, km4, km4, km4, km4), text = "t")
        assertEquals(true, mixed.firesAt(4, 360.0, 150.0), "an easy run 10 over its like")
        assertEquals(false, mixed.firesAt(4, 270.0, 172.0), "a hard run only 2 over (a median of all six would fire)")
        assertEquals(false, mixed.firesAt(4, 315.0, 200.0), "a pace nobody ran: fewer than 3 similar")
    }

    @Test
    fun `hrDrift shared vectors - the engine's JSON decodes and firesAt agrees on every case`() {
        val fx = app.runsolo.core.json.Json.parseObject(java.io.File("../../packages/run_engine/test/fixtures/phase4/hr_drift_vectors.json").readText())
        @Suppress("UNCHECKED_CAST")
        val plans = (fx["plans"] as Map<String, Any?>).mapValues { (_, v) ->
            NudgePlan.fromJson(mapOf("version" to 1L, "hrDrift" to v)).hrDrift!!
        }
        @Suppress("UNCHECKED_CAST")
        val cases = fx["cases"] as List<Map<String, Any?>>
        assertEquals(14, cases.size)
        for (c in cases) {
            val rule = plans.getValue(c["plan"] as String)
            val km = (c["km"] as Number).toInt()
            val pace = (c["pace"] as Number).toDouble()
            val hr = (c["hr"] as Number).toDouble()
            assertEquals(c["fires"], rule.firesAt(km, pace, hr), "$c")
        }
    }

    @Test
    fun `hr drift - after a restore the km in progress was not seen whole, no nudge`() {
        val coach = LiveCoach(ctx(NudgePlan(version = 1, hrDrift = drift)), RunMode.free, null)
        coach.resumeAt(3_600.0)
        var t = 0L
        var d = 3_600.0
        var cue: LiveCoach.KmCue? = null
        for (i in 1..130) {
            val prevT = t
            val prevD = d
            t += 1_000
            d += 1_000.0 / 300
            coach.onTick(prevT, prevD, t, d, 175) { it }?.let { cue = it }
        }
        assertEquals(4, cue!!.km)
        assertNull(cue!!.nudge)
    }

    private val fiveReps = SessionSpec(
        templateId = "1km-repeats", templateVersion = 1, name = "1 km repeats", warmupSeconds = null, cooldownSeconds = null,
        lapLockout = false, cueProfile = CueProfile.standard, hrBand = null,
        steps = (1..5).flatMap { r ->
            listOfNotNull(Step(StepKind.work, TargetKind.distance, 1_000, RecoveryStyle.run, r), if (r < 5) Step(StepKind.recovery, TargetKind.time, 120, RecoveryStyle.jog, r) else null)
        },
    )

    /** Rep paces through the real lap path: warm-up, then work/recovery laps. */
    private fun reps(coach: LiveCoach, vararg paces: Double) {
        var d = 150.0
        var a = 60_000L
        coach.lapEnded(RecorderCore.LapStep(null, true), d, a)
        for ((i, p) in paces.withIndex()) {
            d += 1_000.0
            a += (p * 1_000).toLong()
            coach.lapEnded(RecorderCore.LapStep(2 * i, true), d, a)
            if (i < paces.size - 1) {
                d += 240.0
                a += 120_000
                coach.lapEnded(RecorderCore.LapStep(2 * i + 1, true), d, a)
            }
        }
    }

    @Test
    fun `rep fade - rep 3 on, slower than rep 1 by more than the plan's limit for that rep`() {
        val plan = NudgePlan(version = 1, repFade = fade)
        val coach = LiveCoach(ctx(plan), RunMode.intervals, fiveReps)
        reps(coach, 240.0, 242.0)
        assertNull(coach.nudgeAtCue(CueKind.start, Phase.recovery), "rep 2: never before rep 3")
        val three = LiveCoach(ctx(plan), RunMode.intervals, fiveReps).also { reps(it, 240.0, 241.0, 245.0) }
        assertEquals(NudgePlan.REP_FADE to 3, three.nudgeAtCue(CueKind.start, Phase.recovery)?.let { it.rule to it.index })
        assertNull(three.nudgeAtCue(CueKind.start, Phase.recovery), "once per rep")
        val within = LiveCoach(ctx(plan), RunMode.intervals, fiveReps).also { reps(it, 240.0, 241.0, 243.9) }
        assertNull(within.nudgeAtCue(CueKind.start, Phase.recovery), "3.9 s/km is inside the 4 s/km limit")
        val offForRep5 = LiveCoach(ctx(plan), RunMode.intervals, fiveReps).also { reps(it, 240.0, 240.0, 240.0, 240.0, 260.0) }
        assertNull(offForRep5.nudgeAtCue(CueKind.phaseEnd, Phase.cooldown), "null limit = off for that rep")
        val short = LiveCoach(ctx(plan), RunMode.intervals, fiveReps.copy(cueProfile = CueProfile.short)).also { reps(it, 240.0, 241.0, 250.0) }
        assertNull(short.nudgeAtCue(CueKind.start, Phase.recovery), "short profile: not before the last rep")
        val cooper = LiveCoach(ctx(plan), RunMode.cooper, SessionSpec.COOPER)
        assertNull(cooper.nudgeAtCue(CueKind.projection, Phase.work), "never in a Cooper")
    }

    @Test
    fun `restore - a nudge said before the kill is not said again`() {
        val plan = NudgePlan(version = 1, fastStart = fast)
        val fired = listOf(JournalLine.CueFired(0, 0, JournalLine.FiredKind.nudge, NudgePlan.FAST_START, 1, 280_000))
        val cues = free(LiveCoach(ctx(plan), RunMode.free, null, fired), 1, { 280 }) { _, _ -> null }
        assertNull(cues.single().nudge)
    }

    @Test
    fun `the plan round-trips the lctx line, and an LC1 stub journal still reads`() {
        val plan = NudgePlan(version = 1, fastStart = fast, repFade = fade, hrDrift = drift, blocked = listOf("rep_fade:3"))
        val line = JournalLine.LiveContextLine(0, 0, ctx(plan))
        assertEquals(line, JournalCodec.decode(JournalCodec.encode(line)))
        val stub = JournalCodec.encode(JournalLine.LiveContextLine(0, 0, ctx(NudgePlan())))
            .replace(Regex("\"nudges\":\\{[^}]*\\}"), "\"nudges\":{\"version\":0}")
        assertEquals(NudgePlan(), (JournalCodec.decode(stub) as JournalLine.LiveContextLine).context.nudges)
    }
}
