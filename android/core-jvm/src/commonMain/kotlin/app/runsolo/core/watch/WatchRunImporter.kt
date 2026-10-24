package app.runsolo.core.watch

import app.runsolo.core.fs.FileSystem
import app.runsolo.core.platform.IOException
import app.runsolo.core.platform.decodeUtf8
import app.runsolo.core.model.RunMode
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths

/**
 * Turns a [WatchRunPayload] into a run file (schema 8, the only schema that carries `watch`), durably and idempotently by run id, and says whether the
 * watch may be ACKed (plan §3.5, B2).
 *
 * The caller (the Android transport layer) sends the ACK for a run id **only** when [import] has returned
 * [Result.Imported] or [Result.AlreadyHave], and only after it returned. Receipt of chunks is never an ACK.
 * If [import] throws (a simulated or real kill, anything that is not an [IOException]), there is no result
 * and so no ACK: the watch resends and the next call finishes the job.
 *
 * Commit protocol is [app.runsolo.core.run.Finaliser]'s: gzip → `writeBytes(tmp)` → `fsyncFile(tmp)` →
 * `rename(tmp, runFile)` → `fsyncDir(runs/)`. The rename is the commit point. Everything is validated before
 * the first byte is written, so a rejected payload leaves the file system as it found it.
 *
 * Source of truth (W-N2): distance, km splits and laps are the watch's, written as sent. The importer never
 * recomputes distance from lat/lon and never filters a thinned track; the track is display data.
 */
class WatchRunImporter(private val fs: FileSystem) {
    sealed class Result {
        /** True when the watch may be told to delete this run. */
        abstract val ack: Boolean

        /** Written and made durable by this call. */
        data class Imported(val runId: String, val path: String) : Result() { override val ack get() = true }

        /** A run file with this id already exists in `runs/` or `runs-archive/`; nothing was rewritten. */
        data class AlreadyHave(val runId: String) : Result() { override val ack get() = true }

        /**
         * The payload is invalid (bad CRC, malformed, or failing a validation rule). Nothing was written. Never
         * ACK; resending the same bytes cannot help, so the transport (G4) must answer the watch explicitly:
         * `REJECTED(runId, reason)` instead of silence. On REJECTED the watch drops that payload from
         * `Application.Storage` (the FIT is already in Garmin Connect), stops resending it, and shows
         * "1 run could not sync". [reason] is a short human-readable string, safe to log and to show on the
         * phone. The reply set is therefore: `ACK(runId)` for [Imported] and [AlreadyHave], `REJECTED(runId,
         * reason)` for [Rejected], and no reply for [Failed] (the watch keeps the run and resends later).
         */
        data class Rejected(val reason: String) : Result() { override val ack get() = false }

        /** A storage error (disk full, I/O). The run may be retried later. Never ACK. */
        data class Failed(val reason: String) : Result() { override val ack get() = false }
    }

    /**
     * [payloadBytes] are the watch's UTF-8 JSON exactly as reassembled; [expectedCrc] is the unsigned CRC-32 the
     * watch sent with them (see [WatchRunPayload] for the algorithm). The CRC is checked over the raw bytes
     * before anything is parsed.
     */
    fun import(payloadBytes: ByteArray, expectedCrc: Long): Result {
        if (payloadBytes.size > WatchRunPayload.MAX_BYTES) return Result.Rejected("payload larger than ${WatchRunPayload.MAX_BYTES} bytes")
        if (WatchRunPayload.crc32(payloadBytes) != expectedCrc) return Result.Rejected("payload CRC mismatch")
        val payload = try {
            WatchRunPayload.parse(decodeUtf8(payloadBytes))
        } catch (e: WatchRunPayload.Invalid) {
            return Result.Rejected(e.message ?: "invalid payload")
        } catch (e: IllegalArgumentException) {
            return Result.Rejected("payload is not valid UTF-8")
        }
        val id = payload.runId
        val target = RunPaths.runFile(id)
        val tmp = RunPaths.runFileTmp(id)
        try {
            if (fs.exists(target)) {
                // A first call may have died after the rename and before the directory fsync. Make the
                // entry durable before saying "have it", so an ACK never outruns the disk.
                fs.fsyncDir(RunPaths.RUNS_DIR)
                fs.delete(tmp)
                return Result.AlreadyHave(id)
            }
            if (fs.exists(RunPaths.runFile(id, RunPaths.ARCHIVE_DIR))) return Result.AlreadyHave(id)

            val bytes = toRunFile(payload).toGzipBytes()
            fs.mkdirs(RunPaths.RUNS_DIR)
            fs.delete(tmp) // a crash left it: discard and rebuild
            fs.writeBytes(tmp, bytes)
            fs.fsyncFile(tmp)
            fs.rename(tmp, target)
            fs.fsyncDir(RunPaths.RUNS_DIR)
            return Result.Imported(id, target)
        } catch (e: IOException) {
            return Result.Failed(e.message ?: "I/O error")
        }
    }

    companion object {
        fun toRunFile(p: WatchRunPayload) = RunFile(
            id = p.runId,
            device = "garmin:${p.model}",
            app = "garmin-watch/${p.appVersion}",
            startEpochMs = p.startEpochMs,
            endEpochMs = p.endEpochMs,
            tz = p.tz,
            mode = RunMode.free,
            session = null,
            units = p.units,
            laps = p.laps,
            pauses = p.pauses,
            gaps = p.gaps,
            samples = p.samples,
            coach = p.coach,
            watch = RunFile.WatchInfo(p.model, p.rateChanges),
        )
    }
}
