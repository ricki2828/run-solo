package app.runsolo.core.live

import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveTarget

enum class CompareKind { distance, intervals, cooper, target }

/**
 * One live comparison (Phase 4 §3.2): what the voice appends and `CompareEvent` shows. [rank] is
 * this run's place among itself and the [of] − 1 entries compared (entries without the figure
 * for this point are left out); lower time, pace or a higher VO2 ranks first.
 */
data class CompareResult(
    val boardKey: String,
    val boardLabel: String,
    val kind: CompareKind,
    /** The km, rep or minute this compare belongs to. */
    val index: Int,
    val rank: Int,
    val of: Int,
    /** distance / target: live − best entry (or the target's even split) in ms; negative = ahead. */
    val deltaMs: Long? = null,
    /** intervals: live mean rep pace 1..r − the best prior's, s/km; negative = faster. */
    val deltaSecPerKm: Double? = null,
    /** cooper: projected VO2 − the best past test; positive = better. */
    val deltaVo2: Double? = null,
    /** cooper: the projected VO2; target: the target time in ms. */
    val value: Double? = null,
)

/**
 * The comparisons, pure (no history in Kotlin: the engine packed the boards into the
 * LiveContext). A ghost compare against each entry's own figures at the same point, so no fade
 * model is needed and a fast start is never flattered.
 */
object LiveCompare {
    /** At km [km], live active time [activeMs] from Start vs each entry's `fromStartSplitsMs[km − 1]` (WARN-1). */
    fun distance(board: LiveBoard, km: Int, activeMs: Long): CompareResult? {
        val priors = board.entries.mapNotNull { it.fromStartSplitsMs?.getOrNull(km - 1) }
        if (priors.isEmpty()) return null
        return CompareResult(
            board.key, board.label, CompareKind.distance, km,
            rank = 1 + priors.count { it < activeMs }, of = priors.size + 1, deltaMs = activeMs - priors.min(),
        )
    }

    /**
     * After rep [rep]: the mean of the live untrimmed rep paces 1..rep vs each entry's mean of its
     * `liveRepPacesSecPerKm` 1..rep; an entry with a null (unclean rep) among them, or fewer reps,
     * is dropped for this rep, and so is the whole compare when a live rep is unclean (BLOCK-2).
     */
    fun intervals(board: LiveBoard, livePaces: List<Double?>, rep: Int): CompareResult? {
        if (rep < 1 || livePaces.size < rep) return null
        val live = livePaces.subList(0, rep)
        if (live.any { it == null }) return null
        val liveMean = live.sumOf { it!! } / rep
        val priors = board.entries.mapNotNull { e ->
            val p = e.liveRepPacesSecPerKm ?: return@mapNotNull null
            if (p.size < rep) return@mapNotNull null
            val first = p.subList(0, rep)
            if (first.any { it == null }) null else first.sumOf { it!! } / rep
        }
        if (priors.isEmpty()) return null
        return CompareResult(
            board.key, board.label, CompareKind.intervals, rep,
            rank = 1 + priors.count { it < liveMean }, of = priors.size + 1, deltaSecPerKm = liveMean - priors.min(),
        )
    }

    /** At minute [minute] of a Cooper, the projected VO2 vs every past test's (`cooperHistory`). */
    fun cooper(history: List<Double>, minute: Int, vo2: Double): CompareResult? {
        if (history.isEmpty()) return null
        return CompareResult(
            "cooper", "Cooper", CompareKind.cooper, minute,
            rank = 1 + history.count { it > vo2 }, of = history.size + 1, deltaVo2 = vo2 - history.max(), value = vo2,
        )
    }

    /** At km [km] of the target distance, [elapsedMs] into it vs the target's even split. */
    fun target(target: LiveTarget, km: Int, elapsedMs: Long): CompareResult? {
        if (km * 1_000.0 >= target.distanceM) return null
        val split = (target.targetMs * (km * 1_000.0 / target.distanceM)).toLong()
        return CompareResult(
            "target", if (target.predicted) "predicted" else "target", CompareKind.target, km,
            rank = 1, of = 1, deltaMs = elapsedMs - split, value = target.targetMs.toDouble(),
        )
    }
}
