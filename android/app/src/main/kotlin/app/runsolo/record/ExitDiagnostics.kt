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
 * Entries are pruned when the run is stopped — so the verdict is CACHED per run the moment
 * `recover()` sees the orphan ([cacheForRecovery]): run detail asks [diagnose] long after
 * the run was finalised. The cache is bounded ([MAX_CACHED], oldest evicted).
 */
object ExitDiagnostics {
    private const val PREFS = "runsolo.runs"
    private const val MAX_CACHED = 64

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

    /**
     * Called by `recover()` for every orphan: diagnose the kill that produced it and keep the
     * answer under `diag.<id>` so it survives `noteStopped` and a later resume. Only a real
     * kill is cached (a `none` now may become a kill once the OS records it).
     */
    fun cacheForRecovery(context: Context, runId: String) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains("diag.$runId")) return
        val d = diagnoseLive(context, runId)
        if (d.reason == ExitReason.NONE) return
        cache(context, d)
    }

    /** Persist a diagnosis (also used by tests); evicts the oldest cached entries past [MAX_CACHED]. */
    fun cache(context: Context, d: ExitDiagnosis) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit().putString("diag.${d.runId}", encode(d))
        val cached = prefs.all.keys.filter { it.startsWith("diag.") }
        if (cached.size >= MAX_CACHED) {
            val byTime = cached.sortedBy { k -> decode(k.removePrefix("diag."), prefs.getString(k, null))?.timestampMs ?: 0L }
            for (k in byTime.take(cached.size - MAX_CACHED + 1)) editor.remove(k)
        }
        editor.apply()
    }

    /** The cached verdict when there is one, else a live look-up (only meaningful before `noteStopped`). */
    fun diagnose(context: Context, runId: String): ExitDiagnosis {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        decode(runId, prefs.getString("diag.$runId", null))?.let { return it }
        return diagnoseLive(context, runId)
    }

    private fun encode(d: ExitDiagnosis): String =
        listOf(d.reason.name, d.timestampMs.toString(), d.manufacturer, d.description ?: "").joinToString("\u0001")

    private fun decode(runId: String, text: String?): ExitDiagnosis? {
        val parts = text?.split("\u0001") ?: return null
        if (parts.size < 4) return null
        val reason = ExitReason.values().firstOrNull { it.name == parts[0] } ?: return null
        return ExitDiagnosis(runId = runId, reason = reason, timestampMs = parts[1].toLongOrNull() ?: 0L, description = parts[3].ifEmpty { null }, manufacturer = parts[2])
    }

    private fun diagnoseLive(context: Context, runId: String): ExitDiagnosis {
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
