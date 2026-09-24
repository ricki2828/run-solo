package app.runsolo.core.ble

/**
 * Reconnect decisions for the paired strap (plan §3, W7). The Android client asks this object
 * what to do on every link event and does exactly that; no rescanning, ever, because Android
 * throttles scan starts (5 per 30 s) and suppresses unfiltered scans while the screen is off.
 *
 *  - Pairing scans once (outside this object) and saves the address.
 *  - At start (and pairing) the connect is direct (`autoConnect = false`: seconds, not the
 *    10–60 s a passive autoConnect can take). Every reconnect after a drop is `gatt.close()`
 *    first (GATT 133 leak), then `connectGatt(autoConnect = true)` to the saved address —
 *    a passive, OS-managed wait, so there is no give-up.
 *  - An explicit retry after a failed connect attempt backs off 1 s → 2 s → 4 s … capped at
 *    [maxDelayMs]; the backoff resets after a link that stayed up ≥ [stableMs].
 */
class BleReconnectPolicy(
    address: String?,
    private val initialDelayMs: Long = 1_000,
    private val maxDelayMs: Long = 30_000,
    private val stableMs: Long = 10_000,
) {
    sealed class Action {
        /** Close the current GATT (if any), then connectGatt(autoConnect = [autoConnect]) after [delayMs]. */
        data class Reconnect(val address: String, val autoConnect: Boolean, val delayMs: Long, val closeFirst: Boolean) : Action()
        object Nothing : Action()
    }

    var savedAddress: String? = address
        private set
    var attempts: Int = 0
        private set
    private var nextDelay = initialDelayMs
    private var connectedAt: Long? = null

    /** `blePair(address)`: remember the strap; the first connection is direct (autoConnect = false). */
    fun pair(address: String): Action {
        savedAddress = address
        attempts = 0
        nextDelay = initialDelayMs
        return Action.Reconnect(address, autoConnect = false, delayMs = 0, closeFirst = true)
    }

    /** `bleForget()`: drop the address; nothing reconnects afterwards. */
    fun forget(): Action {
        savedAddress = null
        connectedAt = null
        return Action.Nothing
    }

    /** Recording starts (or the app opens with a saved strap): a direct connect now. */
    fun onStart(): Action {
        val a = savedAddress ?: return Action.Nothing
        return Action.Reconnect(a, autoConnect = false, delayMs = 0, closeFirst = true)
    }

    fun onConnected(nowMs: Long) {
        connectedAt = nowMs
        attempts = 0
    }

    /** Link dropped (`onConnectionStateChange` disconnected, any status incl. 133). */
    fun onDisconnected(nowMs: Long): Action {
        val a = savedAddress ?: return Action.Nothing
        val stable = connectedAt?.let { nowMs - it >= stableMs } ?: false
        connectedAt = null
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
}
