package app.runsolo.record

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import app.runsolo.platform.ExitDiagnosis
import app.runsolo.platform.ExitReason

/**
 * Was the process killed by the OS while a run was recording (plan §3, W11)? Every start and
 * resume records `runId → wall time` in prefs; on the next open, `ApplicationExitInfo`
 * (API 30+) is searched for the EARLIEST exit after that time — the kill that interrupted
 * the run, not a later swipe-away after the recovery dialog. API 29 has no record → `none`.
 * Entries are pruned when the run is stopped.
 */
object ExitDiagnostics {
    private const val PREFS = "runsolo.runs"

    fun noteStart(context: Context, runId: String, startWallMs: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("start.$runId", startWallMs)
            .putLong("since.$runId", startWallMs)
            .apply()
    }

    /** A resume after a kill: only exits after this moment count for the next diagnosis. */
    fun noteResume(context: Context, runId: String, resumeWallMs: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong("since.$runId", resumeWallMs)
            .apply()
    }

    fun noteStopped(context: Context, runId: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .remove("start.$runId")
            .remove("since.$runId")
            .apply()
    }

    fun diagnose(context: Context, runId: String): ExitDiagnosis {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val since = prefs.getLong("since.$runId", -1)
        val none = ExitDiagnosis(runId = runId, reason = ExitReason.NONE, timestampMs = 0, description = null, manufacturer = manufacturer)
        if (since < 0) return none
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return none
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val exits = try {
            am.getHistoricalProcessExitReasons(null, 0, 16)
        } catch (_: Exception) {
            return none
        }
        val hit = exits.filter { it.timestamp >= since }.minByOrNull { it.timestamp } ?: return none
        val reason = when (hit.reason) {
            ApplicationExitInfo.REASON_LOW_MEMORY -> ExitReason.LOW_MEMORY
            ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR -> ExitReason.CRASH
            ApplicationExitInfo.REASON_USER_REQUESTED, ApplicationExitInfo.REASON_USER_STOPPED -> ExitReason.USER_STOP
            ApplicationExitInfo.REASON_EXIT_SELF -> ExitReason.NONE
            ApplicationExitInfo.REASON_OTHER, ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            ApplicationExitInfo.REASON_PERMISSION_CHANGE, ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_DEPENDENCY_DIED, ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            -> ExitReason.OS_KILLED
            else -> if (hit.reason == 14 /* REASON_FREEZER, API 31 */) ExitReason.OS_KILLED else ExitReason.OTHER
        }
        return ExitDiagnosis(
            runId = runId,
            reason = reason,
            timestampMs = hit.timestamp,
            description = hit.description,
            manufacturer = manufacturer,
        )
    }
}
