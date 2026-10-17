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
 * Heart Rate Profile client (plan §3, W7). Pairs by one filtered scan for 0x180D; every later
 * connection is decided by [BleReconnectPolicy], scan-first: a WHOOP in "Broadcast Heart Rate"
 * advertises from a rotating private address and is not bondable (so we never createBond, and
 * the OS cannot resolve the address for us), which leaves the address saved at pairing stale.
 * So, apart from pairing, the strap is found by a hunt — one long filtered 0x180D scan plus a
 * passive `autoConnect` to the saved address for straps with a fixed one — and connected
 * directly (`autoConnect = false`) at the address the scan just saw, using the scan's own
 * [BluetoothDevice] so the stack keeps its random address type. The saved address (and name)
 * follow the strap.
 *
 * The strap is wanted while the Start/Ready GPS probe runs ([OWNER_START]) and while a run
 * records ([OWNER_RUN]); when nobody wants it any more the client lets go after [LINGER_MS] (so
 * Ready → GO keeps the warm link). `gatt.close()` always precedes a new connect (GATT 133 leak).
 * "Connected" is reported only once notifications are enabled (the CCCD write succeeded) AND
 * the first measurement has arrived; a connect with no measurement within [CONNECT_WINDOW_MS],
 * a failed discovery or CCCD write (retried once), or a link silent for [SILENT_LINK_MS] after
 * setup all go back to a hunt. Every transition is written to [BleTrail] so a failure on a real
 * phone can be explained afterwards.
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
    private val trail = BleTrail(this.context)
    private var gatt: BluetoothGatt? = null
    private var pending: Runnable? = null
    private var setupRetried = false
    private var notificationsOn = false
    private var silentWatchdog: Runnable? = null
    private var connectWindow: Runnable? = null
    private var huntCb: ScanCallback? = null
    private var huntEnd: Runnable? = null
    private var huntTick: Runnable? = null
    private val huntDevices = HashMap<String, BluetoothDevice>() // this hunt's scan results, connected by object (keeps the address type)
    private val owners = HashSet<String>()
    private var linger: Runnable? = null
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
    val adapterOn: Boolean get() = adapter?.isEnabled == true

    fun hasPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_CONNECT)
        }
        // API 29-30: legacy BLUETOOTH/BLUETOOTH_ADMIN are install-time; scanning needs fine location.
        return granted(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    private fun now() = SystemClock.elapsedRealtime()

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
        trail.note("pair ${addr(address)} name=${name ?: "-"}")
        // Pairing holds the strap for a while (the pairing screen shows its HR) even outside Start/Ready.
        want(OWNER_PAIR, start = false)
        main.postDelayed({ release(OWNER_PAIR) }, PAIR_HOLD_MS)
        apply(policy.pair(address, name))
    }

    fun forget() {
        prefs.edit().remove(KEY_ADDRESS).remove(KEY_NAME).apply()
        deviceName = null
        trail.note("forget")
        shutdown()
        apply(policy.forget())
    }

    // ---- link ----

    /** Recording starts: keep a working link, otherwise hunt for the saved strap. Any thread. */
    fun connectIfPaired() = main.post { want(OWNER_RUN) }

    /** Recording stopped: let go of the strap unless the Start/Ready screen still wants it. Any thread. */
    fun disconnect() = main.post { release(OWNER_RUN) }

    /** The Start/Ready GPS probe started (main thread): connect the saved strap before GO. */
    fun startScreenWants() = want(OWNER_START)

    /** The Start/Ready GPS probe stopped (main thread). */
    fun startScreenReleases() = release(OWNER_START)

    private fun want(owner: String, start: Boolean = true) {
        linger?.let { main.removeCallbacks(it) }
        linger = null
        if (owners.add(owner)) trail.note("want $owner owners=$owners state=${policy.state}")
        if (connected && gatt != null) listener?.onLink(true)
        if (start) apply(policy.onStart(now()))
    }

    private fun release(owner: String) {
        if (!owners.remove(owner)) return
        trail.note("release $owner owners=$owners")
        if (owners.isNotEmpty() || linger != null) return
        val r = Runnable {
            linger = null
            if (owners.isEmpty()) {
                trail.note("idle: letting go of the strap")
                shutdown()
            }
        }
        linger = r
        main.postDelayed(r, LINGER_MS)
    }

    /** Close everything; nothing connects again until someone wants the strap. */
    private fun shutdown() {
        cancelPending()
        cancelConnectWindow()
        stopHunt()
        closeGatt()
        policy.stop()
        setConnected(false)
    }

    private fun apply(action: BleReconnectPolicy.Action) {
        when (action) {
            is BleReconnectPolicy.Action.Nothing -> Unit
            is BleReconnectPolicy.Action.Connect -> {
                persistIdentity()
                schedule(action.delayMs) {
                    stopHunt()
                    closeGatt()
                    connect(action.address, autoConnect = false)
                }
            }
            is BleReconnectPolicy.Action.Hunt -> {
                stopHunt()
                closeGatt()
                cancelConnectWindow()
                if (action.delayMs > 0) trail.note("hunt in ${action.delayMs}ms")
                schedule(action.delayMs) { startHunt(action) }
            }
        }
    }

    private fun schedule(delayMs: Long, block: () -> Unit) {
        cancelPending()
        val r = Runnable {
            pending = null
            block()
        }
        pending = r
        main.postDelayed(r, delayMs)
    }

    private fun cancelPending() {
        pending?.let { main.removeCallbacks(it) }
        pending = null
    }

    /** The policy re-points the saved address to the strap a scan found by address or name. */
    private fun persistIdentity() {
        val a = policy.savedAddress
        val n = policy.savedName
        if (a != prefs.getString(KEY_ADDRESS, null) || n != prefs.getString(KEY_NAME, null)) {
            prefs.edit().putString(KEY_ADDRESS, a).putString(KEY_NAME, n).apply()
            deviceName = n
            trail.note("saved strap re-pointed to ${a?.let { addr(it) }} name=${n ?: "-"} match=${policy.lastMatch}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String, autoConnect: Boolean) {
        val a = adapter
        if (a == null || !a.isEnabled || !hasPermissions()) {
            trail.note("connect skipped: adapter=${a?.isEnabled} perms=${hasPermissions()}")
            if (!autoConnect) apply(policy.onConnectFailed(now()))
            return
        }
        val device: BluetoothDevice = huntDevices[address] ?: try {
            a.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            if (!autoConnect) apply(policy.onConnectFailed(now()))
            return
        }
        Log.i(TAG, "connectGatt autoConnect=$autoConnect addressType=${addressType(address)}")
        trail.note("connectGatt ${addr(address)} auto=$autoConnect fromScan=${huntDevices.containsKey(address)}")
        setupRetried = false
        // A direct connect goes to an address a scan (or pairing) just saw: it must deliver within seconds.
        if (!autoConnect) armConnectWindow()
        gatt = try {
            device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            Log.w(TAG, "connectGatt threw: $e")
            null
        }
        if (gatt == null) {
            trail.note("connectGatt returned null")
            if (!autoConnect) {
                cancelConnectWindow()
                apply(policy.onConnectFailed(now()))
            }
        }
    }

    /** No first measurement [CONNECT_WINDOW_MS] after a direct connect (or a passive link coming up): hunt again. */
    private fun armConnectWindow() {
        cancelConnectWindow()
        val r = Runnable {
            connectWindow = null
            if (connected) return@Runnable
            trail.note("no measurement within ${CONNECT_WINDOW_MS}ms; state=${policy.state}")
            closeGatt()
            setConnected(false)
            apply(policy.onConnectFailed(now()))
        }
        connectWindow = r
        main.postDelayed(r, CONNECT_WINDOW_MS)
    }

    private fun cancelConnectWindow() {
        connectWindow?.let { main.removeCallbacks(it) }
        connectWindow = null
    }

    /** One filtered 0x180D scan of up to [h].scanMs plus a passive connect to the saved address. */
    @SuppressLint("MissingPermission")
    private fun startHunt(h: BleReconnectPolicy.Action.Hunt) {
        val a = adapter
        val scanner = a?.takeIf { it.isEnabled && hasPermissions() }?.bluetoothLeScanner
        if (scanner == null) {
            trail.note("hunt cannot scan: adapter=${a?.isEnabled} perms=${hasPermissions()}")
            apply(policy.onScanEnded(now(), failed = true))
            return
        }
        huntDevices.clear()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val d = result.device ?: return
                val name = result.scanRecord?.deviceName ?: safeName(d)
                val rssi = result.rssi
                main.post {
                    if (huntCb !== this) return@post
                    if (!huntDevices.containsKey(d.address)) trail.note("hunt saw ${addr(d.address)} name=${name ?: "-"} rssi=$rssi")
                    huntDevices[d.address] = d
                    val action = policy.onScanResult(BleReconnectPolicy.Candidate(d.address, name, rssi), now())
                    if (action is BleReconnectPolicy.Action.Connect) trail.note("hunt matched ${addr(action.address)} by ${policy.lastMatch}")
                    apply(action)
                }
            }

            override fun onScanFailed(errorCode: Int) {
                main.post {
                    if (huntCb !== this) return@post
                    trail.note("hunt scan failed code=$errorCode")
                    stopHunt()
                    apply(policy.onScanEnded(now(), failed = true))
                }
            }
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(HR_SERVICE)).build())
        val mode = if (h.lowLatency) ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_BALANCED
        val settings = ScanSettings.Builder().setScanMode(mode).build()
        try {
            scanner.startScan(filters, settings, cb)
        } catch (e: Exception) {
            trail.note("hunt scan start threw: $e")
            apply(policy.onScanEnded(now(), failed = true))
            return
        }
        huntCb = cb
        trail.note("hunt start scanMs=${h.scanMs} lowLatency=${h.lowLatency} passive=${addr(h.passiveAddress)} name=${policy.savedName ?: "-"}")
        val end = Runnable {
            huntEnd = null
            if (huntCb !== cb) return@Runnable
            trail.note("hunt scan ended, ${huntDevices.size} HR device(s) seen, no match")
            stopHunt()
            apply(policy.onScanEnded(now(), failed = false))
        }
        huntEnd = end
        main.postDelayed(end, h.scanMs)
        val tick = object : Runnable {
            override fun run() {
                if (huntCb !== cb) return
                apply(policy.onHuntTick(now()))
                if (huntCb === cb) main.postDelayed(this, HUNT_TICK_MS)
            }
        }
        huntTick = tick
        main.postDelayed(tick, HUNT_TICK_MS)
        // A strap with a fixed address comes back on its own; the scan covers one that rotates.
        connect(h.passiveAddress, autoConnect = true)
    }

    @SuppressLint("MissingPermission")
    private fun stopHunt() {
        huntEnd?.let { main.removeCallbacks(it) }
        huntEnd = null
        huntTick?.let { main.removeCallbacks(it) }
        huntTick = null
        val cb = huntCb ?: return
        huntCb = null
        try {
            adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Exception) {
        }
    }

    /** Last two octets only: enough to tell addresses apart in the trail. */
    private fun addr(address: String): String = "…" + address.takeLast(5) + "/" + addressType(address).substringBefore('-')

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
            cancelConnectWindow()
            stopHunt() // a late scan result must not tear down the working link
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
        trail.note("setup failed: $what retried=$setupRetried")
        if (!setupRetried) {
            setupRetried = true
            main.postDelayed({ if (g === gatt) g.discoverServices() }, 500)
        } else {
            closeGatt()
            setConnected(false)
            apply(policy.onDisconnected(now()))
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
                    trail.note("link up status=$status state=${policy.state}")
                    if (policy.state == BleReconnectPolicy.LinkState.HUNTING) {
                        // The hunt's passive connect to the saved address came up: stop scanning, set it up.
                        policy.onLinkUp()
                        stopHunt()
                        armConnectWindow()
                    }
                    if (!g.discoverServices()) setupFailed(g, "discoverServices")
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    Log.i(TAG, "disconnected status=$status")
                    trail.note("link down status=$status state=${policy.state} wasConnected=$connected")
                    val hunting = policy.state == BleReconnectPolicy.LinkState.HUNTING
                    if (hunting) closeGatt() // only the passive connect gave up; the hunt's scan carries on
                    setConnected(false)
                    listener?.onNoContact()
                    if (!hunting) apply(policy.onDisconnected(now()))
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
                policy.onConnected(now())
                persistIdentity()
                setConnected(true)
                Log.i(TAG, "first measurement received; strap connected")
                trail.note("connected: first measurement bpm=${parsed.bpm ?: "no-contact"} match=${policy.lastMatch}")
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
        private const val CONNECT_WINDOW_MS = 10_000L
        private const val HUNT_TICK_MS = 1_000L
        private const val LINGER_MS = 5_000L
        private const val PAIR_HOLD_MS = 120_000L
        const val OWNER_START = "start"
        const val OWNER_RUN = "run"
        const val OWNER_PAIR = "pair"
        val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HR_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
