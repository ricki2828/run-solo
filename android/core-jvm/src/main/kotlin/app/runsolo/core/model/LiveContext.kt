package app.runsolo.core.model

import app.runsolo.core.json.double
import app.runsolo.core.json.int
import app.runsolo.core.json.list
import app.runsolo.core.json.long
import app.runsolo.core.json.obj
import app.runsolo.core.json.string
import kotlin.math.abs

/**
 * The live "you vs you" context (Phase 4 plan §3.2, LC1 contract): built by the app at Start
 * (150 ms or not at all), passed through `start()`, journaled as the `lctx` line straight after
 * the header and rebuilt from it on restore (BLOCK-1). Kotlin never reads history; everything the
 * live compare, the Cooper projection and the nudges need is in here. Mirrors the Pigeon
 * `LiveContext`; the JSON key order is canonical (journal line).
 */
data class LiveContext(
    /** At most [MAX_BOARDS]. */
    val boards: List<LiveBoard>,
    val target: LiveTarget? = null,
    val nudges: NudgePlan? = null,
    /** Cooper: cumulative fade fractions F(1)..F(12), F(12) = 1 (§3.3). */
    val cooperCurve: List<Double>? = null,
    /** Cooper: past raw VO2 estimates, oldest first. */
    val cooperHistory: List<Double>? = null,
    val coachingMuted: Boolean = false,
    val builtAtMs: Long,
    val engineVersion: Int,
) {
    init {
        require(boards.size <= MAX_BOARDS) { "at most $MAX_BOARDS live boards, got ${boards.size}" }
        cooperCurve?.let { f ->
            require(f.size == COOPER_MINUTES) { "cooperCurve needs $COOPER_MINUTES points" }
            require(f.all { it.isFinite() } && f.first() > 0) { "cooperCurve must be finite and start above 0" }
            require(f.zipWithNext().all { (a, b) -> b > a }) { "cooperCurve must increase" }
            require(abs(f.last() - 1.0) < 1e-9) { "cooperCurve must end at F(12) = 1" }
        }
        require(cooperHistory == null || cooperHistory.all { it.isFinite() }) { "cooperHistory must be finite" }
    }

    /** The previous Cooper test's VO2, for "up 2 on last time". */
    val lastCooperVo2: Double? get() = cooperHistory?.lastOrNull()

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "boards" to boards.map { it.toJson() },
        "target" to target?.toJson(),
        "nudges" to nudges?.toJson(),
        "cooperCurve" to cooperCurve,
        "cooperHistory" to cooperHistory,
        "coachingMuted" to coachingMuted,
        "builtAtMs" to builtAtMs,
        "engineVersion" to engineVersion,
    )

    companion object {
        const val MAX_BOARDS = 3
        const val MAX_ENTRIES = 20
        const val COOPER_MINUTES = 12

        fun fromJson(m: Map<String, Any?>): LiveContext = LiveContext(
            boards = m.list("boards").map { LiveBoard.fromJson(it.asObj("boards[]")) },
            target = m.obj("target")?.let { LiveTarget.fromJson(it) },
            nudges = m.obj("nudges")?.let { NudgePlan.fromJson(it) },
            cooperCurve = m.doublesOrNull("cooperCurve"),
            cooperHistory = m.doublesOrNull("cooperHistory"),
            coachingMuted = m["coachingMuted"] as? Boolean ?: throw IllegalArgumentException("coachingMuted"),
            builtAtMs = m.long("builtAtMs"),
            engineVersion = m.int("engineVersion"),
        )
    }
}

enum class LiveBoardKind { distance, intervals, cooper }

/** A board the live compare ranks against: at most [LiveContext.MAX_ENTRIES] entries. */
data class LiveBoard(
    val key: String,
    /** Spoken and shown; the app injects any event name. */
    val label: String,
    val kind: LiveBoardKind,
    /** Distance boards: the board's distance in metres. */
    val targetM: Double? = null,
    val entries: List<LiveEntry>,
) {
    init {
        require(entries.size <= LiveContext.MAX_ENTRIES) { "at most ${LiveContext.MAX_ENTRIES} entries on $key" }
        for (e in entries) {
            val series = when (kind) {
                LiveBoardKind.distance -> e.fromStartSplitsMs
                LiveBoardKind.intervals -> e.liveRepPacesSecPerKm
                LiveBoardKind.cooper -> e.cooperMinuteM
            }
            require(series != null) { "a $kind entry needs its series (${e.runId})" }
        }
    }

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "key" to key,
        "label" to label,
        "kind" to kind.name,
        "targetM" to targetM,
        "entries" to entries.map { it.toJson() },
    )

    companion object {
        fun fromJson(m: Map<String, Any?>) = LiveBoard(
            key = m.string("key"),
            label = m.string("label"),
            kind = LiveBoardKind.valueOf(m.string("kind")),
            targetM = (m["targetM"] as? Number)?.toDouble(),
            entries = m.list("entries").map { LiveEntry.fromJson(it.asObj("entries[]")) },
        )
    }
}

/**
 * One prior run on a board. The series matching the board's kind is set: [fromStartSplitsMs]
 * (ms from the Start press at each whole km, WARN-1), [liveRepPacesSecPerKm] (untrimmed per work
 * rep, null = unclean rep, BLOCK-2) or [cooperMinuteM] (metres at each whole test minute).
 */
data class LiveEntry(
    val runId: String,
    /** Run start, epoch millis. */
    val dateMs: Long,
    val fromStartSplitsMs: List<Long>? = null,
    val liveRepPacesSecPerKm: List<Double?>? = null,
    val cooperMinuteM: List<Double>? = null,
    /** Finish ms, mean rep pace s/km, or raw Cooper VO2. */
    val finalMetric: Double,
) {
    init {
        require(finalMetric.isFinite()) { "finalMetric must be finite ($runId)" }
        require(liveRepPacesSecPerKm == null || liveRepPacesSecPerKm.all { it == null || it.isFinite() }) {
            "liveRepPacesSecPerKm must be finite ($runId)"
        }
        require(cooperMinuteM == null || cooperMinuteM.all { it.isFinite() }) { "cooperMinuteM must be finite ($runId)" }
    }

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "runId" to runId,
        "dateMs" to dateMs,
        "fromStartSplitsMs" to fromStartSplitsMs,
        "liveRepPacesSecPerKm" to liveRepPacesSecPerKm,
        "cooperMinuteM" to cooperMinuteM,
        "finalMetric" to finalMetric,
    )

    companion object {
        fun fromJson(m: Map<String, Any?>) = LiveEntry(
            runId = m.string("runId"),
            dateMs = m.long("dateMs"),
            fromStartSplitsMs = (m["fromStartSplitsMs"] as? List<*>)?.map { (it as? Number ?: bad("fromStartSplitsMs")).toLong() },
            liveRepPacesSecPerKm = (m["liveRepPacesSecPerKm"] as? List<*>)?.map {
                if (it == null) null else (it as? Number ?: bad("liveRepPacesSecPerKm")).toDouble()
            },
            cooperMinuteM = m.doublesOrNull("cooperMinuteM"),
            finalMetric = m.double("finalMetric"),
        )
    }
}

/** A target to race (§3.4): even splits over [distanceM]; PD2 fills it. */
data class LiveTarget(val distanceM: Double, val targetMs: Long, val predicted: Boolean) {
    fun toJson(): Map<String, Any?> = linkedMapOf("distanceM" to distanceM, "targetMs" to targetMs, "predicted" to predicted)

    companion object {
        fun fromJson(m: Map<String, Any?>) = LiveTarget(
            distanceM = m.double("distanceM"),
            targetMs = m.long("targetMs"),
            predicted = m["predicted"] as? Boolean ?: throw IllegalArgumentException("target.predicted"),
        )
    }
}

/**
 * In-run nudges (§3.5, CR1): thresholds the engine built from the runner's own history
 * (`NudgePlanSpec.toJson` in `coaching_rules.dart`, mirrored key for key); native only compares
 * live figures against them. A null rule is off. [blocked] = "rule:index" said on the previous
 * run of this board (WARN-5), never said again this run. `version` 0 = the LC1 stub (no rules).
 */
data class NudgePlan(
    val version: Int = 0,
    val fastStart: FastStartRule? = null,
    val repFade: RepFadeRule? = null,
    val hrDrift: HrDriftRule? = null,
    val blocked: List<String> = emptyList(),
) {
    fun toJson(): Map<String, Any?> = linkedMapOf(
        "version" to version,
        "fastStart" to fastStart?.toJson(),
        "repFade" to repFade?.toJson(),
        "hrDrift" to hrDrift?.toJson(),
        "blocked" to blocked,
    )

    companion object {
        /** Rule names; they key the `cue_fired` lines the next run's [blocked] comes from. */
        const val FAST_START = "fast_start"
        const val REP_FADE = "rep_fade"
        const val HR_DRIFT = "hr_drift"

        fun fromJson(m: Map<String, Any?>) = NudgePlan(
            version = m.int("version"),
            fastStart = m.obj("fastStart")?.let { FastStartRule(it.long("km1MaxMs"), it.string("text")) },
            repFade = m.obj("repFade")?.let { RepFadeRule(it.nullableDoubles("maxDropSecPerKm"), it.string("text")) },
            hrDrift = m.obj("hrDrift")?.let {
                HrDriftRule(
                    kmSamples = it.list("kmSamples").map { km ->
                        (km as? List<*> ?: bad("kmSamples")).map { pair ->
                            val p = pair as? List<*> ?: bad("kmSamples")
                            require(p.size == 2) { "kmSamples pairs are [pace, hr]" }
                            (p[0] as? Number ?: bad("kmSamples")).toDouble() to (p[1] as? Number ?: bad("kmSamples")).toDouble()
                        }
                    },
                    bpmOver = (it["bpmOver"] as? Number)?.toDouble() ?: HrDriftRule.BPM_OVER,
                    paceBand = (it["paceBand"] as? Number)?.toDouble() ?: HrDriftRule.PACE_BAND,
                    firstKm = (it["firstKm"] as? Number)?.toInt() ?: HrDriftRule.FIRST_KM,
                    minSimilar = (it["minSimilar"] as? Number)?.toInt() ?: HrDriftRule.MIN_SIMILAR,
                    text = it.string("text"),
                )
            },
            blocked = (m["blocked"] as? List<*>)?.map { it as? String ?: bad("blocked") } ?: emptyList(),
        )
    }
}

/** Fire at km 1 when the live km-1 split (ms from Start) is under [km1MaxMs]. */
data class FastStartRule(val km1MaxMs: Long, val text: String) {
    fun toJson(): Map<String, Any?> = linkedMapOf("km1MaxMs" to km1MaxMs, "text" to text)
}

/** At the end of rep r ≥ 3: fire when live rep r pace − rep 1 pace (s/km) > [maxDropSecPerKm] `[r − 1]` (null = off for r). */
data class RepFadeRule(val maxDropSecPerKm: List<Double?>, val text: String) {
    fun toJson(): Map<String, Any?> = linkedMapOf("maxDropSecPerKm" to maxDropSecPerKm, "text" to text)
}

/**
 * HR up for this pace (#56 review P2: like with like): [kmSamples] `[k − 1]` = the recent board
 * runs' (pace s/km, mean HR) at km k. The engine's `HrDriftRule.firesAt`, mirrored.
 */
data class HrDriftRule(
    val kmSamples: List<List<Pair<Double, Double>>>,
    val bpmOver: Double = BPM_OVER,
    val paceBand: Double = PACE_BAND,
    val firstKm: Int = FIRST_KM,
    val minSimilar: Int = MIN_SIMILAR,
    val text: String,
) {
    /**
     * At km [km] (1-based) with the live km pace and mean HR: the HRs of runs whose pace was within
     * [paceBand] of this one; with at least [minSimilar] of them, fire when [hr] ≥ their median +
     * [bpmOver].
     */
    fun firesAt(km: Int, paceSecPerKm: Double, hr: Double): Boolean {
        if (km < firstKm || km > kmSamples.size) return false
        val similar = kmSamples[km - 1].filter { (p, _) -> abs(p - paceSecPerKm) <= paceBand * paceSecPerKm }.map { it.second }.sorted()
        if (similar.size < minSimilar) return false
        val m = similar.size / 2
        val median = if (similar.size % 2 == 1) similar[m] else (similar[m - 1] + similar[m]) / 2
        return hr >= median + bpmOver
    }

    fun toJson(): Map<String, Any?> = linkedMapOf(
        "kmSamples" to kmSamples.map { km -> km.map { (p, h) -> listOf(p, h) } },
        "bpmOver" to bpmOver, "paceBand" to paceBand, "firstKm" to firstKm, "minSimilar" to minSimilar, "text" to text,
    )

    companion object {
        const val BPM_OVER = 5.0
        const val PACE_BAND = 0.05
        const val FIRST_KM = 4
        const val MIN_SIMILAR = 3
    }
}

private fun Map<String, Any?>.nullableDoubles(key: String): List<Double?> =
    (this[key] as? List<*> ?: throw IllegalArgumentException(key)).map { if (it == null) null else (it as? Number ?: bad(key)).toDouble() }

private fun bad(what: String): Nothing = throw IllegalArgumentException("non-numeric value in $what")

@Suppress("UNCHECKED_CAST")
private fun Any?.asObj(what: String): Map<String, Any?> = this as? Map<String, Any?> ?: throw IllegalArgumentException("$what is not an object")

private fun Map<String, Any?>.doublesOrNull(key: String): List<Double>? =
    (this[key] as? List<*>)?.map { (it as? Number ?: bad(key)).toDouble() }
