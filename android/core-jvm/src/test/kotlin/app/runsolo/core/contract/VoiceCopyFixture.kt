package app.runsolo.core.contract

import app.runsolo.core.live.CompareKind
import app.runsolo.core.live.CompareResult
import app.runsolo.core.live.CooperProjection
import app.runsolo.core.live.CueComposer
import app.runsolo.core.live.GoalCoach
import app.runsolo.core.live.LiveWords
import app.runsolo.core.model.CueKind
import app.runsolo.core.model.CueProfile
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.Phase
import app.runsolo.core.model.RecoveryStyle
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Step
import app.runsolo.core.model.StepKind
import app.runsolo.core.model.TargetKind
import app.runsolo.core.record.CueWords
import app.runsolo.core.record.RecorderCore
import app.runsolo.core.replay.ReplayScenarios
import java.io.File

/**
 * Phase 4 T4 voice-copy snapshot: every line the recorder can say, one per template branch, with
 * the longest numbers where a number varies, as `id<TAB>words<TAB>text`. A copy change shows up
 * as a diff of this file in review; [VoiceCopyFixtureTest] also holds every line to the 16-word
 * budget and the copy rules. The nudge lines are the engine's (`CoachingRules`), as the T4
 * contexts carry them.
 */
object VoiceCopyFixture {
    const val FILE = "src/test/fixtures/voice/voice_copy.tsv"

    fun lines(): List<Pair<String, String>> {
        val out = ArrayList<Pair<String, String>>()
        fun add(id: String, text: String?) {
            if (text != null) out.add(id to text)
        }

        val fourByFour = SessionSpec.norwegian4x4()
        val jog = Step(StepKind.recovery, TargetKind.time, 60, RecoveryStyle.jog, 1)
        val distance = fourByFour.copy(
            templateId = "400s", name = "8 × 400 m",
            steps = listOf(Step(StepKind.work, TargetKind.distance, 400, RecoveryStyle.run, 1), jog),
        )
        val short = fourByFour.copy(cueProfile = CueProfile.short)
        fun cue(kind: CueKind, spec: SessionSpec?, phase: Phase, step: Int?, value: Double? = null, index: Int? = null, rep: Int = 1) =
            CueWords.text(kind, value, spec, phase, rep, step, index)

        // Cue words (CueWords), by branch.
        add("cue.start.time-rep", cue(CueKind.start, fourByFour, Phase.work, 0, rep = 4))
        add("cue.start.distance-rep", cue(CueKind.start, distance.copy(steps = List(20) { distance.steps[0].copy(rep = it + 1) }), Phase.work, 0, rep = 20))
        add("cue.start.short-rep", cue(CueKind.start, short, Phase.work, 0))
        add("cue.start.cooper", cue(CueKind.start, SessionSpec.COOPER, Phase.work, 0))
        add("cue.start.goal-distance", cue(CueKind.start, SessionSpec.goalDistance(21_098, "Half").copy(spokenName = "Half marathon"), Phase.work, 0))
        add("cue.start.goal-time", cue(CueKind.start, SessionSpec.goalTime(4_500, "1 h 15").copy(spokenName = "1 hour 15 minutes"), Phase.work, 0))
        add("cue.start.event", cue(CueKind.start, ReplayScenarios.PARKRUN, Phase.work, 0))
        add("cue.start.recover", cue(CueKind.start, fourByFour, Phase.recovery, 1))
        add("cue.start.short-recover", cue(CueKind.start, short, Phase.recovery, 1))
        add("cue.start.walk", cue(CueKind.start, fourByFour.copy(steps = listOf(fourByFour.steps[0], jog.copy(style = RecoveryStyle.walk))), Phase.recovery, 1))
        add("cue.start.stand", cue(CueKind.start, fourByFour.copy(steps = listOf(fourByFour.steps[0], jog.copy(style = RecoveryStyle.stand))), Phase.recovery, 1))
        add("cue.halfway", cue(CueKind.halfway, fourByFour, Phase.work, 0))
        add("cue.thirty-seconds", cue(CueKind.thirtySeconds, fourByFour, Phase.work, 0))
        add("cue.phase-end.cooldown", cue(CueKind.phaseEnd, fourByFour, Phase.cooldown, null))
        add("cue.phase-end.cooper", cue(CueKind.phaseEnd, SessionSpec.COOPER, Phase.cooldown, null))
        add("cue.phase-end.cooldown-over", cue(CueKind.phaseEnd, fourByFour, Phase.cooldown, null, value = CueWords.COOLDOWN_OVER))
        add("cue.stop", cue(CueKind.stop, fourByFour, Phase.none, null))
        add("cue.distance-to-go", cue(CueKind.distanceToGo, distance, Phase.work, 0))
        // A goal's to-go line carries the pace (§G goal compares): the longest clock, over an hour.
        add("cue.distance-to-go.goal", cue(CueKind.distanceToGo, SessionSpec.goalDistance(42_195, "Marathon"), Phase.work, 0, value = 17_999_000.0))
        add("cue.last-rep", cue(CueKind.lastRep, fourByFour, Phase.work, 0))
        add("cue.minute-mark.1", cue(CueKind.minuteMark, SessionSpec.COOPER, Phase.work, 0, value = 1.0))
        add("cue.minute-mark.11", cue(CueKind.minuteMark, SessionSpec.COOPER, Phase.work, 0, value = 11.0))
        add("cue.projection.target", cue(CueKind.projection, ReplayScenarios.PARKRUN, Phase.work, 0, value = 7_199_000.0, index = 4))
        add("cue.projection.cooper", CooperProjection.cue(11, 9_999.0))

        // Free run km splits (LiveWords.kmSplit).
        add("km.split", LiveWords.kmSplit(3, 920_000, 307_000))
        // A goal km with its compare (§G): the km replaces "On pace for", the longest two-digit case.
        add("km.goal", CueComposer.compose(LiveWords.goalKm(41), "Number 12 of 21, 125 seconds off your best.").text!!)
        add("km.split.whole-minutes", LiveWords.kmSplit(2, 600_000, 300_000))
        add("km.split.over-an-hour", LiveWords.kmSplit(12, 3_845_000, 320_000))
        add("km.split.longest", LiveWords.kmSplit(10, 7_199_000, 599_000))
        add("km.split.no-pace", LiveWords.kmSplit(4, 1_220_000, null))

        // Live compares (LiveWords.compare), every branch.
        fun r(kind: CompareKind, rank: Int, of: Int, label: String = "10K", index: Int = 20, deltaMs: Long? = null, deltaSec: Double? = null, deltaVo2: Double? = null, value: Double? = null) =
            LiveWords.compare(CompareResult("k", label, kind, index, rank, of, deltaMs, deltaSec, deltaVo2, value))
        add("compare.distance.best", r(CompareKind.distance, 1, 21, deltaMs = -999_000))
        add("compare.distance.best-level", r(CompareKind.distance, 1, 21, deltaMs = 0))
        add("compare.distance.rank", r(CompareKind.distance, 20, 21, deltaMs = 999_000))
        add("compare.distance.rank-1s", r(CompareKind.distance, 3, 7, deltaMs = 1_000))
        add("compare.distance.rank-level", r(CompareKind.distance, 2, 21, deltaMs = 0))
        add("compare.distance.one-other-up", r(CompareKind.distance, 1, 2, deltaMs = -999_000))
        add("compare.distance.one-other-behind", r(CompareKind.distance, 2, 2, deltaMs = 999_000))
        add("compare.distance.one-other-level", r(CompareKind.distance, 1, 2, deltaMs = 0))
        add("compare.intervals.best", r(CompareKind.intervals, 1, 21, deltaSec = -9.0))
        add("compare.intervals.rank", r(CompareKind.intervals, 20, 21, deltaSec = 9.0))
        add("compare.intervals.rank-1-rep", r(CompareKind.intervals, 2, 21, index = 1, deltaSec = 9.0))
        add("compare.intervals.one-other-ahead", r(CompareKind.intervals, 1, 2, deltaSec = -9.0))
        add("compare.intervals.one-other-behind", r(CompareKind.intervals, 2, 2, deltaSec = 9.0))
        add("compare.intervals.one-other-level", r(CompareKind.intervals, 1, 2, deltaSec = 0.2))
        add("compare.cooper.best", r(CompareKind.cooper, 1, 21, deltaVo2 = 3.0))
        add("compare.cooper.second", r(CompareKind.cooper, 2, 21, deltaVo2 = -1.0))
        add("compare.cooper.third", r(CompareKind.cooper, 3, 21, deltaVo2 = -1.0))
        add("compare.cooper.rank", r(CompareKind.cooper, 20, 21, deltaVo2 = -30.0))
        add("compare.cooper.last-up", r(CompareKind.cooper, 1, 2, deltaVo2 = 30.0))
        add("compare.cooper.last-down", r(CompareKind.cooper, 2, 2, deltaVo2 = -30.0))
        add("compare.cooper.last-level", r(CompareKind.cooper, 1, 2, deltaVo2 = 0.2))
        add("compare.target.up", r(CompareKind.target, 1, 1, label = "predicted", deltaMs = -999_000, value = 7_199_000.0))
        add("compare.target.behind", r(CompareKind.target, 1, 1, label = "target", deltaMs = 999_000, value = 7_199_000.0))
        add("compare.target.level", r(CompareKind.target, 1, 1, label = "predicted", deltaMs = 0, value = 1_380_000.0))

        // The goal-reached line (GoalCoach): distance and time goals, with and without a new best.
        fun goal(spec: SessionSpec, end: RecorderCore.StepEnd, ctx: LiveContext?) =
            GoalCoach(spec, ctx).atCue(CueKind.phaseEnd, Phase.cooldown, end)?.text
        val tenK = SessionSpec.goalDistance(10_000, "10K")
        val board = LiveBoard(
            "be:10000", "10K", LiveBoardKind.distance, 10_000.0,
            listOf(LiveEntry("a", 0, fromStartSplitsMs = List(10) { (it + 1) * 300_000L }, finalMetric = 3_000_000.0)),
        )
        add("goal.distance", goal(tenK, RecorderCore.StepEnd(0, 2_952_000, 10_000.0), null))
        add("goal.distance.new-best", goal(tenK, RecorderCore.StepEnd(0, 2_952_000, 10_000.0), LiveContext(listOf(board), builtAtMs = 0, engineVersion = 3)))
        add("goal.distance.marathon", goal(SessionSpec.goalDistance(42_195, "Marathon"), RecorderCore.StepEnd(0, 17_999_000, 42_195.0), null))
        add("goal.time", goal(SessionSpec.goalTime(1_800, "30 min").copy(spokenName = "30 minutes"), RecorderCore.StepEnd(0, 1_800_000, 7_210.0), null))
        add("goal.distance.miles", goal(SessionSpec.goalDistance(12_070, "7.5 mi").copy(spokenName = "7.5 miles"), RecorderCore.StepEnd(0, 3_599_000, 12_070.0), null))

        // The timed 5 km's end line (#83): against its course board, no cool-down.
        val course = LiveContext(
            listOf(
                LiveBoard(
                    "${SessionSpec.EVENT_ID}:c", "5K time trial", LiveBoardKind.distance, 5_000.0,
                    listOf(LiveEntry("a", 0, fromStartSplitsMs = List(5) { (it + 1) * 288_000L }, finalMetric = 1_440_000.0)),
                ),
            ),
            builtAtMs = 0, engineVersion = 3,
        )
        val event = ReplayScenarios.PARKRUN
        add("event.end.new-best", goal(event, RecorderCore.StepEnd(0, 1_420_000, 5_000.0), course))
        add("event.end.seconds-off", goal(event, RecorderCore.StepEnd(0, 1_499_000, 5_000.0), course))
        add("event.end.one-second-off", goal(event, RecorderCore.StepEnd(0, 1_441_000, 5_000.0), course))
        add("event.end.level", goal(event, RecorderCore.StepEnd(0, 1_440_000, 5_000.0), course))
        add("event.end.no-board", goal(event, RecorderCore.StepEnd(0, 1_440_000, 5_000.0), null))

        // Nudges (engine-owned lines, as packed into the LiveContext).
        add("nudge.fast-start", ReplayScenarios.T4.FAST_START_5K)
        add("nudge.rep-fade", ReplayScenarios.T4.REP_FADE)
        add("nudge.hr-drift", ReplayScenarios.T4.HR_DRIFT)
        return out
    }

    fun render(): String = lines().joinToString("") { (id, text) -> "$id\t${CueComposer.words(text)}\t$text\n" }

    fun write(file: File = File(FILE)) {
        file.parentFile.mkdirs()
        file.writeText(render())
    }
}
