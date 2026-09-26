package app.runsolo.core.journal

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.run.RunPaths

/**
 * Append-only writer for one run's journal (plan §3): `write()` + flush on every line so a
 * process kill loses nothing already written; `fsync` at most every [fsyncIntervalMs] and
 * immediately on header/lap/pause/resume/gap (power-loss guard).
 *
 * Failure model:
 *  - A line that cannot be encoded (should not happen: the codec sanitises non-finite values)
 *    is dropped and counted in [dropped]; it never stops the journal.
 *  - An I/O failure (ENOSPC, EIO, a torn descriptor) puts the writer in a degraded state:
 *    lines are kept in a bounded memory buffer ([bufferLimit], ~1 h at 1 Hz), [onWriteFailed]
 *    fires once per episode, and every later append retries reopening the file at most every
 *    [retryIntervalMs]; on success the buffer is flushed in order and [ok] goes back to true.
 *    [close] makes one last attempt so `stop()` loses only what the disk truly refused.
 *  - [open] on an existing journal (resume after a kill) first drops a torn tail — bytes after
 *    the last newline — so the resume `gap` line never fuses with a fragment.
 */
class JournalWriter(
    private val fs: FileSystem,
    private val runId: String,
    private val fsyncIntervalMs: Long = 10_000,
    private val retryIntervalMs: Long = 5_000,
    private val bufferLimit: Int = 4_000,
    private val onWriteFailed: (Throwable) -> Unit = {},
) : AutoCloseable {
    val path: String = RunPaths.journal(runId)
    private var appender: FileSystem.Appender? = null
    private var lastFsyncT: Long = Long.MIN_VALUE
    private var lastRetryT: Long = Long.MIN_VALUE
    private var closed = false
    private val pending = ArrayDeque<ByteArray>()

    /** False while degraded (last write failed and no retry has succeeded yet). */
    var ok: Boolean = true
        private set

    var linesWritten: Int = 0
        private set

    /** Lines lost: undecodable, or evicted from the memory buffer while degraded. */
    var dropped: Int = 0
        private set

    /** Lines currently held in memory because the disk refused them. */
    val buffered: Int get() = pending.size

    /** Bytes removed from a torn tail by [open]; 0 for a fresh journal. */
    var tornTailBytes: Long = 0
        private set

    fun open() {
        fs.mkdirs(RunPaths.journalDir(runId))
        if (fs.exists(path)) {
            val bytes = fs.readBytes(path)
            if (bytes.isNotEmpty() && bytes.last() != '\n'.code.toByte()) {
                val keep = bytes.lastIndexOf('\n'.code.toByte()) + 1
                tornTailBytes = (bytes.size - keep).toLong()
                fs.truncate(path, keep.toLong())
            }
        }
        appender = fs.openAppend(path)
    }

    fun append(line: JournalLine) {
        if (closed) return
        val bytes = try {
            (JournalCodec.encode(line) + "\n").toByteArray(Charsets.UTF_8)
        } catch (_: Exception) {
            dropped++
            return
        }
        val forced = line is JournalLine.Lap || line is JournalLine.Pause ||
            line is JournalLine.Resume || line is JournalLine.Gap || line is JournalLine.Header ||
            line is JournalLine.LiveContextLine || line is JournalLine.CueFired
        if (!ok) {
            enqueue(bytes)
            if (line.t - lastRetryT >= retryIntervalMs || lastRetryT == Long.MIN_VALUE) {
                lastRetryT = line.t
                if (reopen()) flushPending(line.t, forced)
            }
            return
        }
        if (!writeNow(bytes, line.t, forced)) {
            enqueue(bytes)
            lastRetryT = line.t
        }
    }

    private fun enqueue(bytes: ByteArray) {
        if (pending.size >= bufferLimit) {
            pending.removeFirst()
            dropped++
        }
        pending.addLast(bytes)
    }

    /** Returns false (and degrades) on failure. */
    private fun writeNow(bytes: ByteArray, t: Long, forced: Boolean): Boolean {
        val a = appender ?: throw IllegalStateException("JournalWriter not open")
        return try {
            a.write(bytes)
            a.flush()
            linesWritten++
            if (forced || lastFsyncT == Long.MIN_VALUE || t - lastFsyncT >= fsyncIntervalMs) {
                a.fsync()
                lastFsyncT = t
            }
            true
        } catch (e: Throwable) {
            if (ok) onWriteFailed(e)
            ok = false
            false
        }
    }

    private fun reopen(): Boolean {
        try {
            appender?.close()
        } catch (_: Throwable) {
        }
        appender = null
        return try {
            fs.mkdirs(RunPaths.journalDir(runId))
            appender = fs.openAppend(path)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun flushPending(t: Long, forced: Boolean) {
        while (pending.isNotEmpty()) {
            val head = pending.first()
            val a = appender ?: return
            try {
                a.write(head)
                a.flush()
                linesWritten++
                pending.removeFirst()
            } catch (_: Throwable) {
                return
            }
        }
        ok = true
        try {
            if (forced) {
                appender?.fsync()
                lastFsyncT = t
            }
        } catch (e: Throwable) {
            onWriteFailed(e)
            ok = false
        }
    }

    /** fsync now (called by stop() before finalising); retries buffered lines first. */
    fun sync() {
        if (closed) return
        if (!ok && reopen()) flushPending(lastFsyncT, forced = true)
        if (!ok) return
        try {
            appender?.fsync()
        } catch (e: Throwable) {
            onWriteFailed(e)
            ok = false
        }
    }

    override fun close() {
        if (closed) return
        sync()
        closed = true
        try {
            appender?.close()
        } catch (_: Throwable) {
        }
        appender = null
    }
}
