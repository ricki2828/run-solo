package app.runsolo.core.model

/**
 * Core-owned value types. They mirror the Pigeon enums in `app.runsolo.platform` by name so
 * the Android shell maps them with `valueOf(name)`; core-jvm must not depend on the generated
 * Pigeon file (it carries Flutter imports).
 */
enum class RunMode { fourByFour, free }

enum class Units { km, mi }

enum class LapSource { button, notification, volumeKey, auto }

enum class LapKind { manual, auto, pause }

enum class Phase { none, warmup, work, recovery, cooldown }

enum class CueKind { halfway, thirtySeconds, phaseEnd, start, stop }

enum class RecorderState { idle, recording, paused, finalising }

/** The 4x4 preset written into the file header; drives both cues and the detector (plan §6). */
data class Preset(val reps: Int, val workSeconds: Int, val recoverySeconds: Int) {
    init {
        require(reps in 1..12) { "reps out of range: $reps" }
        require(workSeconds > 0 && recoverySeconds > 0) { "preset durations must be positive" }
    }

    val workMs: Long get() = workSeconds * 1000L
    val recoveryMs: Long get() = recoverySeconds * 1000L

    fun toJson(): Map<String, Any?> =
        linkedMapOf("reps" to reps, "workSeconds" to workSeconds, "recoverySeconds" to recoverySeconds)

    companion object {
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
