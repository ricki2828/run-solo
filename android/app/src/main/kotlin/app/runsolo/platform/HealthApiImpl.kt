package app.runsolo.platform

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.health.connect.client.HealthConnectClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Shows Health Connect's permission screen; answers the permissions that are granted afterwards. */
fun interface HealthPrompter {
    fun request(permissions: Set<String>, callback: (Set<String>) -> Unit)
}

/**
 * Writes finished runs to Health Connect. Write only: no read permission is declared or asked.
 * Permissions are asked from a runner's tap (Settings switch or the Send sheet), never from the
 * background; a write without them reports `permissionDenied` and writes nothing.
 */
class HealthApiImpl(
    private val context: Context,
    private val prompter: HealthPrompter,
) : HealthApi {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private fun availability(): HealthAvailability = when (HealthConnectClient.getSdkStatus(context)) {
        HealthConnectClient.SDK_AVAILABLE -> HealthAvailability.AVAILABLE
        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthAvailability.NEEDS_UPDATE
        // Android 14+ has it built in: unavailable there means this phone does not support it.
        else -> if (Build.VERSION.SDK_INT >= 34) HealthAvailability.UNSUPPORTED else HealthAvailability.NOT_INSTALLED
    }

    override fun status(callback: (Result<HealthStatus>) -> Unit) {
        scope.launch {
            val a = availability()
            if (a != HealthAvailability.AVAILABLE) {
                callback(Result.success(HealthStatus(a, coreGranted = false, routeGranted = false)))
                return@launch
            }
            val granted = try {
                HealthConnectClient.getOrCreate(context).permissionController.getGrantedPermissions()
            } catch (e: Exception) {
                Log.w(TAG, "granted permissions unreadable", e)
                emptySet()
            }
            callback(Result.success(HealthStatus(a, granted.containsAll(CORE), ROUTE in granted)))
        }
    }

    override fun requestAccess(route: Boolean, callback: (Result<Boolean>) -> Unit) {
        scope.launch {
            if (availability() != HealthAvailability.AVAILABLE) {
                callback(Result.success(false))
                return@launch
            }
            val wanted = if (route) setOf(ROUTE) else CORE
            val client = HealthConnectClient.getOrCreate(context)
            val already = try {
                client.permissionController.getGrantedPermissions()
            } catch (e: Exception) {
                emptySet()
            }
            if (already.containsAll(wanted)) {
                callback(Result.success(true))
                return@launch
            }
            prompter.request(wanted) { granted -> callback(Result.success(granted.containsAll(wanted))) }
        }
    }

    override fun openInstall() {
        val pkg = PROVIDER_PACKAGE
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$pkg"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(market)
        } catch (_: Exception) {
            try {
                context.startActivity(web)
            } catch (_: Exception) {
            }
        }
    }

    override fun writeWorkout(workout: HealthWorkout, callback: (Result<HealthWriteResult>) -> Unit) {
        scope.launch {
            fun reply(o: HealthWriteOutcome, detail: String? = null) =
                callback(Result.success(HealthWriteResult(o, detail)))
            if (availability() != HealthAvailability.AVAILABLE) {
                reply(HealthWriteOutcome.NOT_AVAILABLE)
                return@launch
            }
            try {
                val client = HealthConnectClient.getOrCreate(context)
                val granted = client.permissionController.getGrantedPermissions()
                if (!granted.containsAll(CORE)) {
                    reply(HealthWriteOutcome.PERMISSION_DENIED)
                    return@launch
                }
                val withRoute = ROUTE in granted
                client.insertRecords(HealthRecords.toRecords(workout, includeRoute = withRoute))
                reply(
                    if (!withRoute && workout.route.isNotEmpty()) HealthWriteOutcome.WRITTEN_WITHOUT_ROUTE
                    else HealthWriteOutcome.WRITTEN,
                )
            } catch (e: SecurityException) {
                reply(HealthWriteOutcome.PERMISSION_DENIED)
            } catch (e: Exception) {
                Log.w(TAG, "health write failed", e)
                reply(HealthWriteOutcome.FAILED, "Could not write to Health Connect")
            }
        }
    }

    companion object {
        private const val TAG = "RunSolo/health"

        /** Health Connect's app on Android 13 and older (the client's own constant is internal). */
        private const val PROVIDER_PACKAGE = "com.google.android.apps.healthdata"

        /** The three core write permissions. The route is asked on its own (Health Connect requires it). */
        val CORE = setOf(
            "android.permission.health.WRITE_EXERCISE",
            "android.permission.health.WRITE_HEART_RATE",
            "android.permission.health.WRITE_DISTANCE",
        )
        const val ROUTE = "android.permission.health.WRITE_EXERCISE_ROUTE"
    }
}
