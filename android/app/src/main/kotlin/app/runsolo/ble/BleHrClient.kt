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
 * every connection is to the saved address, never a rescan (Android throttles scan starts and
 * suppresses unfiltered scans screen-off). At run start an existing link is kept, otherwise a
 * direct `connectGatt(autoConnect = false)`; after a drop `autoConnect = true` (passive, OS
 * managed). `gatt.close()` always precedes a reconnect (GATT 133 leak). "Connected" is reported
 * only once notifications are enabled (the CCCD write succeeded); a failed discovery or CCCD
 * write is retried once, then the link is closed and reconnected. Whoop broadcast is a
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
    private val policy = BleReconnectPolicy(prefs.getString(KEY_ADDRESS, null))
    private var gatt: BluetoothGatt? = null
    private var pendingReconnect: Runnable? = null
    private var setupRetried = false
    var listener: Listener? = null

    /** Notifications enabled on the HR characteristic (not merely a GATT link). */
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
        val found = LinkedHashMap<String, Found>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val d = result.device ?: return
                val name = result.scanRecord?.deviceName ?: safeName(d)
                found[d.address] = Found(d.address, name)
            }

            override fun onScanFailed(errorCode: Int) {
                Log.w(TAG, "scan failed $errorCode")
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
        main.postDelayed({
            try {
                scanner.stopScan(cb)
            } catch (_: Exception) {
            }
            done(Result.success(found.values.toList()))
        }, timeoutMs)
    }

    fun pair(address: String) {
        prefs.edit().putString(KEY_ADDRESS, address).apply()
        val name = try {
            adapter?.getRemoteDevice(address)?.let { safeName(it) }
        } catch (_: Exception) {
            null
        }
        deviceName = name
        prefs.edit().putString(KEY_NAME, name).apply()
        apply(policy.pair(address))
    }

    fun forget() {
        prefs.edit().remove(KEY_ADDRESS).remove(KEY_NAME).apply()
        deviceName = null
        cancelReconnect()
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
        Log.i(TAG, "connectGatt autoConnect=$autoConnect")
        setupRetried = false
        gatt = try {
            device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            Log.w(TAG, "connectGatt threw: $e")
            null
        }
        if (gatt == null) apply(policy.onConnectFailed(SystemClock.elapsedRealtime()))
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
        if (connected == v) return
        connected = v
        if (!v) lastHr = null
        listener?.onLink(v)
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
                    policy.onConnected(SystemClock.elapsedRealtime())
                    setConnected(true)
                    Log.i(TAG, "HR notifications on")
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
        val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HR_MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
