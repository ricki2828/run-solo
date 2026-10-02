package app.runsolo.platform

import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseRouteResult
import androidx.health.connect.client.records.ExerciseSegment
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Health Connect records a run becomes: laps, pauses, heart rate, route, upsert ids, offsets. */
class HealthRecordsTest {
    private val t0 = 1_760_000_000_000L

    private fun workout(
        hr: List<HealthHrSample> = listOf(HealthHrSample(t0 + 5_000, 140), HealthHrSample(t0 + 10_000, 150)),
        route: List<HealthRoutePoint> = listOf(
            HealthRoutePoint(t0 + 5_000, -37.8, 144.9, 12.0, 4.0),
            HealthRoutePoint(t0 + 10_000, -37.81, 144.91),
        ),
        pauses: List<HealthPause> = emptyList(),
        offset: Long = 36_000,
        version: Long = 7,
    ) = HealthWorkout(
        clientRecordId = "11111111-1111-4111-8111-111111111111",
        version = version,
        title = "Morning run",
        startEpochMs = t0,
        endEpochMs = t0 + 60_000,
        utcOffsetSeconds = offset,
        distanceM = 200.0,
        laps = listOf(HealthLap(t0, t0 + 30_000, 100.0), HealthLap(t0 + 30_000, t0 + 60_000, 100.0)),
        pauses = pauses,
        hr = hr,
        route = route,
    )

    /** The route's points, or null when the session carries no route. */
    private fun routeOf(s: ExerciseSessionRecord): List<ExerciseRoute.Location>? =
        (s.exerciseRouteResult as? ExerciseRouteResult.Data)?.exerciseRoute?.route

    @Test
    fun `session is a run with laps, route and the phone offset`() {
        val recs = HealthRecords.toRecords(workout(), includeRoute = true)
        val s = recs.filterIsInstance<ExerciseSessionRecord>().single()
        assertEquals(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, s.exerciseType)
        assertEquals("Morning run", s.title)
        assertEquals(2, s.laps.size)
        assertEquals(100.0, s.laps[0].length!!.inMeters, 1e-6)
        assertEquals(36_000, s.startZoneOffset!!.totalSeconds)
        assertEquals(36_000, s.endZoneOffset!!.totalSeconds)
        assertEquals(2, routeOf(s)!!.size)
    }

    @Test
    fun `route is left out without the route permission`() {
        val s = HealthRecords.toRecords(workout(), includeRoute = false).filterIsInstance<ExerciseSessionRecord>().single()
        assertNull(routeOf(s))
    }

    @Test
    fun `route points outside the session are dropped`() {
        val w = workout(route = listOf(HealthRoutePoint(t0 - 1_000, 1.0, 1.0), HealthRoutePoint(t0 + 5_000, 1.0, 1.0)))
        val s = HealthRecords.toRecords(w, true).filterIsInstance<ExerciseSessionRecord>().single()
        assertEquals(1, routeOf(s)!!.size)
    }

    @Test
    fun `pauses become pause segments`() {
        val w = workout(pauses = listOf(HealthPause(t0 + 10_000, t0 + 20_000)))
        val s = HealthRecords.toRecords(w, true).filterIsInstance<ExerciseSessionRecord>().single()
        assertEquals(1, s.segments.size)
        assertEquals(ExerciseSegment.EXERCISE_SEGMENT_TYPE_PAUSE, s.segments[0].segmentType)
    }

    @Test
    fun `heart rate and distance records`() {
        val recs = HealthRecords.toRecords(workout(), true)
        val hr = recs.filterIsInstance<HeartRateRecord>().single()
        assertEquals(listOf(140L, 150L), hr.samples.map { it.beatsPerMinute })
        assertEquals(200.0, recs.filterIsInstance<DistanceRecord>().single().distance.inMeters, 1e-6)
    }

    @Test
    fun `a long run splits heart rate into chunks and a single sample still fits`() {
        val many = (0 until HealthRecords.HR_CHUNK + 1).map { HealthHrSample(t0 + it * 10L, 140) }
        val recs = HealthRecords.toRecords(workout(hr = many), true).filterIsInstance<HeartRateRecord>()
        assertEquals(2, recs.size)
        val one = HealthRecords.toRecords(workout(hr = listOf(HealthHrSample(t0 + 5_000, 140))), true)
            .filterIsInstance<HeartRateRecord>().single()
        assertTrue(one.endTime.isAfter(one.startTime))
    }

    @Test
    fun `implausible heart rates are dropped and no hr means no hr record`() {
        val w = workout(hr = listOf(HealthHrSample(t0 + 1_000, 0), HealthHrSample(t0 + 2_000, 400)))
        assertTrue(HealthRecords.toRecords(w, true).none { it is HeartRateRecord })
    }

    @Test
    fun `every record id derives from the run id and carries the version, so a re-send upserts`() {
        val w = workout(version = 42)
        val recs = HealthRecords.toRecords(w, true)
        val ids = recs.map { it.metadata.clientRecordId }
        assertEquals(
            listOf(HealthRecords.sessionId(w), HealthRecords.distanceId(w), HealthRecords.heartRateId(w, 0)),
            ids,
        )
        assertTrue(ids.all { it!!.startsWith(w.clientRecordId) })
        assertTrue(recs.all { it.metadata.clientRecordVersion == 42L })
        // Same input, same ids: sending again replaces rather than duplicates.
        assertEquals(ids, HealthRecords.toRecords(w, true).map { it.metadata.clientRecordId })
        assertNotNull(recs.first().metadata.clientRecordId)
    }
}
