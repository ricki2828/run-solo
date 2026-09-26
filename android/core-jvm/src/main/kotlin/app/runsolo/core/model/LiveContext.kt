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

/** In-run nudges (§3.5). LC1 stub with no rules (WARN-6); CR1 fills it. `version` 0 = none. */
data class NudgePlan(val version: Int = 0) {
    fun toJson(): Map<String, Any?> = linkedMapOf("version" to version)

    companion object {
        fun fromJson(m: Map<String, Any?>) = NudgePlan(version = m.int("version"))
    }
}

private fun bad(what: String): Nothing = throw IllegalArgumentException("non-numeric value in $what")

@Suppress("UNCHECKED_CAST")
private fun Any?.asObj(what: String): Map<String, Any?> = this as? Map<String, Any?> ?: throw IllegalArgumentException("$what is not an object")

private fun Map<String, Any?>.doublesOrNull(key: String): List<Double>? =
    (this[key] as? List<*>)?.map { (it as? Number ?: bad(key)).toDouble() }
