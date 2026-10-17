package app.runsolo.ble

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Rolling strap diagnostics: every link decision [BleHrClient] makes, one line each with wall
 * time and elapsed-realtime, in `files/ble-trail.log` (also logged under `RunSolo/ble`). Capped
 * at [MAX_BYTES]: past that the older half is dropped. Addresses appear only as their last two
 * octets. Main thread only; a write failure is ignored (diagnostics never break the strap).
 */
class BleTrail(context: Context) {
    private val file = File(context.filesDir, FILE)
    private val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)

    fun note(event: String) {
        val line = "${fmt.format(Date())} +${SystemClock.elapsedRealtime()} $event"
        Log.i(TAG, line)
        try {
            if (file.length() > MAX_BYTES) {
                val keep = file.readLines().let { it.drop(it.size / 2) }
                file.writeText(keep.joinToString("\n", postfix = "\n"))
            }
            file.appendText(line + "\n")
        } catch (_: Exception) {
        }
    }

    companion object {
        const val FILE = "ble-trail.log"
        private const val TAG = "RunSolo/ble"
        private const val MAX_BYTES = 128 * 1024L
    }
}
