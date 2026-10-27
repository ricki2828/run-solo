package app.runsolo

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Native half of Settings → About → Share diagnostics. Uncaught exceptions are appended to
 * `files/diagnostics/native-crash.log` (the Dart `DiagnosticsLog` reads the same directory),
 * capped at [MAX_BYTES] with the older half dropped. Nothing leaves the phone from here.
 */
object DiagnosticsFiles {
    const val DIR = "diagnostics"
    const val CRASH_FILE = "native-crash.log"
    const val MAX_BYTES = 128 * 1024L
    private const val RUNS_PREFS = "runsolo.runs"

    fun crashFile(context: Context): File = File(File(context.filesDir, DIR), CRASH_FILE)

    /** Append one crash entry. Never throws: the handler is already running because something failed. */
    fun appendCrash(context: Context, thread: String, error: Throwable, version: String, wallMs: Long) {
        try {
            val file = crashFile(context)
            file.parentFile?.mkdirs()
            if (file.length() > MAX_BYTES) {
                val keep = file.readLines().let { it.drop(it.size / 2) }
                file.writeText(keep.joinToString("\n", postfix = "\n"))
            }
            val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(Date(wallMs))
            file.appendText("--- $stamp native thread=$thread app=$version\n${error.stackTraceToString()}\n")
        } catch (_: Exception) {
        }
    }

    /** Installs once; chains to whatever handler was there (the platform's kill-and-report path). */
    fun installCrashHandler(context: Context, version: String) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Chained) return
        Thread.setDefaultUncaughtExceptionHandler(Chained(previous) { thread, error ->
            appendCrash(app, thread.name, error, version, System.currentTimeMillis())
        })
    }

    internal class Chained(
        private val next: Thread.UncaughtExceptionHandler?,
        private val record: (Thread, Throwable) -> Unit,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            record(thread, error)
            next?.uncaughtException(thread, error)
        }
    }

    /** The cached OS-exit verdicts (`ExitDiagnostics` prefs, `diag.<run>`), one line each. */
    fun exitTail(context: Context): String {
        val prefs = context.getSharedPreferences(RUNS_PREFS, Context.MODE_PRIVATE)
        val lines = prefs.all.filterKeys { it.startsWith("diag.") }.mapNotNull { (k, v) ->
            val parts = (v as? String)?.split("\u0001") ?: return@mapNotNull null
            if (parts.size < 3) return@mapNotNull null
            // Run ids are random uuids; keep only a short prefix.
            "${k.removePrefix("diag.").take(8)} reason=${parts[0]} at=${parts[1]} maker=${parts[2]} ${parts.getOrElse(3) { "" }}"
        }
        return if (lines.isEmpty()) "(none)" else lines.joinToString("\n")
    }
}
