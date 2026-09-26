package app.runsolo

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import app.runsolo.platform.BleApi
import app.runsolo.platform.BleApiImpl
import app.runsolo.platform.PermissionKind
import app.runsolo.platform.PermissionStatus
import app.runsolo.platform.PermissionsApi
import app.runsolo.platform.RecordMode
import app.runsolo.platform.RecorderApi
import app.runsolo.platform.RecorderApiImpl
import app.runsolo.platform.RecorderEventBus
import app.runsolo.platform.RecorderEventsStreamHandler
import app.runsolo.platform.EventTraceName
import app.runsolo.platform.LapSource
import app.runsolo.platform.ReplayConfig
import app.runsolo.platform.StorageApi
import app.runsolo.platform.StorageApiImpl
import app.runsolo.platform.toPigeon
import app.runsolo.platform.Units
import app.runsolo.record.LapInput
import app.runsolo.record.LocationSource
import com.google.android.gms.common.api.ResolvableApiException
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.Priority
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var recorder: RecorderApiImpl
    private val permissionCallbacks = HashMap<Int, (Result<Boolean>) -> Unit>()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super.onCreate (plan §4): shows the Lap Line splash on API 29+ and swaps
        // LaunchTheme for NormalTheme; Flutter's first frame dismisses it.
        installSplashScreen()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Application context: the recorder outlives this Activity (swipe from Recents mid-run).
        recorder = RecorderApiImpl(applicationContext)
        RecorderApi.setUp(flutterEngine.dartExecutor.binaryMessenger, recorder)
        BleApi.setUp(flutterEngine.dartExecutor.binaryMessenger, BleApiImpl(applicationContext))
        PermissionsApi.setUp(flutterEngine.dartExecutor.binaryMessenger, Permissions())
        StorageApi.setUp(flutterEngine.dartExecutor.binaryMessenger, StorageApiImpl(applicationContext))
        RecorderEventsStreamHandler.register(flutterEngine.dartExecutor.binaryMessenger, RecorderEventBus)
        handleDebugIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDebugIntent(intent)
    }

    /**
     * Debug builds only (plan §12 replay mode + the CI lifecycle test). Extras:
     *  - `runsolo.replay=<fixture>` [`runsolo.speed=<x>`] [`runsolo.mode=intervals|laps|free`]: start a replay run now.
     *  - `runsolo.lapEveryMs=<n>`: press a notification LAP every n ms of wall time while recording
     *    (Laps mode; in Free mode the presses must be ignored and logged as `lapIgnored`).
     *  - `runsolo.recover=true`: run recover(); resume the newest readable orphan, else finalise it.
     *  - `runsolo.stopAfterMs=<n>`: stop the run after n ms (used after recover).
     * Everything is logged under the `RunSolo/debug` tag for the emulator script.
     */
    private fun handleDebugIntent(intent: Intent?) {
        if (!BuildConfig.REPLAY_ENABLED || intent == null || !::recorder.isInitialized) return
        val fixture = intent.getStringExtra("runsolo.replay")
        val recover = intent.getBooleanExtra("runsolo.recover", false)
        val stopAfter = intent.getLongExtra("runsolo.stopAfterMs", -1)
        val lapEvery = intent.getLongExtra("runsolo.lapEveryMs", -1)
        if (fixture == null && !recover && stopAfter < 0 && lapEvery < 0) return
        val main = Handler(Looper.getMainLooper())
        main.post {
            if (fixture != null) {
                val speed = intent.getFloatExtra("runsolo.speed", 10f).toDouble() // `am start --ef`
                val modeName = intent.getStringExtra("runsolo.mode") ?: "intervals"
                val mode = RecordMode.values().firstOrNull { EventTraceName.dart(it) == modeName } ?: RecordMode.INTERVALS
                // Intervals replays run the standard Norwegian 4x4 (the lifecycle test's timeline).
                val spec = if (mode == RecordMode.INTERVALS) app.runsolo.core.model.SessionSpec.norwegian4x4().toPigeon() else null
                val r = recorder.startReplay(mode, spec, Units.KM, ReplayConfig(fixture, speed))
                Log.i(DEBUG_TAG, "startReplay fixture=$fixture mode=${EventTraceName.dart(mode)} speed=$speed → runId=${r.runId} error=${r.error}")
            }
            if (lapEvery > 0) {
                val press = object : Runnable {
                    override fun run() {
                        val st = recorder.status()
                        if (st.state == app.runsolo.platform.RecorderState.IDLE) return
                        recorder.lap(LapSource.NOTIFICATION)
                        Log.i(DEBUG_TAG, "debug lap pressed at ${st.elapsedMs} ms (mode=${EventTraceName.dart(st.mode)})")
                        main.postDelayed(this, lapEvery)
                    }
                }
                main.postDelayed(press, lapEvery)
            }
            if (recover) {
                val orphans = recorder.recover()
                Log.i(DEBUG_TAG, "recover count=${orphans.size} ${orphans.joinToString { "${it.runId}(readable=${it.readable},age=${it.lastLineAgeMs},elapsed=${it.elapsedMs})" }}")
                val newest = orphans.firstOrNull { it.readable }
                if (newest != null) {
                    val diag = recorder.exitDiagnosis(newest.runId)
                    Log.i(DEBUG_TAG, "exitDiagnosis runId=${newest.runId} reason=${diag.reason} desc=${diag.description}")
                    val r = recorder.resumeRecovered(newest.runId)
                    Log.i(DEBUG_TAG, "resumeRecovered runId=${r.runId} error=${r.error}")
                }
                for (o in orphans.drop(if (newest != null) 1 else 0)) {
                    Log.i(DEBUG_TAG, "finalise runId=${o.runId} → ${recorder.finalise(o.runId)}")
                }
            }
            if (stopAfter >= 0) {
                main.postDelayed({
                    val id = recorder.stop()
                    Log.i(DEBUG_TAG, "stop → runId=$id files=${recorder.listRunFiles()}")
                }, stopAfter)
            }
        }
    }

    // ---- PermissionsApi (needs the Activity for prompts and result callbacks) ----

    inner class Permissions : PermissionsApi {
        private fun granted(p: String) = ContextCompat.checkSelfPermission(this@MainActivity, p) == PackageManager.PERMISSION_GRANTED

        override fun permissionStatus(): PermissionStatus {
            val fine = granted(Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = granted(Manifest.permission.ACCESS_COARSE_LOCATION)
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            val bluetooth = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                true
            }
            return PermissionStatus(
                fineLocation = fine,
                approximateOnly = coarse && !fine,
                locationEnabled = lm.isLocationEnabled,
                notifications = NotificationManagerCompat.from(this@MainActivity).areNotificationsEnabled(),
                bluetooth = bluetooth,
                batteryUnrestricted = pm.isIgnoringBatteryOptimizations(packageName),
                gmsAvailable = LocationSource.gmsAvailable(this@MainActivity),
            )
        }

        override fun requestPermission(kind: PermissionKind, callback: (Result<Boolean>) -> Unit) {
            when (kind) {
                PermissionKind.LOCATION -> {
                    if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
                        ensureLocationEnabled(callback)
                    } else {
                        ask(REQ_LOCATION, arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)) { r ->
                            if (r.getOrDefault(false)) ensureLocationEnabled(callback) else callback(r)
                        }
                    }
                }
                PermissionKind.NOTIFICATIONS -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        callback(Result.success(NotificationManagerCompat.from(this@MainActivity).areNotificationsEnabled()))
                    } else {
                        ask(REQ_NOTIFICATIONS, arrayOf(Manifest.permission.POST_NOTIFICATIONS), callback)
                    }
                }
                PermissionKind.BLUETOOTH -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        callback(Result.success(true))
                    } else {
                        ask(REQ_BLUETOOTH, arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT), callback)
                    }
                }
            }
        }

        override fun openBatterySettings() {
            // The one allowed Settings deep link (plan §10): the app's own battery page, never
            // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.
            val intents = listOf(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            )
            for (i in intents) {
                try {
                    startActivity(i)
                    return
                } catch (_: Exception) {
                }
            }
        }

        override fun openAppSettings() {
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
            }
        }

        override fun setKeepScreenOn(enabled: Boolean) {
            val w = window ?: return
            if (enabled) w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else w.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        override fun volumeKeyLapsSupported(): Boolean = LapInput.SUPPORTED
    }

    private fun ask(code: Int, permissions: Array<String>, callback: (Result<Boolean>) -> Unit) {
        if (permissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) {
            callback(Result.success(true))
            return
        }
        permissionCallbacks[code]?.invoke(Result.success(false))
        permissionCallbacks[code] = callback
        requestPermissions(permissions, code)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val cb = permissionCallbacks.remove(requestCode) ?: return
        val fineIndex = permissions.indexOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val ok = if (requestCode == REQ_LOCATION && fineIndex >= 0) {
            grantResults[fineIndex] == PackageManager.PERMISSION_GRANTED // approximate-only counts as not granted (W10)
        } else {
            grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        }
        cb(Result.success(ok))
    }

    /** System "turn on location" dialog via SettingsClient (allowed); resolves true when location is on. */
    private fun ensureLocationEnabled(callback: (Result<Boolean>) -> Unit) {
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        if (lm.isLocationEnabled) {
            callback(Result.success(true))
            return
        }
        if (!LocationSource.gmsAvailable(this)) {
            callback(Result.success(false))
            return
        }
        val req = LocationSettingsRequest.Builder()
            .addLocationRequest(LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L).build())
            .build()
        LocationServices.getSettingsClient(this).checkLocationSettings(req)
            .addOnSuccessListener { callback(Result.success(true)) }
            .addOnFailureListener { e ->
                if (e is ResolvableApiException) {
                    permissionCallbacks[REQ_LOCATION_SETTINGS]?.invoke(Result.success(false))
                    permissionCallbacks[REQ_LOCATION_SETTINGS] = callback
                    try {
                        e.startResolutionForResult(this, REQ_LOCATION_SETTINGS)
                    } catch (_: Exception) {
                        permissionCallbacks.remove(REQ_LOCATION_SETTINGS)
                        callback(Result.success(false))
                    }
                } else {
                    callback(Result.success(false))
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_LOCATION_SETTINGS) {
            val cb = permissionCallbacks.remove(REQ_LOCATION_SETTINGS) ?: return
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            cb(Result.success(lm.isLocationEnabled))
        }
    }

    companion object {
        private const val DEBUG_TAG = "RunSolo/debug"
        private const val REQ_LOCATION = 41
        private const val REQ_NOTIFICATIONS = 42
        private const val REQ_BLUETOOTH = 43
        private const val REQ_LOCATION_SETTINGS = 44
    }
}
