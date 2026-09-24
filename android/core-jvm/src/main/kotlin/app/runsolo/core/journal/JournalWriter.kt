package app.runsolo.core.journal

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.run.RunPaths

/**
 * Append-only writer for one run's journal (plan §3): `write()` + flush on every line so a
 * process kill loses nothing already written; `fsync` at most every [fsyncIntervalMs] and
 * immediately on lap/pause/resume/gap/stop (power-loss guard).
 *
 * Any I/O failure is reported through [onWriteFailed] once and marks [ok] false; the service
 * surfaces it as `fault{journalWriteFailed}` and keeps recording in memory rather than crashing.
 */
class JournalWriter(
    private val fs: FileSystem,
    private val runId: String,
    private val fsyncIntervalMs: Long = 10_000,
    private val onWriteFailed: (Throwable) -> Unit = {},
) : AutoCloseable {
    val path: String = RunPaths.journal(runId)
    private var appender: FileSystem.Appender? = null
    private var lastFsyncT: Long = Long.MIN_VALUE
    private var closed = false

    /** False once a write has failed; the writer stays usable but stops trying. */
    var ok: Boolean = true
        private set

    var linesWritten: Int = 0
        private set

    fun open() {
        fs.mkdirs(RunPaths.journalDir(runId))
        appender = fs.openAppend(path)
    }

    fun append(line: JournalLine) {
        if (!ok || closed) return
        val a = appender ?: throw IllegalStateException("JournalWriter not open")
        try {
            a.write((JournalCodec.encode(line) + "\n").toByteArray(Charsets.UTF_8))
            a.flush()
            linesWritten++
            val forced = line is JournalLine.Lap || line is JournalLine.Pause ||
                line is JournalLine.Resume || line is JournalLine.Gap || line is JournalLine.Header
            if (forced || lastFsyncT == Long.MIN_VALUE || line.t - lastFsyncT >= fsyncIntervalMs) {
                a.fsync()
                lastFsyncT = line.t
            }
        } catch (e: Throwable) {
            ok = false
            onWriteFailed(e)
        }
    }

    /** fsync now (called by stop() before finalising). */
    fun sync() {
        if (!ok || closed) return
        try {
            appender?.fsync()
        } catch (e: Throwable) {
            ok = false
            onWriteFailed(e)
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            appender?.fsync()
        } catch (_: Throwable) {
        }
        try {
            appender?.close()
        } catch (_: Throwable) {
        }
        appender = null
    }
}
