package app.runsolo.platform

import android.content.Context
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseRouteResult
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SpeedRecord
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.temporal.ChronoUnit
import kotlin.reflect.KClass

/**
 * SPIKE: reads running sessions OTHER apps wrote to Health Connect (decision X2, "any watch").
 * Dart keeps this off behind `kHealthConnectImport`; nothing here runs unless Dart asks.
 *
 * A plain MethodChannel (`app.runsolo/health_import`) instead of a Pigeon API: Pigeon output is
 * committed and CI-checked, so a throwaway read API would churn two generated files.
 *
 * The route is only read when Dart passes `includeRoute` (an explicit tap on one run). Health
 * Connect answers `ConsentRequired` when the runner has not consented for that read, and always
 * does so in the background; that is reported as `routeConsentRequired` and the run imports
 * routeless. Wire-format of the series is flat number lists, see `health_import_gateway.dart`.
 */
class HealthImportChannel(
    private val context: Context,
    private val prompter: HealthPrompter,
) : MethodChannel.MethodCallHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                when (call.method) {
                    "requestRead" -> requestRead(result)
                    "listRuns" -> result.success(listRuns(call.argument<Int>("days") ?: 30))
                    "readRun" -> result.success(
                        readRun(call.argument<String>("sessionId")!!, call.argument<Boolean>("includeRoute") == true),
                    )
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("permission", "Health Connect read permission missing", null)
            } catch (e: Exception) {
                Log.w(TAG, "health import ${call.method} failed", e)
                result.error("failed", e.message, null)
            }
        }
    }

    private fun available() = HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE

    private suspend fun requestRead(result: MethodChannel.Result) {
        if (!available()) {
            result.success(false)
            return
        }
        val client = HealthConnectClient.getOrCreate(context)
        val have = client.permissionController.getGrantedPermissions()
        if (have.containsAll(READ)) {
            result.success(true)
            return
        }
        prompter.request(READ) { granted -> result.success(granted.containsAll(READ)) }
    }

    private suspend fun <T : Record> readAll(
        client: HealthConnectClient,
        type: KClass<T>,
        from: Instant,
        to: Instant,
    ): List<T> {
        val out = ArrayList<T>()
        var token: String? = null
        do {
            val r = client.readRecords(
                ReadRecordsRequest(type, TimeRangeFilter.between(from, to), pageSize = 1000, pageToken = token),
            )
            out += r.records
            token = r.pageToken
        } while (token != null && out.size < MAX_RECORDS)
        return out
    }

    private fun isRun(s: ExerciseSessionRecord) =
        s.exerciseType == ExerciseSessionRecord.EXERCISE_TYPE_RUNNING ||
            s.exerciseType == ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL

    private suspend fun listRuns(days: Int): List<Map<String, Any?>> {
        if (!available()) return emptyList()
        val client = HealthConnectClient.getOrCreate(context)
        val to = Instant.now()
        val from = to.minus(days.toLong().coerceIn(1, 30), ChronoUnit.DAYS)
        return readAll(client, ExerciseSessionRecord::class, from, to)
            // Runs this app wrote itself are already in its history.
            .filter { isRun(it) && it.metadata.dataOrigin.packageName != context.packageName }
            .sortedByDescending { it.startTime }
            .map {
                mapOf(
                    "sessionId" to it.metadata.id,
                    "startMs" to it.startTime.toEpochMilli(),
                    "endMs" to it.endTime.toEpochMilli(),
                    "source" to it.metadata.dataOrigin.packageName,
                    "title" to it.title,
                )
            }
    }

    private suspend fun readRun(sessionId: String, includeRoute: Boolean): Map<String, Any?>? {
        if (!available()) return null
        val client = HealthConnectClient.getOrCreate(context)
        val session = client.readRecord(ExerciseSessionRecord::class, sessionId).record
        val from = session.startTime
        val to = session.endTime
        // Only the source app's own records: another app's overlapping data is not this run's.
        val origin = session.metadata.dataOrigin.packageName
        val distance = readAll(client, DistanceRecord::class, from, to).filter { it.metadata.dataOrigin.packageName == origin }
        val hr = readAll(client, HeartRateRecord::class, from, to).filter { it.metadata.dataOrigin.packageName == origin }
        val speed = readAll(client, SpeedRecord::class, from, to).filter { it.metadata.dataOrigin.packageName == origin }

        val route = ArrayList<Double>()
        var consent = false
        if (includeRoute) {
            when (val r = session.exerciseRouteResult) {
                is ExerciseRouteResult.Data -> for (p in r.exerciseRoute.route) {
                    route += p.time.toEpochMilli().toDouble()
                    route += p.latitude
                    route += p.longitude
                    route += p.altitude?.inMeters ?: Double.NaN
                }
                is ExerciseRouteResult.ConsentRequired -> consent = true
                else -> {}
            }
        }
        return mapOf(
            "sessionId" to session.metadata.id,
            "startMs" to from.toEpochMilli(),
            "endMs" to to.toEpochMilli(),
            "zoneOffsetMin" to session.startZoneOffset?.let { it.totalSeconds / 60 },
            "source" to origin,
            "title" to session.title,
            "distance" to distance.flatMap {
                listOf(it.startTime.toEpochMilli().toDouble(), it.endTime.toEpochMilli().toDouble(), it.distance.inMeters)
            },
            "heartRate" to hr.flatMap { rec ->
                rec.samples.flatMap { listOf(it.time.toEpochMilli().toDouble(), it.beatsPerMinute.toDouble()) }
            },
            "speed" to speed.flatMap { rec ->
                rec.samples.flatMap { listOf(it.time.toEpochMilli().toDouble(), it.speed.inMetersPerSecond) }
            },
            "route" to route,
            "routeConsentRequired" to consent,
        )
    }

    companion object {
        const val CHANNEL = "app.runsolo/health_import"
        private const val TAG = "RunSolo/healthimport"
        private const val MAX_RECORDS = 20000

        /**
         * Minimum read set. No steps (cadence is not a coach input yet), no sleep, no weight.
         * The route read permission is deliberately absent: Health Connect gates a route per
         * read with its own consent dialog, see the class comment.
         */
        val READ = setOf(
            "android.permission.health.READ_EXERCISE",
            "android.permission.health.READ_DISTANCE",
            "android.permission.health.READ_HEART_RATE",
            "android.permission.health.READ_SPEED",
        )
    }
}
