package app.runsolo.garmin

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.ConnectIQ.IQApplicationEventListener
import com.garmin.android.connectiq.ConnectIQ.IQConnectType
import com.garmin.android.connectiq.ConnectIQ.IQMessageStatus
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.monkeybrains.serialization.Serializer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Phase 0 spike bridge (Garmin plan exit checks a-f). Lives for the whole process so it keeps
 * receiving while the activity is in the background; every log line says whether an activity was
 * resumed (bg=0/1) so background delivery is visible in the exported log. Dogfood flavour only.
 */
object GarminSpike {
    /** Must equal garmin/manifest.xml's application id; garmin/tools/check_ids.py enforces it in CI. */
    const val APP_ID = "41321ac77d204b33b9f974642f1c733e"

    private const val MAX_LOG = 2000
    private val app = IQApp(APP_ID)
    private val ui = Handler(Looper.getMainLooper())
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val lines = ArrayDeque<String>()
    private var ciq: ConnectIQ? = null
    private var device: IQDevice? = null
    private var pingN = 0
    private var pingT0 = 0L

    // throughput bookkeeping (watch sends 25 x 1000-char chunks)
    private var tpCount = 0
    private var tpWire = 0
    private var tpFirst = 0L

    @Volatile var foreground = false
    @Volatile var onChange: (() -> Unit)? = null
    @Volatile var lastResults: String = "(none yet)"

    fun log(s: String) {
        synchronized(lines) {
            lines.addLast("${stamp.format(Date())} bg=${if (foreground) 0 else 1} $s")
            while (lines.size > MAX_LOG) lines.removeFirst()
        }
        onChange?.let { ui.post(it) }
    }

    fun text(): String = synchronized(lines) { lines.joinToString("\n") }

    fun clear() = synchronized(lines) { lines.clear() }

    /** Log plus last results, newest content kept, capped well under the Binder limit for Share. */
    fun exportText(): String {
        val body = "Run Supreme Garmin spike log\nappId=$APP_ID\n\nLAST WATCH RESULTS\n$lastResults\n\nLOG\n${text()}"
        return if (body.length > 200_000) body.takeLast(200_000) else body
    }

    fun status(): String =
        "sdk=${if (ciq == null) "off" else "up"} device=${device?.friendlyName ?: "none"} appId=${APP_ID.take(8)}.."

    fun start(context: Context) {
        if (ciq != null) return
        val sdk = ConnectIQ.getInstance(context.applicationContext, IQConnectType.WIRELESS)
        ciq = sdk
        sdk.initialize(context.applicationContext, true, object : ConnectIQ.ConnectIQListener {
            override fun onSdkReady() {
                log("sdk ready")
                pickDevice()
            }

            override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus) {
                log("sdk init error $status")
                ciq = null
            }

            override fun onSdkShutDown() {
                log("sdk shut down")
                ciq = null
            }
        })
    }

    fun reconnect(context: Context) {
        try { ciq?.shutdown(context.applicationContext) } catch (e: Exception) { log("shutdown: $e") }
        ciq = null
        device = null
        start(context)
    }

    private fun pickDevice() {
        val sdk = ciq ?: return
        try {
            val known = sdk.knownDevices.orEmpty()
            known.forEach { log("known device ${it.friendlyName} id=${it.deviceIdentifier} status=${sdk.getDeviceStatus(it)}") }
            val chosen = known.firstOrNull { sdk.getDeviceStatus(it) == IQDevice.IQDeviceStatus.CONNECTED } ?: known.firstOrNull()
            if (chosen == null) {
                log("NO paired Garmin device (pair the watch in Garmin Connect first)")
                return
            }
            device = chosen
            sdk.registerForDeviceEvents(chosen) { d, st -> log("device ${d.friendlyName} -> $st") }
            // Exit check (a): the sideloaded app must not be reported as not installed.
            sdk.getApplicationInfo(APP_ID, chosen, object : ConnectIQ.IQApplicationInfoListener {
                override fun onApplicationInfoReceived(a: IQApp) =
                    log("app INSTALLED on ${chosen.friendlyName}: name=${a.displayName} version=${a.version()} status=${a.status}")

                override fun onApplicationNotInstalled(id: String) =
                    log("app NOT INSTALLED according to Garmin Connect Mobile (id=$id): exit check (a) FAILS or the .prg is not on the watch")
            })
            sdk.registerForAppEvents(chosen, app, appListener)
            log("listening on ${chosen.friendlyName} for app ${APP_ID.take(8)}..")
        } catch (e: Exception) {
            log("pickDevice error: $e")
        }
    }

    private fun wireSize(o: Any?): Int = try { Serializer.serialize(o).size } catch (e: Exception) { -1 }

    private val appListener = IQApplicationEventListener { dev, from, messages, status ->
        // Exit check (f): ignore anything not from our app id.
        if (from.applicationId != APP_ID) {
            log("IGNORED message from other app id ${from.applicationId}")
            return@IQApplicationEventListener
        }
        if (status != IQMessageStatus.SUCCESS) {
            log("rx status $status")
            return@IQApplicationEventListener
        }
        messages.orEmpty().forEach { handle(dev, it) }
    }

    private fun handle(dev: IQDevice, obj: Any?) {
        val wire = wireSize(obj)
        val m: Map<String, Any?> = (obj as? Map<*, *>)?.mapKeys { it.key.toString() } ?: emptyMap()
        val t = m["t"] as? String
        val now = System.currentTimeMillis()
        when (t) {
            "hello" -> {
                log("rx hello wire=${wire}B $m")
                send(mapOf("t" to "echo", "n" to (m["n"] ?: 0), "bg" to if (foreground) 0 else 1))
            }
            "chunk" -> {
                val i = (m["i"] as? Number)?.toInt() ?: -1
                if (i == 0) { tpCount = 0; tpWire = 0; tpFirst = now }
                tpCount += 1
                tpWire += wire
                val n = (m["n"] as? Number)?.toInt() ?: 0
                if (i == n - 1) {
                    val ms = now - tpFirst
                    log("rx chunks got=$tpCount/$n wire=${tpWire}B in ${ms}ms (phone clock, first to last)")
                    send(mapOf("t" to "tp", "got" to tpCount, "bytes" to tpWire, "ms" to ms.toInt()))
                }
            }
            "burst" -> log("rx burst n=${m["n"]} watch-uptime=${m["up"]} wire=${wire}B")
            "smp" -> {
                val f = m["f"]
                log("rx sample fmt=$f pts=${m["k"]} wire=${wire}B")
                send(mapOf("t" to "sz", "f" to f, "k" to m["k"], "bytes" to wire))
            }
            "pong" -> log("rx pong n=${m["n"]} rtt=${now - pingT0}ms")
            "res" -> {
                lastResults = m.entries.sortedBy { it.key.toString() }.joinToString("\n") { "${it.key}=${it.value}" }
                log("rx RESULTS wire=${wire}B\n$lastResults")
            }
            else -> log("rx unknown wire=${wire}B $obj")
        }
    }

    fun send(payload: Map<String, Any?>) {
        val sdk = ciq
        val d = device
        if (sdk == null || d == null) { log("send skipped: sdk/device not ready"); return }
        try {
            sdk.sendMessage(d, app, payload) { _, _, st -> log("tx ${payload["t"]} -> $st") }
        } catch (e: Exception) {
            log("send error: $e")
        }
    }

    fun pingWatch() {
        pingN += 1
        pingT0 = System.currentTimeMillis()
        send(mapOf("t" to "ping", "n" to pingN))
    }
}
