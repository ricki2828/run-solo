package app.runsolo.platform

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.Locale
import java.util.concurrent.Executors

/**
 * A short place name for a run's start point from the phone's own
 * [Geocoder]. The app makes no request itself; the system geocoder may ask
 * Google Play services (said in the privacy policy). Any failure, an absent
 * geocoder, or an answer with no usable name resolves null, never a
 * coordinate.
 */
class PlaceApiImpl(private val context: Context) : PlaceApi {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun placeName(lat: Double, lon: Double, callback: (Result<String?>) -> Unit) {
        // The Result must come back on the platform thread, whatever the geocoder does.
        fun reply(name: String?) {
            main.post { callback(Result.success(name)) }
        }
        if (!Geocoder.isPresent()) {
            reply(null)
            return
        }
        try {
            val geocoder = Geocoder(context, Locale.getDefault())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                geocoder.getFromLocation(lat, lon, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) {
                        reply(nameOf(addresses.firstOrNull()))
                    }
                    override fun onError(errorMessage: String?) {
                        reply(null)
                    }
                })
            } else {
                worker.execute {
                    val name = try {
                        @Suppress("DEPRECATION")
                        nameOf(geocoder.getFromLocation(lat, lon, 1)?.firstOrNull())
                    } catch (e: Exception) {
                        null
                    }
                    reply(name)
                }
            }
        } catch (e: Exception) {
            reply(null)
        }
    }

    companion object {
        /** Sub-locality (a suburb) first, then locality (a town); blank and numeric answers are no name. */
        fun nameOf(address: Address?): String? {
            if (address == null) return null
            return listOf(address.subLocality, address.locality)
                .mapNotNull { it?.trim() }
                .firstOrNull { it.isNotEmpty() && it.any { c -> c.isLetter() } }
        }
    }
}
