package app.runsolo.core.journal

import app.runsolo.core.model.CueKind
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LiveContext

/**
 * A journal event on the RUN timeline (millis since the header, pauses and gaps included).
 * Device monotonic time is gone by this point; see [JournalReplay] for the rebasing rules.
 */
sealed class RunEvent {
    abstract val t: Long

    data class Sample(
        override val t: Long,
        val lat: Double?,
        val lon: Double?,
        val altM: Double?,
        val accuracyM: Double?,
        val speedMps: Double?,
        val hr: Int?,
    ) : RunEvent() {
        val hasFix: Boolean get() = lat != null && lon != null && accuracyM != null
    }

    data class Lap(override val t: Long, val source: LapSource) : RunEvent()
    data class Pause(override val t: Long) : RunEvent()
    data class Resume(override val t: Long) : RunEvent()
    data class Cue(override val t: Long, val kind: CueKind) : RunEvent()

    /** [t] is where the run went dark; [endT] where it resumed. */
    data class Gap(override val t: Long, val endT: Long) : RunEvent()
    data class HrLink(override val t: Long, val connected: Boolean) : RunEvent()
}

data class Replay(
    val header: JournalLine.Header,
    val events: List<RunEvent>,
    /** Run-timeline millis of the last decodable line. */
    val endT: Long,
    /** Wall-clock epoch millis of the last decodable line (for orphan ageing). */
    val lastWallMs: Long,
    /** Device monotonic `t` of the last decodable line (what a `gap` line must reference). */
    val lastDeviceT: Long,
    /** True when the file ended mid-line (process died while writing); the partial line is dropped. */
    val truncatedTail: Boolean,
    /** Lines that were complete but undecodable (bit rot); dropped, counted. */
    val badLines: Int,
    /** Backward jumps of `t` larger than [JournalReplay.CLOCK_JUMP_MS] with no `gap` line (a reboot without a resume; clamped, counted). */
    val clockJumps: Int,
    /** Lines written slightly out of time order (a back-dated auto-lap after a sample); re-sorted, counted. */
    val outOfOrder: Int,
    /** The `lctx` line's context (Phase 4 BLOCK-1); null = none journaled, the run stays silent. */
    val liveContext: LiveContext? = null,
    /** Every `cf` line, in journal order: live cues already spoken, never repeated on restore. */
    val cuesFired: List<JournalLine.CueFired> = emptyList(),
) {
    val isPaused: Boolean
        get() = events.lastOrNull { it is RunEvent.Pause || it is RunEvent.Resume } is RunEvent.Pause
}

object JournalReplay {
    open class NoHeader(message: String) : RuntimeException(message)

    /** The header is from a newer app (plan §18.7 W6): unreadable here, but never offered for discard. */
    class NewerJournal(message: String) : NoHeader(message)

    /** A backward step in `t` bigger than this is a clock reset, not a late line. */
    const val CLOCK_JUMP_MS = 5_000L

    /**
     * Decodes the journal bytes. Tolerates: a truncated last line (no trailing newline, or
     * unparsable — dropped), undecodable middle lines (dropped, counted), lines slightly out of
     * time order (the core back-dates a phase-end auto-lap to the boundary after later samples
     * were written: kept, re-sorted by `t` with journal order as the tie-break, counted), and a
     * monotonic clock that jumped backwards by more than [CLOCK_JUMP_MS] with no `gap` line
     * (clamped: run time does not advance, counted). Throws [NoHeader] when the first decodable
     * line is not a header — such a journal cannot be finalised.
     */
    fun read(bytes: ByteArray): Replay {
        val text = bytes.toString(Charsets.UTF_8)
        val endsWithNewline = text.endsWith("\n")
        val rawLines = text.split('\n')
        // split() leaves a trailing "" after a final newline; drop it. Without the newline, the
        // last element is a partial line and is only kept if it happens to decode.
        val lines = if (endsWithNewline) rawLines.dropLast(1) else rawLines

        var header: JournalLine.Header? = null
        val events = ArrayList<RunEvent>()
        var badLines = 0
        var liveContext: LiveContext? = null
        val cuesFired = ArrayList<JournalLine.CueFired>()
        var clockJumps = 0
        var outOfOrder = 0
        var truncated = false
        var offset = 0L // runT = deviceT + offset
        var lastRunT = 0L
        var lastDeviceT = 0L
        var lastWall = 0L

        for ((i, raw) in lines.withIndex()) {
            if (raw.isBlank()) continue
            val isLast = i == lines.lastIndex
            val line = try {
                JournalCodec.decode(raw)
            } catch (e: JournalCodec.NewerSchema) {
                if (header == null) throw NewerJournal(e.message ?: "newer journal")
                badLines++
                continue
            } catch (_: Exception) {
                if (isLast && !endsWithNewline) truncated = true else badLines++
                continue
            }
            if (header == null) {
                header = line as? JournalLine.Header ?: throw NoHeader("First journal line is not a header")
                offset = -line.t
                lastDeviceT = line.t
                lastWall = line.w
                continue
            }
            if (line is JournalLine.Header) { badLines++; continue } // duplicate header
            // Live-compare bookkeeping, not run events: kept aside, never on the run timeline.
            if (line is JournalLine.LiveContextLine) { if (liveContext == null) liveContext = line.context; continue }
            if (line is JournalLine.CueFired) { cuesFired.add(line); continue }
            val runT: Long
            if (line is JournalLine.Gap) {
                // Run time continues through the dark span; the new device base is line.t.
                val gapStart = lastRunT
                val gapEnd = gapStart + line.wallGapMs.coerceAtLeast(0)
                offset = gapEnd - line.t
                runT = gapEnd
                events.add(RunEvent.Gap(gapStart, gapEnd))
            } else {
                var candidate = line.t + offset
                if (candidate < lastRunT - CLOCK_JUMP_MS) {
                    // Monotonic time went backwards with no gap line: clamp, never go negative.
                    clockJumps++
                    offset = lastRunT - line.t
                    candidate = lastRunT
                } else if (candidate < lastRunT) {
                    outOfOrder++
                }
                runT = candidate
                events.add(
                    when (line) {
                        is JournalLine.Sample -> RunEvent.Sample(runT, line.lat, line.lon, line.altM, line.accuracyM, line.speedMps, line.hr)
                        is JournalLine.Lap -> RunEvent.Lap(runT, line.source)
                        is JournalLine.Pause -> RunEvent.Pause(runT)
                        is JournalLine.Resume -> RunEvent.Resume(runT)
                        is JournalLine.Cue -> RunEvent.Cue(runT, line.kind)
                        is JournalLine.HrLink -> RunEvent.HrLink(runT, line.connected)
                        is JournalLine.Header, is JournalLine.Gap,
                        is JournalLine.LiveContextLine, is JournalLine.CueFired -> throw IllegalStateException()
                    },
                )
            }
            if (runT >= lastRunT) {
                lastRunT = runT
                lastDeviceT = line.t
            }
            if (line.w > lastWall) lastWall = line.w
        }
        val h = header ?: throw NoHeader("Journal has no decodable header")
        // Stable: equal t keeps journal order (pause before resume, lap before sample).
        val sorted = if (outOfOrder == 0) events else events.sortedBy { it.t }
        return Replay(
            header = h,
            events = sorted,
            endT = lastRunT,
            lastWallMs = lastWall,
            lastDeviceT = lastDeviceT,
            truncatedTail = truncated,
            badLines = badLines,
            clockJumps = clockJumps,
            outOfOrder = outOfOrder,
            liveContext = liveContext,
            cuesFired = cuesFired,
        )
    }
}
