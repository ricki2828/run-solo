package app.runsolo.record

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import android.util.Log
import app.runsolo.core.model.LocationFix
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority

/** 1 Hz fixes for the recorder (plan §3). Every fix is stamped from `elapsedRealtimeNanos`. */
interface LocationSource {
    fun start(onFix: (LocationFix) -> Unit)
    fun stop()

    companion object {
        const val TAG = "RunSolo/location"

        fun toFix(l: Location): LocationFix = LocationFix(
            t = l.elapsedRealtimeNanos / 1_000_000,
            lat = l.latitude,
            lon = l.longitude,
            altM = if (l.hasAltitude()) l.altitude else null,
            // No accuracy reported → treat as unusable; the filter rejects it, the sample is still journaled.
            accuracyM = if (l.hasAccuracy()) l.accuracy.toDouble() else 9999.0,
            speedMps = if (l.hasSpeed()) l.speed.toDouble() else null,
        )

        fun gmsAvailable(context: Context): Boolean =
            GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

        /** FLP when GMS is present, raw GPS_PROVIDER otherwise or when the user opted for raw GPS. */
        fun create(context: Context, preferRawGps: Boolean): LocationSource =
            if (!preferRawGps && gmsAvailable(context)) FusedLocationSource(context) else GpsProviderSource(context)
    }
}

/** FusedLocationProvider, PRIORITY_HIGH_ACCURACY at 1000 ms / 0 m. */
class FusedLocationSource(context: Context) : LocationSource {
    private val client = LocationServices.getFusedLocationProviderClient(context)
    private var callback: LocationCallback? = null

    @SuppressLint("MissingPermission") // the service checks fine location before starting
    override fun start(onFix: (LocationFix) -> Unit) {
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateDistanceMeters(0f)
            .setMinUpdateIntervalMillis(1000L)
            .setWaitForAccurateLocation(false)
            .build()
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                for (l in result.locations) onFix(LocationSource.toFix(l))
            }
        }
        callback = cb
        client.requestLocationUpdates(request, cb, Looper.getMainLooper())
        Log.i(LocationSource.TAG, "fused updates started")
    }

    override fun stop() {
        callback?.let { client.removeLocationUpdates(it) }
        callback = null
    }
}

/** Raw GPS_PROVIDER at 1 s / 0 m (no GMS, or the settings toggle). */
class GpsProviderSource(context: Context) : LocationSource {
    private val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private var listener: LocationListener? = null

    @SuppressLint("MissingPermission")
    override fun start(onFix: (LocationFix) -> Unit) {
        val l = LocationListener { location -> onFix(LocationSource.toFix(location)) }
        listener = l
        manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000L, 0f, l, Looper.getMainLooper())
        Log.i(LocationSource.TAG, "GPS_PROVIDER updates started")
    }

    override fun stop() {
        listener?.let { manager.removeUpdates(it) }
        listener = null
    }
}
