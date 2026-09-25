package app.runsolo.core.model

/**
 * Core-owned value types. They mirror the Pigeon enums in `app.runsolo.platform` by name so
 * the Android shell maps them with `valueOf(name)`; core-jvm must not depend on the generated
 * Pigeon file (it carries Flutter imports).
 */
/**
 * Run type picked at Start (plan §18.2, Phase 3 §3.8). `intervals` follows a [SessionSpec]
 * (schema ≤ 2 `fourByFour` maps here); `laps` is the lap-capable by-feel run (schema-1 `free`
 * maps here, §18.7 B1), optionally a fartlek; `free` has no lap input at all; `cooper` carries
 * the Cooper spec and records like `free` until I2.
 */
enum class RunMode {
    intervals, laps, free, cooper;

    /** Whether LAP presses (button, notification, volume key) are accepted at all. Exhaustive: a new mode must decide. */
    val lapInput: Boolean
        get() = when (this) {
            intervals, laps -> true
            free, cooper -> false
        }

    /** Volume-key laps default (W8): on only for the by-feel Laps run. */
    val volumeKeyLapsDefault: Boolean
        get() = when (this) {
            laps -> true
            intervals, free, cooper -> false
        }

    /** Whether the run's phases follow its session's steps. */
    val followsSteps: Boolean
        get() = when (this) {
            intervals -> true
            laps, free, cooper -> false
        }

    companion object {
        /** Schema ≤ 2 wrote the structured run as `fourByFour`. */
        const val LEGACY_FOUR_BY_FOUR = "fourByFour"
    }
}

enum class Units { km, mi }

enum class LapSource { button, notification, volumeKey, auto }

enum class LapKind { manual, auto, pause }

enum class Phase { none, warmup, work, recovery, cooldown }

enum class CueKind { halfway, thirtySeconds, phaseEnd, start, stop, distanceToGo, lastRep, minuteMark, countdown, projection }

enum class RecorderState { idle, recording, paused, finalising }

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
