package app.runsolo.core.model

import app.runsolo.core.json.int
import app.runsolo.core.json.list
import app.runsolo.core.json.string

enum class StepKind { work, recovery }

enum class TargetKind { time, distance, equalToPreviousWork }

enum class RecoveryStyle { run, jog, walk, stand }

enum class CueProfile { standard, short, cooper }

/**
 * One expanded step (Phase 3 plan §3.3). [value] is seconds for a time target, metres for a
 * distance target, 0 for [TargetKind.equalToPreviousWork]. [rep] is 1-based; a recovery carries
 * the rep number of the work step before it. Work steps are always [RecoveryStyle.run].
 */
data class Step(val kind: StepKind, val target: TargetKind, val value: Int, val style: RecoveryStyle, val rep: Int) {
    val durationMs: Long? get() = if (target == TargetKind.time) value * 1000L else null

    fun toJson(): Map<String, Any?> =
        linkedMapOf("kind" to kind.name, "target" to target.name, "value" to value, "style" to style.name, "rep" to rep)

    companion object {
        fun fromJson(m: Map<String, Any?>) = Step(
            kind = StepKind.valueOf(m.string("kind")),
            target = TargetKind.valueOf(m.string("target")),
            value = m.int("value"),
            style = RecoveryStyle.valueOf(m.string("style")),
            rep = m.int("rep"),
        )
    }
}

/**
 * The expanded session a structured run follows (Phase 3 plan §3.3, I1 contract). Presets and
 * custom templates are expanded on the Dart side; Kotlin only receives, validates, journals and
 * runs the flat step list. The JSON key order is canonical (run file `session`, journal header).
 */
data class SessionSpec(
    val templateId: String,
    val templateVersion: Int,
    val name: String,
    val warmupSeconds: Int?,
    val cooldownSeconds: Int?,
    val lapLockout: Boolean,
    /** The recording stops itself when the last timed part ends (parkrun: 5.00 km). */
    val autoStop: Boolean = false,
    val cueProfile: CueProfile,
    val hrBand: Pair<Double, Double>?,
    val steps: List<Step>,
) {
    val workSteps: List<Step> get() = steps.filter { it.kind == StepKind.work }
    val reps: Int get() = workSteps.size
    val isFartlek: Boolean get() = templateId == FARTLEK_ID

    /**
     * The contract's validation rules, a line-for-line mirror of the Dart `SessionSpec.validate()`
     * (same order, same messages); a list of problems, empty when valid.
     */
    fun problems(): List<String> {
        val out = ArrayList<String>()
        if (templateId.isEmpty()) out.add("templateId is empty")
        if (templateVersion < 1) out.add("templateVersion must be >= 1")
        hrBand?.let { (lo, hi) -> if (!(lo > 0 && lo < hi && hi <= 1.2)) out.add("hrBand must be 0 < low < high <= 1.2") }
        // warmupSeconds 0 = no warm-up: step 1 begins at start() (parkrun, founder 26-Sep).
        if (warmupSeconds != null && warmupSeconds != 0 && warmupSeconds !in 300..1200) out.add("warmup must be open, 0 (none) or 300..1200 s")
        if (cooldownSeconds != null && cooldownSeconds !in 300..1200) out.add("cooldown must be open or 300..1200 s")
        if (steps.isEmpty()) {
            if (!isFartlek) out.add("only fartlek may have no steps")
            return out
        }
        if (steps.size > MAX_STEPS) out.add("more than $MAX_STEPS steps")
        if (reps !in 1..MAX_WORK) out.add("reps must be 1..$MAX_WORK")
        for ((i, s) in steps.withIndex()) {
            val expectWork = i % 2 == 0
            if ((s.kind == StepKind.work) != expectWork) {
                out.add("step $i: steps must alternate work, recovery, …, work")
                continue
            }
            val rep = i / 2 + 1
            if (s.rep != rep) out.add("step $i: rep must be $rep, got ${s.rep}")
            when (s.kind) {
                StepKind.work -> {
                    if (s.style != RecoveryStyle.run) out.add("step $i: work style is run")
                    when (s.target) {
                        TargetKind.time -> if (s.value !in 15..1200) out.add("step $i: time work must be 15..1200 s")
                        TargetKind.distance -> if (s.value !in 100..10_000) out.add("step $i: distance work must be 100..10000 m")
                        TargetKind.equalToPreviousWork -> out.add("step $i: only a recovery can be equal time")
                    }
                }
                StepKind.recovery -> {
                    if (s.style == RecoveryStyle.run) out.add("step $i: recovery style is jog, walk or stand")
                    when (s.target) {
                        TargetKind.time -> if (s.value !in 0..600) out.add("step $i: time recovery must be 0..600 s")
                        TargetKind.distance -> {
                            if (s.value !in 50..2000) out.add("step $i: distance recovery must be 50..2000 m")
                            if (s.style != RecoveryStyle.jog) out.add("step $i: walk and stand recoveries must be timed")
                        }
                        TargetKind.equalToPreviousWork -> if (s.value != 0) out.add("step $i: equal time carries value 0")
                    }
                }
            }
        }
        if (steps.last().kind != StepKind.work) out.add("the last step must be work")
        return out
    }

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "templateId" to templateId,
        "templateVersion" to templateVersion,
        "name" to name,
        "warmupSeconds" to warmupSeconds,
        "cooldownSeconds" to cooldownSeconds,
        "lapLockout" to lapLockout,
        "autoStop" to autoStop,
        "cueProfile" to cueProfile.name,
        "hrBand" to hrBand?.let { listOf(it.first, it.second) },
        "steps" to steps.map { it.toJson() },
    )

    companion object {
        const val MAX_STEPS = 80
        const val MAX_WORK = 40
        const val NORWEGIAN_4X4_ID = "norwegian-4x4"
        const val COOPER_ID = "cooper"
        const val FARTLEK_ID = "fartlek"

        fun fromJson(m: Map<String, Any?>?): SessionSpec? {
            m ?: return null
            val band = m["hrBand"] as? List<*>
            require(band == null || (band.size == 2 && band.all { it is Number })) { "session.hrBand must be [low, high], got $band" }
            return SessionSpec(
                templateId = m.string("templateId"),
                templateVersion = m.int("templateVersion"),
                name = m.string("name"),
                warmupSeconds = (m["warmupSeconds"] as? Number)?.toInt(),
                cooldownSeconds = (m["cooldownSeconds"] as? Number)?.toInt(),
                lapLockout = m["lapLockout"] as? Boolean ?: throw IllegalArgumentException("session.lapLockout"),
                autoStop = m["autoStop"] as? Boolean ?: false,
                cueProfile = CueProfile.valueOf(m.string("cueProfile")),
                hrBand = band?.let { (it[0] as Number).toDouble() to (it[1] as Number).toDouble() },
                steps = m.list("steps").map { @Suppress("UNCHECKED_CAST") Step.fromJson(it as Map<String, Any?>) },
            )
        }

        /** Uniform time intervals: [reps] work steps with [reps] − 1 jog recoveries between them. */
        fun uniformTime(reps: Int, workSeconds: Int, recoverySeconds: Int): List<Step> {
            val out = ArrayList<Step>()
            for (r in 1..reps) {
                out.add(Step(StepKind.work, TargetKind.time, workSeconds, RecoveryStyle.run, r))
                if (r < reps) out.add(Step(StepKind.recovery, TargetKind.time, recoverySeconds, RecoveryStyle.jog, r))
            }
            return out
        }

        /** The Norwegian 4x4 at the given shape: what a schema ≤ 2 `fourByFour` + preset maps to. */
        fun norwegian4x4(reps: Int = 4, workSeconds: Int = 240, recoverySeconds: Int = 180) = SessionSpec(
            templateId = NORWEGIAN_4X4_ID,
            templateVersion = 1,
            name = "Norwegian 4x4",
            warmupSeconds = null,
            cooldownSeconds = null,
            lapLockout = false,
            cueProfile = CueProfile.standard,
            hrBand = 0.85 to 0.95,
            steps = uniformTime(reps, workSeconds, recoverySeconds),
        )

        val COOPER = SessionSpec(
            templateId = COOPER_ID,
            templateVersion = 1,
            name = "12-minute test",
            warmupSeconds = null,
            cooldownSeconds = null,
            lapLockout = true,
            cueProfile = CueProfile.cooper,
            hrBand = null,
            steps = listOf(Step(StepKind.work, TargetKind.time, 720, RecoveryStyle.run, 1)),
        )

        val FARTLEK = SessionSpec(
            templateId = FARTLEK_ID,
            templateVersion = 1,
            name = "Fartlek",
            warmupSeconds = null,
            cooldownSeconds = null,
            lapLockout = false,
            cueProfile = CueProfile.standard,
            hrBand = null,
            steps = emptyList(),
        )

        /**
         * Schema ≤ 2 `preset{reps, workSeconds, recoverySeconds}` → the norwegian-4x4 spec. A
         * `fourByFour` with no preset was a by-feel 4x4 and maps to no session (it keeps the
         * by-feel detector, so its verdicts do not change).
         */
        fun fromLegacyPreset(m: Map<String, Any?>): SessionSpec =
            norwegian4x4(m.int("reps"), m.int("workSeconds"), m.int("recoverySeconds"))
    }
}
