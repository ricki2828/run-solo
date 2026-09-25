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
    val cueProfile: CueProfile,
    val hrBand: Pair<Double, Double>?,
    val steps: List<Step>,
) {
    val workSteps: List<Step> get() = steps.filter { it.kind == StepKind.work }
    val reps: Int get() = workSteps.size
    val isFartlek: Boolean get() = templateId == FARTLEK_ID

    /** The contract's validation rules (shared with Dart); a list of problems, empty when valid. */
    fun problems(): List<String> {
        val p = ArrayList<String>()
        if (templateId.isEmpty()) p.add("templateId empty")
        if (templateVersion < 1) p.add("templateVersion < 1")
        if (steps.size > MAX_STEPS) p.add("more than $MAX_STEPS steps")
        hrBand?.let { (lo, hi) -> if (!(lo > 0 && lo < hi && hi <= 1.2)) p.add("hrBand must be 0 < low < high <= 1.2") }
        warmupSeconds?.let { if (it !in 300..1200) p.add("warmup must be open or 300..1200 s") }
        cooldownSeconds?.let { if (it !in 300..1200) p.add("cooldown must be open or 300..1200 s") }
        if (steps.isEmpty()) {
            if (!isFartlek) p.add("no steps")
            return p
        }
        val work = workSteps.size
        if (work !in 1..MAX_WORK) p.add("work steps $work not in 1..$MAX_WORK")
        steps.forEachIndexed { i, s ->
            val wantKind = if (i % 2 == 0) StepKind.work else StepKind.recovery
            if (s.kind != wantKind) p.add("step $i: expected ${wantKind.name}")
            val wantRep = i / 2 + 1
            if (s.rep != wantRep) p.add("step $i: rep ${s.rep}, expected $wantRep")
            when (s.kind) {
                StepKind.work -> {
                    if (s.style != RecoveryStyle.run) p.add("step $i: work style must be run")
                    when (s.target) {
                        TargetKind.time -> if (s.value !in 15..1200) p.add("step $i: work time ${s.value} s not in 15..1200")
                        TargetKind.distance -> if (s.value !in 100..10_000) p.add("step $i: work distance ${s.value} m not in 100..10000")
                        TargetKind.equalToPreviousWork -> p.add("step $i: a work step cannot be equalToPreviousWork")
                    }
                }
                StepKind.recovery -> {
                    if (s.style == RecoveryStyle.run) p.add("step $i: recovery style must be jog, walk or stand")
                    when (s.target) {
                        TargetKind.time -> if (s.value !in 0..600) p.add("step $i: recovery time ${s.value} s not in 0..600")
                        TargetKind.distance -> {
                            if (s.value !in 50..2000) p.add("step $i: recovery distance ${s.value} m not in 50..2000")
                            if (s.style != RecoveryStyle.jog) p.add("step $i: a ${s.style.name} recovery must be time or equalToPreviousWork")
                        }
                        TargetKind.equalToPreviousWork -> if (s.value != 0) p.add("step $i: equalToPreviousWork value must be 0")
                    }
                }
            }
        }
        if (steps.last().kind != StepKind.work) p.add("last step must be work")
        return p
    }

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "templateId" to templateId,
        "templateVersion" to templateVersion,
        "name" to name,
        "warmupSeconds" to warmupSeconds,
        "cooldownSeconds" to cooldownSeconds,
        "lapLockout" to lapLockout,
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
            return SessionSpec(
                templateId = m.string("templateId"),
                templateVersion = m.int("templateVersion"),
                name = m.string("name"),
                warmupSeconds = (m["warmupSeconds"] as? Number)?.toInt(),
                cooldownSeconds = (m["cooldownSeconds"] as? Number)?.toInt(),
                lapLockout = m["lapLockout"] as? Boolean ?: throw IllegalArgumentException("session.lapLockout"),
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
         * Schema ≤ 2 `preset{reps, workSeconds, recoverySeconds}` → the norwegian-4x4 spec; a
         * `fourByFour` with no preset was the standard 4 × 240/180.
         */
        fun fromLegacyPreset(m: Map<String, Any?>?): SessionSpec =
            if (m == null) norwegian4x4() else norwegian4x4(m.int("reps"), m.int("workSeconds"), m.int("recoverySeconds"))
    }
}
