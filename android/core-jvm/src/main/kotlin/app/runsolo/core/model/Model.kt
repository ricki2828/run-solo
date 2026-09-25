package app.runsolo.core.model

/**
 * Core-owned value types. They mirror the Pigeon enums in `app.runsolo.platform` by name so
 * the Android shell maps them with `valueOf(name)`; core-jvm must not depend on the generated
 * Pigeon file (it carries Flutter imports).
 */
/**
 * Run type picked at Start (plan §18.2). `laps` is the lap-capable by-feel run (schema-1 `free`
 * maps here, §18.7 B1); `free` has no lap input at all; `cooper` is vocabulary for the schema-2
 * file format (Phase 3 protocol) and records like `free` until then.
 */
enum class RunMode {
    fourByFour, laps, free, cooper;

    /** Whether LAP presses (button, notification, volume key) are accepted at all. Exhaustive: a new mode must decide. */
    val lapInput: Boolean
        get() = when (this) {
            fourByFour, laps -> true
            free, cooper -> false
        }

    /** Volume-key laps default (W8): on only for the by-feel Laps run. */
    val volumeKeyLapsDefault: Boolean
        get() = when (this) {
            laps -> true
            fourByFour, free, cooper -> false
        }

    /** Only the 4x4 carries a preset in the header; every other mode's preset is null. */
    val usesPreset: Boolean
        get() = when (this) {
            fourByFour -> true
            laps, free, cooper -> false
        }
}

enum class Units { km, mi }

enum class LapSource { button, notification, volumeKey, auto }

enum class LapKind { manual, auto, pause }

enum class Phase { none, warmup, work, recovery, cooldown }

enum class CueKind { halfway, thirtySeconds, phaseEnd, start, stop }

enum class RecorderState { idle, recording, paused, finalising }

/** The 4x4 preset written into the file header; drives both cues and the detector (plan §6). */
data class Preset(val reps: Int, val workSeconds: Int, val recoverySeconds: Int) {
    init {
        // Plan §6: reps 3–6. The Dart parser rejects a file outside this range, so both sides agree.
        require(reps in MIN_REPS..MAX_REPS) { "reps out of range: $reps" }
        require(workSeconds > 0 && recoverySeconds > 0) { "preset durations must be positive" }
    }

    val workMs: Long get() = workSeconds * 1000L
    val recoveryMs: Long get() = recoverySeconds * 1000L

    fun toJson(): Map<String, Any?> =
        linkedMapOf("reps" to reps, "workSeconds" to workSeconds, "recoverySeconds" to recoverySeconds)

    companion object {
        const val MIN_REPS = 3
        const val MAX_REPS = 6
        val DEFAULT_4X4 = Preset(reps = 4, workSeconds = 240, recoverySeconds = 180)

        fun fromJson(m: Map<String, Any?>?): Preset? {
            m ?: return null
            return Preset(
                reps = (m["reps"] as Number).toInt(),
                workSeconds = (m["workSeconds"] as Number).toInt(),
                recoverySeconds = (m["recoverySeconds"] as Number).toInt(),
            )
        }
    }
}

/** A raw location fix as delivered by the platform. [t] is device monotonic millis. */
data class LocationFix(
    val t: Long,
    val lat: Double,
    val lon: Double,
    val altM: Double?,
    val accuracyM: Double,
    val speedMps: Double?,
)

/** One parsed BLE reading. [t] is device monotonic millis at receipt. */
data class HrReading(val t: Long, val bpm: Int)
