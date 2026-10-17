package app.runsolo.core.ble

/**
 * Connect and reconnect decisions for the paired strap (plan §3, W7). The Android client asks
 * this object what to do on every link and scan event and does exactly that.
 *
 * Why scan-first: a WHOOP in "Broadcast Heart Rate" advertises from a rotating resolvable private
 * address and is not bonded, so the address saved at pairing goes stale between sessions (and can
 * change after a mid-run drop). A direct `connectGatt` to a stale address hangs ~30 s before it
 * fails, and a passive `autoConnect` to it waits forever. So, apart from pairing, the strap is only
 * connected directly at an address a scan has just seen:
 *
 *  - Pairing connects directly to the address its scan just returned ([pair]).
 *  - Otherwise every connect starts with a hunt ([Action.Hunt]): ONE long filtered scan (Heart Rate
 *    service 0x180D; filtered scans keep running screen-off) plus, alongside it, a passive
 *    `autoConnect` to the saved address for straps with a fixed address. Each scan result goes to
 *    [onScanResult]; the first that is the saved strap is connected directly at its fresh
 *    address, and the saved address (and name) are re-pointed.
 *  - A connect with no first measurement within the client's window, a dropped link, or a failed
 *    setup all go back to a hunt after a short backoff (0.5 s → 1 s → 2 s … capped at
 *    [maxDelayMs], reset after a link that stayed up ≥ [stableMs]).
 *  - Scan starts are budgeted ([SCAN_STARTS_PER_WINDOW] per [SCAN_WINDOW_MS]; Android allows 5 per
 *    30 s), and the pairing scan counts against the same budget ([noteScanStart]). A hunt that
 *    would exceed it is delayed until a start frees up, never dropped.
 *
 * Matching (never another runner's strap): the saved address, else the saved name
 * (case-insensitive). Nothing looser: a lone same-brand strap at a parkrun start is as likely to be
 * a stranger's (with ours not broadcasting yet) as ours with a changed name, and taking it would
 * record their HR and re-point the saved strap to them. WHOOP's advertised name carries its serial;
 * if a phone ever shows it changing, the trail's `hunt saw … name=` lines will say so.
 */
class BleReconnectPolicy(
    address: String?,
    name: String? = null,
    private val initialDelayMs: Long = 500,
    private val maxDelayMs: Long = 8_000,
    private val stableMs: Long = 10_000,
) {
    sealed class Action {
        object Nothing : Action()

        /** Stop any scan, close the current GATT, then `connectGatt(autoConnect = false)` to [address] after [delayMs]. */
        data class Connect(val address: String, val delayMs: Long) : Action()

        /**
         * Close the current GATT, then after [delayMs] start one filtered 0x180D scan of up to
         * [scanMs] (results to [onScanResult], its end to [onScanEnded]) and a passive
         * `connectGatt(autoConnect = true)` to [passiveAddress]. [lowLatency]: the first hunts of
         * an episode scan at low latency; a strap still missing after that is looked for at the
         * balanced (battery) rate.
         */
        data class Hunt(val delayMs: Long, val scanMs: Long, val passiveAddress: String, val lowLatency: Boolean = true) : Action()
    }

    enum class LinkState { IDLE, HUNTING, CONNECTING, CONNECTED }

    /** One HR peripheral seen by a scan. */
    data class Candidate(val address: String, val name: String?, val rssi: Int = 0)

    /** How a scan result was matched to the saved strap; for logs. */
    enum class Match { ADDRESS, NAME }

    var savedAddress: String? = address
        private set
    var savedName: String? = name
        private set
    var attempts: Int = 0
        private set
    var state: LinkState = LinkState.IDLE
        private set

    /** How the last connect from a hunt was matched (null after pairing); for logs. */
    var lastMatch: Match? = null
        private set
    private val scanStarts = ArrayList<Long>() // may hold one planned (future) hunt start
    private var nextDelay = initialDelayMs
    private var connectedAt: Long? = null
    private val seen = LinkedHashMap<String, Candidate>() // this hunt's HR peripherals by address
    private var huntsThisEpisode = 0

    /** `blePair(address)`: remember the strap and connect directly (a scan just saw this address). */
    fun pair(address: String, name: String? = null): Action {
        savedAddress = address
        savedName = name
        attempts = 0
        nextDelay = initialDelayMs
        lastMatch = null
        state = LinkState.CONNECTING
        return Action.Connect(address, delayMs = 0)
    }

    /** `bleForget()`: drop the strap; nothing connects afterwards. */
    fun forget(): Action {
        savedAddress = null
        savedName = null
        stop()
        return Action.Nothing
    }

    /** Nobody wants the strap any more (run ended, Start/Ready left): the client closes everything. */
    fun stop() {
        connectedAt = null
        seen.clear()
        state = LinkState.IDLE
    }

    /**
     * The strap is wanted (Start/Ready on screen, or a run starts). Already hunting, connecting or
     * connected: carry on. Otherwise hunt now.
     */
    fun onStart(nowMs: Long): Action {
        if (savedAddress == null || state != LinkState.IDLE) return Action.Nothing
        attempts = 0
        nextDelay = initialDelayMs
        huntsThisEpisode = 0
        return hunt(nowMs, 0)
    }

    /**
     * The hunt's passive connect to the saved address came up (a strap with a fixed address): it
     * is now being set up, so the client stops the scan and later scan results are ignored.
     */
    fun onLinkUp() {
        if (state != LinkState.HUNTING) return
        lastMatch = Match.ADDRESS
        state = LinkState.CONNECTING
    }

    /** The first measurement arrived. */
    fun onConnected(nowMs: Long) {
        connectedAt = nowMs
        attempts = 0
        huntsThisEpisode = 0
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
        scanStarts.removeAll { nowMs - it >= SCAN_WINDOW_MS }
    }

    /** A hunt starting at `now + delay`, pushed later if the scan-start budget is spent. */
    private fun hunt(nowMs: Long, delayMs: Long): Action {
        val a = savedAddress ?: return Action.Nothing
        prune(nowMs)
        var at = nowMs + delayMs
        if (scanStarts.size >= SCAN_STARTS_PER_WINDOW) {
            val freeAt = scanStarts.sorted()[scanStarts.size - SCAN_STARTS_PER_WINDOW] + SCAN_WINDOW_MS
            at = maxOf(at, freeAt)
        }
        scanStarts.add(at)
        seen.clear()
        state = LinkState.HUNTING
        val fast = huntsThisEpisode < FAST_HUNTS
        huntsThisEpisode++
        return Action.Hunt(delayMs = at - nowMs, scanMs = if (fast) FAST_SCAN_MS else HUNT_SCAN_MS, passiveAddress = a, lowLatency = fast)
    }

    /** One scan result during a hunt: connect the first one that is the saved strap. */
    fun onScanResult(c: Candidate, nowMs: Long): Action {
        if (state != LinkState.HUNTING || savedAddress == null) return Action.Nothing
        seen[c.address] = c
        return evaluate()
    }

    /** Periodic re-check while hunting (a no-op today: every match is made on a scan result). */
    fun onHuntTick(nowMs: Long): Action {
        if (state != LinkState.HUNTING || savedAddress == null) return Action.Nothing
        return evaluate()
    }

    private fun evaluate(): Action {
        val (c, how) = pick() ?: return Action.Nothing
        savedAddress = c.address
        lastMatch = how
        state = LinkState.CONNECTING
        return Action.Connect(c.address, delayMs = 0)
    }

    private fun pick(): Pair<Candidate, Match>? {
        val all = seen.values
        all.firstOrNull { it.address == savedAddress }?.let { return it to Match.ADDRESS }
        val n = savedName?.trim()
        if (n.isNullOrEmpty()) return null
        return all.filter { it.name?.trim().equals(n, ignoreCase = true) }.maxByOrNull { it.rssi }?.let { it to Match.NAME }
    }

    /**
     * The hunt's scan ended without a match: it ran its full length, or it could not start / failed
     * ([failed]). Hunt again, after the backoff when it failed.
     */
    fun onScanEnded(nowMs: Long, failed: Boolean): Action {
        if (state != LinkState.HUNTING) return Action.Nothing
        return hunt(nowMs, if (failed) backoff() else 0)
    }

    /**
     * The link dropped (`onConnectionStateChange` disconnected, any status incl. 133), a connect
     * had no first measurement in time, or setup failed twice. While hunting this can only be the
     * passive connect giving up: the scan carries on. Otherwise hunt again after the backoff.
     */
    fun onDisconnected(nowMs: Long): Action {
        if (savedAddress == null || state == LinkState.IDLE || state == LinkState.HUNTING) return Action.Nothing
        val stable = connectedAt?.let { nowMs - it >= stableMs } ?: false
        connectedAt = null
        if (stable) {
            nextDelay = initialDelayMs
            attempts = 0
        }
        return hunt(nowMs, backoff())
    }

    /** `connectGatt` returned null or threw, or no first measurement in time: same as a drop. */
    fun onConnectFailed(nowMs: Long): Action = onDisconnected(nowMs)

    private fun backoff(): Long {
        val d = nextDelay
        attempts++
        nextDelay = (nextDelay * 2).coerceAtMost(maxDelayMs)
        return d
    }

    companion object {
        const val SCAN_STARTS_PER_WINDOW = 4 // Android allows 5 starts per 30 s; keep one spare
        const val SCAN_WINDOW_MS = 30_000L

        /** One balanced hunt scan's length; restarted when it ends (well under Android's 30 min opportunistic downgrade). */
        const val HUNT_SCAN_MS = 5 * 60_000L

        /** Low-latency hunts per episode, and their length: a broadcasting strap is seen in a second or two. */
        const val FAST_HUNTS = 2
        const val FAST_SCAN_MS = 60_000L
    }
}
