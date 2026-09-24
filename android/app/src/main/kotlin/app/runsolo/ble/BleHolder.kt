package app.runsolo.ble

import android.content.Context

/** One [BleHrClient] per process: pairing happens outside a run, the session borrows it during one. */
object BleHolder {
    private var client: BleHrClient? = null

    fun client(context: Context): BleHrClient =
        client ?: BleHrClient(context.applicationContext).also { client = it }
}
