package app.runsolo.platform

import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseLap
import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseSegment
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Length
import java.time.Instant
import java.time.ZoneOffset

/**
 * A [HealthWorkout] (already thinned and trimmed by Dart) as Health Connect records: one running
 * session with laps, pauses and, when the route permission is held, the route; heart-rate series;
 * one distance record. Every record's `clientRecordId` derives from the run id and the version
 * rises with each write, so sending a run again replaces it instead of duplicating it.
 */
object HealthRecords {
    /** Heart-rate samples per record; a long run becomes several records. */
    const val HR_CHUNK = 900

    const val MIN_BPM = 1L
    const val MAX_BPM = 300L

    fun sessionId(w: HealthWorkout) = w.clientRecordId
    fun distanceId(w: HealthWorkout) = "${w.clientRecordId}-distance"
    fun heartRateId(w: HealthWorkout, chunk: Int) = "${w.clientRecordId}-hr-$chunk"

    fun toRecords(w: HealthWorkout, includeRoute: Boolean): List<Record> {
        val zone = ZoneOffset.ofTotalSeconds(w.utcOffsetSeconds.toInt().coerceIn(-18 * 3600, 18 * 3600))
        val start = Instant.ofEpochMilli(w.startEpochMs)
        val end = Instant.ofEpochMilli(maxOf(w.endEpochMs, w.startEpochMs + 1000))
        val device = Device(type = Device.TYPE_PHONE)
        fun meta(id: String) = Metadata.activelyRecorded(device, id, w.version)
        fun inside(ms: Long) = ms >= start.toEpochMilli() && ms <= end.toEpochMilli()

        val laps = w.laps
            .filter { it.endEpochMs > it.startEpochMs && inside(it.startEpochMs) && inside(it.endEpochMs) }
            .sortedBy { it.startEpochMs }
            .map {
                ExerciseLap(
                    Instant.ofEpochMilli(it.startEpochMs),
                    Instant.ofEpochMilli(it.endEpochMs),
                    Length.meters(it.distanceM.coerceAtLeast(0.0)),
                )
            }
        val pauses = w.pauses
            .filter { it.endEpochMs > it.startEpochMs && inside(it.startEpochMs) && inside(it.endEpochMs) }
            .sortedBy { it.startEpochMs }
            .map {
                ExerciseSegment(
                    Instant.ofEpochMilli(it.startEpochMs),
                    Instant.ofEpochMilli(it.endEpochMs),
                    ExerciseSegment.EXERCISE_SEGMENT_TYPE_PAUSE,
                    0,
                )
            }
        val route = if (includeRoute) {
            w.route
                .filter { inside(it.epochMs) && it.lat in -90.0..90.0 && it.lon in -180.0..180.0 }
                .sortedBy { it.epochMs }
                .map {
                    ExerciseRoute.Location(
                        time = Instant.ofEpochMilli(it.epochMs),
                        latitude = it.lat,
                        longitude = it.lon,
                        horizontalAccuracy = it.accuracyM?.takeIf { a -> a >= 0 }?.let { a -> Length.meters(a) },
                        altitude = it.altM?.let { a -> Length.meters(a) },
                    )
                }
                .takeIf { it.isNotEmpty() }
                ?.let { ExerciseRoute(it) }
        } else {
            null
        }

        val out = ArrayList<Record>()
        out += ExerciseSessionRecord(
            startTime = start,
            startZoneOffset = zone,
            endTime = end,
            endZoneOffset = zone,
            metadata = meta(sessionId(w)),
            exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_RUNNING,
            title = w.title,
            notes = null,
            segments = pauses,
            laps = laps,
            exerciseRoute = route,
        )
        if (w.distanceM > 0.0) {
            out += DistanceRecord(
                startTime = start,
                startZoneOffset = zone,
                endTime = end,
                endZoneOffset = zone,
                distance = Length.meters(w.distanceM),
                metadata = meta(distanceId(w)),
            )
        }
        val hr = w.hr
            .filter { inside(it.epochMs) && it.bpm in MIN_BPM..MAX_BPM }
            .sortedBy { it.epochMs }
        hr.chunked(HR_CHUNK).forEachIndexed { i, chunk ->
            val first = Instant.ofEpochMilli(chunk.first().epochMs)
            val last = Instant.ofEpochMilli(chunk.last().epochMs)
            out += HeartRateRecord(
                startTime = first,
                startZoneOffset = zone,
                endTime = if (last.isAfter(first)) last else first.plusSeconds(1),
                endZoneOffset = zone,
                samples = chunk.map { HeartRateRecord.Sample(Instant.ofEpochMilli(it.epochMs), it.bpm) },
                metadata = meta(heartRateId(w, i)),
            )
        }
        return out
    }
}
