package app.runsolo.record

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.util.Log
import app.runsolo.core.elevation.PressureReading

/**
 * The phone's barometer (`TYPE_PRESSURE`), if it has one. About 1 Hz with up to 1 s of report
 * latency: the hub may batch a little to save power, but never for longer than the join window
 * of `PressureJoin` (3 s), so every 1 Hz tick finds a reading and the source never alternates between
 * barometer and GPS ticks. Needs no
 * permission, and the readings never leave the phone: they go into the journal and become the
 * run file's elevation, nothing more.
 */
class PressureSource(context: Context) {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val sensor: Sensor? = manager?.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private var listener: SensorEventListener? = null

    val available: Boolean get() = sensor != null

    /** Starts delivering on [handler]'s thread; false when there is no barometer. */
    fun start(handler: Handler, onReading: (PressureReading) -> Unit): Boolean {
        val m = manager ?: return false
        val s = sensor ?: return false
        val l = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (event.values.isEmpty()) return
                // The event timestamp is elapsedRealtimeNanos, the same base as a fix's time.
                onReading(PressureReading(event.timestamp / 1_000_000L, event.values[0].toDouble()))
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        listener = l
        return try {
            m.registerListener(l, s, SAMPLING_PERIOD_US, MAX_REPORT_LATENCY_US, handler)
        } catch (e: Exception) {
            Log.w(TAG, "pressure sensor start failed: $e")
            listener = null
            false
        }
    }

    fun stop() {
        listener?.let { manager?.unregisterListener(it) }
        listener = null
    }

    private companion object {
        const val TAG = "PressureSource"
        const val SAMPLING_PERIOD_US = 1_000_000
        const val MAX_REPORT_LATENCY_US = 1_000_000
    }
}
