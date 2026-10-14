package app.runsolo.core.trail

/**
 * Where the trail ghost hands a line that wants saying. The ghost never speaks for itself once an arbiter
 * (`TalkBudget`) exists: the recorder offers the line here and the arbiter decides whether and when it is said
 * (the turnaround is P0: it always speaks). With no sink the recorder says it straight away, as a followed
 * route's end does.
 */
fun interface TrailCueSink {
    /** The runner is at the turnaround point of the known out-and-back trail [trailId]; [text] is the line, [t] the fix's time. */
    fun turnaround(trailId: String, text: String, t: Long)
}
