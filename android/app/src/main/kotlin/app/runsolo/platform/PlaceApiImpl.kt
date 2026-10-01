package app.runsolo.platform

import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * A short place name for a run's start point from the phone's own
 * [Geocoder]. The app makes no request itself; the system geocoder may ask
 * Google Play services (said in the privacy policy). Any failure, an absent
 * geocoder, a timeout, or an answer with no usable name resolves null, never
 * a coordinate. Each lookup completes exactly once and never waits longer
 * than [TIMEOUT_MS], whatever the geocoder does.
 */
class PlaceApiImpl(private val context: Context) : PlaceApi {
    private val main = Handler(Looper.getMainLooper())

    // One thread per lookup: a hung blocking call (API 32 and below) must not stall the next one.
    private val workers = Executors.newCachedThreadPool { r -> Thread(r, "place-lookup").apply { isDaemon = true } }

    override fun placeName(lat: Double, lon: Double, callback: (Result<String?>) -> Unit) {
        val done = AtomicBoolean(false)
        // The Result must come back once, on the platform thread.
        fun reply(name: String?) {
            if (done.compareAndSet(false, true)) {
                main.post { callback(Result.success(name)) }
            }
        }
        main.postDelayed({ reply(null) }, TIMEOUT_MS)
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
                workers.execute {
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
        const val TIMEOUT_MS = 10_000L

        /** Sub-locality (a suburb) first, then locality (a town); blank and numeric answers are no name. */
        fun nameOf(address: Address?): String? {
            if (address == null) return null
            return listOf(address.subLocality, address.locality)
                .mapNotNull { it?.trim() }
                .firstOrNull { it.isNotEmpty() && it.any { c -> c.isLetter() } }
        }
    }
}
