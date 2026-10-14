package app.runsolo.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import app.runsolo.core.ble.BleReconnectPolicy
import app.runsolo.core.ble.HeartRateMeasurement
import app.runsolo.core.model.HrReading
import java.util.UUID

/**
 * Heart Rate Profile client (plan §3, W7). Pairs by one filtered scan for 0x180D; after that
 * every connection is to the saved address (Android throttles scan starts and suppresses
 * unfiltered scans screen-off). One exception: a WHOOP broadcasts from a rotating random
 * private address, so the saved one can go stale. When a connect yields no measurement within
 * [FALLBACK_MS], [BleReconnectPolicy] may allow ONE filtered 0x180D scan per episode that
 * matches the saved device name and silently re-points the saved address. We deliberately do
 * not createBond: a broadcast-mode strap is not bondable, so it would only raise a pairing
 * prompt or fail, and a bond is the only way the OS could resolve a private address. At run start an existing link is kept, otherwise a
 * direct `connectGatt(autoConnect = false)`; after a drop `autoConnect = true` (passive, OS
 * managed). `gatt.close()` always precedes a reconnect (GATT 133 leak). "Connected" is reported
 * only once notifications are enabled (the CCCD write succeeded) AND the first measurement
 * has arrived — a link that never delivers is not a working strap; a failed discovery or CCCD
 * write is retried once, then the link is closed and reconnected, and a link that stays silent
 * for [SILENT_LINK_MS] after setup is treated the same way. Whoop broadcast is a
 * standard HR-profile peripheral; its contact bits are a Phase 1 device-test item.
 *
 * Readings go to [listener] with `t = elapsedRealtime` at receipt; a no-contact packet is
 * reported as [Listener.onNoContact]. All callbacks are marshalled to the main thread.
 */
class BleHrClient(context: Context) {
    interface Listener {
        fun onReading(reading: HrReading)
        fun onNoContact()
        fun onLink(connected: Boolean)
    }

    private val context = context.applicationContext
    private val prefs = this.context.getSharedPreferences("runsolo.ble", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val manager = this.context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager // null without Bluetooth
    private val adapter: BluetoothAdapter? get() = manager?.adapter
    private val policy = BleReconnectPolicy(prefs.getString(KEY_ADDRESS, null), prefs.getString(KEY_NAME, null))
    private var gatt: BluetoothGatt? = null
    private var pendingReconnect: Runnable? = null
    private var setupRetried = false
    private var notificationsOn = false
    private var silentWatchdog: Runnable? = null
    private var fallbackTimer: Runnable? = null
    private var nameScanCb: ScanCallback? = null
    private val seenNames = HashMap<String, String>() // address -> name from the last pairing scan, capped at MAX_SEEN_NAMES
    var listener: Listener? = null

    /** Notifications enabled AND at least one measurement received (not merely a GATT link). */
    var connected: Boolean = false
        private set
    var lastHr: Int? = null
        private set
    var deviceName: String? = prefs.getString(KEY_NAME, null)
        private set
    val savedAddress: String? get() = policy.savedAddress
    /** Paired but the strap was not seen: the UI hint is "start the broadcast, then scan again". */
    val notFound: Boolean get() = policy.state == BleReconnectPolicy.LinkState.NOT_FOUND
    val adapterOn: Boolean get() = adapter?.isEnabled == true

    fun hasPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_CONNECT)
        }
        // API 29-30: legacy BLUETOOTH/BLUETOOTH_ADMIN are install-time; scanning needs fine location.
        return granted(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    // ---- pairing ----

    data class Found(val address: String, val name: String?)

    /** One filtered scan for HR peripherals, ≤ [timeoutMs]; results de-duplicated by address. */
    @SuppressLint("MissingPermission")
    fun scan(timeoutMs: Long = 10_000, done: (Result<List<Found>>) -> Unit) {
        val a = adapter
        if (a == null || !a.isEnabled) {
            done(Result.failure(IllegalStateException("bluetooth off")))
            return
        }
        if (!hasPermissions()) {
            done(Result.failure(SecurityException("bluetooth permission missing")))
            return
        }
        val scanner = a.bluetoothLeScanner
        if (scanner == null) {
            done(Result.failure(IllegalStateException("no LE scanner")))
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (!policy.canStartScan(now)) {
            Log.w(TAG, "scan refused: start budget spent")
            done(Result.failure(app.runsolo.platform.FlutterError("scan_budget", "scan start budget spent")))
            return
        }
        val found = LinkedHashMap<String, Found>()
        policy.noteScanStart(now)
        var finished = false
        lateinit var cb: ScanCallback
        val finish = {
            if (!finished) {
                finished = true
                try {
                    scanner.stopScan(cb)
                } catch (_: Exception) {
                }
                done(Result.success(found.values.toList()))
            }
        }
        cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val d = result.device ?: return
                val name = result.scanRecord?.deviceName ?: safeName(d)
                found[d.address] = Found(d.address, name)
                if (name != null) {
                    if (seenNames.size >= MAX_SEEN_NAMES) seenNames.clear()
                    seenNames[d.address] = name
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "scan failed $errorCode")
                main.post { finish() }
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(HR_SERVICE)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(filters, settings, cb)
        } catch (e: Exception) {
            done(Result.failure(e))
            return
        }
        main.postDelayed({ finish() }, timeoutMs)
    }

    fun pair(address: String) {
        prefs.edit().putString(KEY_ADDRESS, address).apply()
        // The scan's name wins: the OS only knows a remote name it has cached, often none for a broadcast strap.
        val name = seenNames[address] ?: try {
            adapter?.getRemoteDevice(address)?.let { safeName(it) }
        } catch (_: Exception) {
            null
        }
        deviceName = name
        prefs.edit().putString(KEY_NAME, name).apply()
        Log.i(TAG, "paired addressType=${addressType(address)} hasName=${name != null}")
        apply(policy.pair(address, name))
    }

    fun forget() {
        prefs.edit().remove(KEY_ADDRESS).remove(KEY_NAME).apply()
        deviceName = null
        cancelReconnect()
        cancelFallback()
        stopNameScan()
        closeGatt()
        apply(policy.forget())
        setConnected(false)
    }

    // ---- link ----

    /** Recording starts: keep a working link, otherwise connect directly to the saved strap. */
    fun connectIfPaired() {
        if (connected && gatt != null) {
            listener?.onLink(true)
            return
        }
        apply(policy.onStart())
    }

    fun disconnect() {
        cancelReconnect()
        cancelFallback()
        stopNameScan()
        closeGatt()
        setConnected(false)
    }

    private fun apply(action: BleReconnectPolicy.Action) {
        when (action) {
            is BleReconnectPolicy.Action.Nothing -> Unit
            is BleReconnectPolicy.Action.Reconnect -> {
                cancelReconnect()
                val r = Runnable {
                    pendingReconnect = null
                    if (action.closeFirst) closeGatt()
                    connect(action.address, action.autoConnect)
                }
                pendingReconnect = r
                main.postDelayed(r, action.delayMs)
            }
            is BleReconnectPolicy.Action.ScanForName -> startNameScan(action)
        }
    }

    private fun cancelReconnect() {
        pendingReconnect?.let { main.removeCallbacks(it) }
        pendingReconnect = null
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, autoConnect: Boolean) {
        val a = adapter
        if (a == null || !a.isEnabled || !hasPermissions()) {
            apply(policy.onConnectFailed(SystemClock.elapsedRealtime()))
            return
        }
        val device: BluetoothDevice = try {
            a.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            return
        }
        Log.i(TAG, "connectGatt autoConnect=$autoConnect addressType=${addressType(address)}")
        setupRetried = false
        // Only a direct connect is expected to produce a measurement within seconds; a passive autoConnect after a drop can legitimately take a minute.
        if (!autoConnect) armFallback() else cancelFallback()
        gatt = try {
            device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            Log.w(TAG, "connectGatt threw: $e")
            null
        }
        if (gatt == null) apply(policy.onConnectFailed(SystemClock.elapsedRealtime()))
    }

    /** No measurement [FALLBACK_MS] after a connect attempt: ask the policy whether a name scan is allowed. */
    private fun armFallback() {
        cancelFallback()
        val r = Runnable {
            fallbackTimer = null
            if (connected) return@Runnable
            val action = policy.onNoMeasurement(SystemClock.elapsedRealtime())
            Log.i(TAG, "no measurement after ${FALLBACK_MS}ms; fallback=${policy.lastFallback}")
            if (action is BleReconnectPolicy.Action.ScanForName) startNameScan(action)
            if (policy.state == BleReconnectPolicy.LinkState.NOT_FOUND) listener?.onLink(false)
        }
        fallbackTimer = r
        main.postDelayed(r, FALLBACK_MS)
    }

    private fun cancelFallback() {
        fallbackTimer?.let { main.removeCallbacks(it) }
        fallbackTimer = null
    }

    /** One filtered scan for the saved name (the start was already budgeted by the policy). */
    @SuppressLint("MissingPermission")
    private fun startNameScan(action: BleReconnectPolicy.Action.ScanForName) {
        val scanner = adapter?.takeIf { it.isEnabled && hasPermissions() }?.bluetoothLeScanner
        if (scanner == null) {
            finishNameScan(emptyList())
            return
        }
        val found = LinkedHashMap<String, BleReconnectPolicy.Candidate>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val d = result.device ?: return
                val name = result.scanRecord?.deviceName ?: safeName(d)
                found[d.address] = BleReconnectPolicy.Candidate(d.address, name, result.rssi)
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "name scan failed $errorCode")
                main.post {
                    if (nameScanCb === this) {
                        stopNameScan()
                        finishNameScan(found.values.toList())
                    }
                }
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(HR_SERVICE)).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        try {
            scanner.startScan(filters, settings, cb)
        } catch (e: Exception) {
            Log.w(TAG, "name scan start threw: $e")
            finishNameScan(emptyList())
            return
        }
        nameScanCb = cb
        main.postDelayed({
            if (nameScanCb !== cb) return@postDelayed // cancelled
            stopNameScan()
            finishNameScan(found.values.toList())
        }, action.timeoutMs)
    }

    @SuppressLint("MissingPermission")
    private fun stopNameScan() {
        val cb = nameScanCb ?: return
        nameScanCb = null
        try {
            adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Exception) {
        }
    }

    private fun finishNameScan(found: List<BleReconnectPolicy.Candidate>) {
        val before = policy.savedAddress
        if (connected) return // the link came up while the scan ran
        val action = policy.onScanResult(found, SystemClock.elapsedRealtime())
        if (action is BleReconnectPolicy.Action.Reconnect) {
            Log.i(TAG, "name scan matched; address ${if (action.address == before) "unchanged" else "updated"} type=${addressType(action.address)}")
            prefs.edit().putString(KEY_ADDRESS, action.address).apply()
            apply(action)
        } else {
            Log.i(TAG, "name scan found no match among ${found.size} HR device(s); strap stays paired")
            listener?.onLink(false)
        }
    }

    /** Top two address bits (meaningful only if the address is random; a public one looks random): 11 static, 01 resolvable private, 00 non-resolvable private. */
    private fun addressType(address: String): String {
        val first = address.substringBefore(':').toIntOrNull(16) ?: return "unknown"
        return when (first ushr 6) {
            3 -> "msb11-static-random"
            1 -> "msb01-resolvable-private"
            0 -> "msb00-nonresolvable-private-or-public"
            else -> "unknown"
        }
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt() {
        gatt?.let {
            try {
                it.disconnect()
            } catch (_: Exception) {
            }
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        gatt = null
    }

    private fun setConnected(v: Boolean) {
        if (!v) {
            notificationsOn = false
            cancelWatchdog()
        } else {
            cancelFallback()
            stopNameScan() // a late scan result must not tear down the working link
        }
        if (connected == v) return
        connected = v
        if (!v) lastHr = null
        listener?.onLink(v)
    }

    private fun cancelWatchdog() {
        silentWatchdog?.let { main.removeCallbacks(it) }
        silentWatchdog = null
    }

    /** Notifications are on but nothing arrived: drop and reconnect rather than sit "connected" with no HR. */
    private fun armWatchdog(g: BluetoothGatt) {
        cancelWatchdog()
        val r = Runnable {
            silentWatchdog = null
            if (g === gatt && !connected) setupFailed(g, "silent link")
        }
        silentWatchdog = r
        main.postDelayed(r, SILENT_LINK_MS)
    }

    /** Discovery or CCCD failed: retry once, then treat as a drop (close + reconnect). */
    @SuppressLint("MissingPermission")
    private fun setupFailed(g: BluetoothGatt, what: String) {
        if (g !== gatt) return
        Log.w(TAG, "$what failed")
        if (!setupRetried) {
            setupRetried = true
            main.postDelayed({ if (g === gatt) g.discoverServices() }, 500)
        } else {
            closeGatt()
            setConnected(false)
            apply(policy.onDisconnected(SystemClock.elapsedRealtime()))
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableNotifications(g: BluetoothGatt): Boolean {
        val ch = g.getService(HR_SERVICE)?.getCharacteristic(HR_MEASUREMENT) ?: return false
        if (!g.setCharacteristicNotification(ch, true)) return false
        val cccd = ch.getDescriptor(CCCD) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            g.writeDescriptor(cccd)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (g !== gatt) { // stale callback from a closed gatt
                    try {
                        g.close()
                    } catch (_: Exception) {
                    }
                    return@post
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.i(TAG, "link up, discovering")
                    if (!g.discoverServices()) setupFailed(g, "discoverServices")
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    Log.i(TAG, "disconnected status=$status")
                    setConnected(false)
                    listener?.onNoContact()
                    apply(policy.onDisconnected(SystemClock.elapsedRealtime()))
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post {
                if (g !== gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS || !enableNotifications(g)) setupFailed(g, "services/cccd")
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (g !== gatt || descriptor.uuid != CCCD) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    notificationsOn = true
                    armWatchdog(g)
                    Log.i(TAG, "HR notifications on; waiting for the first measurement")
                } else {
                    setupFailed(g, "cccd write status=$status")
                }
            }
        }

        // API 33+ delivers the value; older delivers the characteristic.
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            deliver(g, ch.uuid, value)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                val v = ch.value ?: return
                deliver(g, ch.uuid, v)
            }
        }
    }

    private fun deliver(g: BluetoothGatt, uuid: UUID, value: ByteArray) {
        if (uuid != HR_MEASUREMENT) return
        val parsed = HeartRateMeasurement.parse(value) ?: return
        val t = SystemClock.elapsedRealtime()
        main.post {
            if (g !== gatt) return@post
            if (notificationsOn && !connected) {
                cancelWatchdog()
                policy.onConnected(SystemClock.elapsedRealtime())
                setConnected(true)
                Log.i(TAG, "first measurement received; strap connected")
            }
            val bpm = parsed.bpm
            lastHr = bpm
            if (bpm == null) listener?.onNoContact() else listener?.onReading(HrReading(t, bpm))
        }
    }

    @SuppressLint("MissingPermission")
    private fun safeName(d: BluetoothDevice): String? = try {
        d.name
    } catch (_: SecurityException) {
        null
    }

    companion object {
        private const val TAG = "RunSolo/ble"
        private const val KEY_ADDRESS = "address"
        private const val KEY_NAME = "name"
        private const val MAX_SEEN_NAMES = 32
        private const val SILENT_LINK_MS = 15_000L
        private const val FALLBACK_MS = 12_000L
        val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HR_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
