package app.runsolo.core.ble

/**
 * Reconnect decisions for the paired strap (plan §3, W7). The Android client asks this object
 * what to do on every link event and does exactly that. Rescanning is the exception, never a
 * loop: Android throttles scan starts (5 per 30 s) and suppresses unfiltered scans while the
 * screen is off. The one exception is the name fallback below.
 *
 *  - Pairing scans once (outside this object) and saves the address.
 *  - At start (and pairing) the connect is direct (`autoConnect = false`: seconds, not the
 *    10–60 s a passive autoConnect can take). Every reconnect after a drop is `gatt.close()`
 *    first (GATT 133 leak), then `connectGatt(autoConnect = true)` to the saved address —
 *    a passive, OS-managed wait, so there is no give-up.
 *  - Name fallback: a strap that broadcasts with a rotating random private address (not bonded)
 *    leaves the saved address stale, so connectGatt never succeeds. When a connect yields no
 *    measurement within the client's window, [onNoMeasurement] asks for ONE filtered scan
 *    (HR service) per episode, matched on the saved device name; a match re-points the saved
 *    address ([onScanResult]), no match leaves the strap paired but [LinkState.NOT_FOUND].
 *    Scan starts are budgeted ([SCAN_STARTS_PER_WINDOW] per [SCAN_WINDOW_MS]) and the pairing
 *    scan counts against the same budget ([noteScanStart]).
 *  - An explicit retry after a failed connect attempt backs off 1 s → 2 s → 4 s … capped at
 *    [maxDelayMs]; the backoff resets after a link that stayed up ≥ [stableMs].
 */
class BleReconnectPolicy(
    address: String?,
    name: String? = null,
    private val initialDelayMs: Long = 1_000,
    private val maxDelayMs: Long = 30_000,
    private val stableMs: Long = 10_000,
) {
    sealed class Action {
        /** Close the current GATT (if any), then connectGatt(autoConnect = [autoConnect]) after [delayMs]. */
        data class Reconnect(val address: String, val autoConnect: Boolean, val delayMs: Long, val closeFirst: Boolean) : Action()
        object Nothing : Action()

        /** One filtered HR-service scan, [timeoutMs] long, then call [onScanResult] with what matched. */
        data class ScanForName(val name: String, val timeoutMs: Long) : Action()
    }

    enum class LinkState { IDLE, CONNECTING, SCANNING, NOT_FOUND, CONNECTED }

    /** One HR peripheral seen by a scan. */
    data class Candidate(val address: String, val name: String?, val rssi: Int = 0)

    /** Why a name scan was or was not started; for logs (no addresses). */
    enum class FallbackReason { NO_NAME, ALREADY_SCANNED, THROTTLED, STARTED }

    var savedAddress: String? = address
        private set
    var savedName: String? = name
        private set
    var attempts: Int = 0
        private set
    var state: LinkState = LinkState.IDLE
        private set
    var lastFallback: FallbackReason? = null
        private set
    private var scannedThisEpisode = false
    private val scanStarts = ArrayList<Long>()
    private var nextDelay = initialDelayMs
    private var connectedAt: Long? = null

    /** `blePair(address)`: remember the strap; the first connection is direct (autoConnect = false). */
    fun pair(address: String, name: String? = null): Action {
        savedAddress = address
        savedName = name
        scannedThisEpisode = false
        state = LinkState.CONNECTING
        attempts = 0
        nextDelay = initialDelayMs
        return Action.Reconnect(address, autoConnect = false, delayMs = 0, closeFirst = true)
    }

    /** `bleForget()`: drop the address; nothing reconnects afterwards. */
    fun forget(): Action {
        savedAddress = null
        savedName = null
        connectedAt = null
        state = LinkState.IDLE
        return Action.Nothing
    }

    /** Recording starts (or the app opens with a saved strap): a direct connect now. */
    fun onStart(): Action {
        val a = savedAddress ?: return Action.Nothing
        scannedThisEpisode = false
        state = LinkState.CONNECTING
        return Action.Reconnect(a, autoConnect = false, delayMs = 0, closeFirst = true)
    }

    /** The first measurement arrived: the saved address works, so the next failure gets a fresh fallback. */
    fun onConnected(nowMs: Long) {
        connectedAt = nowMs
        attempts = 0
        scannedThisEpisode = false
        state = LinkState.CONNECTED
    }

    /** The pairing scan (outside this object) also spends from the scan-start budget. */
    fun noteScanStart(nowMs: Long) {
        prune(nowMs)
        scanStarts.add(nowMs)
    }

    /** Whether a scan start is still inside the budget (the pairing scan checks this before it starts). */
    fun canStartScan(nowMs: Long): Boolean {
        prune(nowMs)
        return scanStarts.size < SCAN_STARTS_PER_WINDOW
    }

    private fun prune(nowMs: Long) {
        scanStarts.removeAll { nowMs - it >= SCAN_WINDOW_MS || it > nowMs }
    }

    /**
     * A connect (direct or passive) produced no measurement within the client's window. At most
     * one name scan per episode (start, pair, or last working link), and only inside the scan-start
     * budget. Without a saved name nothing can be matched safely (another runner's strap would
     * also advertise 0x180D), so the strap is left [LinkState.NOT_FOUND] without scanning.
     */
    fun onNoMeasurement(nowMs: Long): Action {
        if (savedAddress == null || state == LinkState.CONNECTED) return Action.Nothing
        val n = savedName
        if (n.isNullOrBlank()) {
            lastFallback = FallbackReason.NO_NAME
            state = LinkState.NOT_FOUND
            return Action.Nothing
        }
        if (scannedThisEpisode) {
            lastFallback = FallbackReason.ALREADY_SCANNED
            state = LinkState.NOT_FOUND // the scanned-for address also failed: say so, do not loop
            return Action.Nothing
        }
        prune(nowMs)
        if (scanStarts.size >= SCAN_STARTS_PER_WINDOW) {
            lastFallback = FallbackReason.THROTTLED
            return Action.Nothing
        }
        scannedThisEpisode = true
        scanStarts.add(nowMs)
        lastFallback = FallbackReason.STARTED
        state = LinkState.SCANNING
        return Action.ScanForName(n, SCAN_TIMEOUT_MS)
    }

    /**
     * Result of the name scan. A name match (case-insensitive, strongest signal wins) re-points
     * the saved address and connects directly; no match leaves the strap paired but disconnected
     * ([LinkState.NOT_FOUND]) with the old address kept for the passive reconnect already pending.
     */
    fun onScanResult(found: List<Candidate>, nowMs: Long): Action {
        if (savedAddress == null) return Action.Nothing
        if (state == LinkState.CONNECTED) return Action.Nothing // the old link came up during the scan: leave it alone
        val n = savedName
        val hit = if (n.isNullOrBlank()) null else
            found.filter { it.name.equals(n, ignoreCase = true) }.maxByOrNull { it.rssi }
        if (hit == null) {
            state = LinkState.NOT_FOUND
            return Action.Nothing
        }
        savedAddress = hit.address
        attempts = 0
        nextDelay = initialDelayMs
        state = LinkState.CONNECTING
        return Action.Reconnect(hit.address, autoConnect = false, delayMs = 0, closeFirst = true)
    }

    /** Link dropped (`onConnectionStateChange` disconnected, any status incl. 133). */
    fun onDisconnected(nowMs: Long): Action {
        val a = savedAddress ?: return Action.Nothing
        val stable = connectedAt?.let { nowMs - it >= stableMs } ?: false
        connectedAt = null
        if (state == LinkState.CONNECTED) state = LinkState.CONNECTING
        if (stable) {
            nextDelay = initialDelayMs
            attempts = 0
        }
        val delay = nextDelay
        attempts++
        nextDelay = (nextDelay * 2).coerceAtMost(maxDelayMs)
        return Action.Reconnect(a, autoConnect = true, delayMs = delay, closeFirst = true)
    }

    /** `connectGatt` returned null or threw (adapter off): same backoff as a drop. */
    fun onConnectFailed(nowMs: Long): Action = onDisconnected(nowMs)

    companion object {
        const val SCAN_STARTS_PER_WINDOW = 4 // Android allows 5 starts per 30 s; keep one spare
        const val SCAN_WINDOW_MS = 30_000L
        const val SCAN_TIMEOUT_MS = 8_000L
    }
}
