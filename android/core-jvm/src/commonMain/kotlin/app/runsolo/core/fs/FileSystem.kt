package app.runsolo.core.fs

/**
 * The only way core-jvm touches storage. Paths are plain strings relative to the app's
 * `files/` root (`runs/<id>/journal.ndjson`, `runs/run-<id>.json.gz`, `runs-archive/...`).
 *
 * The contract is deliberately small so a test double can inject a crash at any boundary
 * (before rename, after rename before index, after index) and a real implementation maps
 * 1:1 onto java.nio with `FileChannel.force(true)` for fsync.
 */
interface FileSystem {
    fun exists(path: String): Boolean
    fun isDirectory(path: String): Boolean

    /** Direct children names (not paths) of a directory; empty when it does not exist. */
    fun list(dir: String): List<String>
    fun mkdirs(dir: String)
    fun readBytes(path: String): ByteArray
    fun size(path: String): Long

    /** Last modification time in epoch millis, or null when the file does not exist. */
    fun lastModifiedMs(path: String): Long?

    /** Opens (creating if needed) for append. Parent directory must exist. */
    fun openAppend(path: String): Appender

    /** Writes the whole file; overwrites. Caller fsyncs via [fsyncFile] when it matters. */
    fun writeBytes(path: String, bytes: ByteArray)
    fun fsyncFile(path: String)

    /** fsync the directory entry so a rename survives power loss. */
    fun fsyncDir(dir: String)

    /** Cut the file to [size] bytes (used to drop a torn tail before appending a resume). */
    fun truncate(path: String, size: Long)

    /** Atomic replace within the same filesystem. */
    fun rename(from: String, to: String)
    fun delete(path: String)

    /** Deletes a directory and everything under it. */
    fun deleteRecursively(path: String)

    interface Appender : AutoCloseable {
        fun write(bytes: ByteArray)

        /** Push to the OS (survives a process kill). */
        fun flush()

        /** Push to disk (survives power loss). */
        fun fsync()
        override fun close()
    }
}

/** Helpers shared by implementations. */
fun String.parentPath(): String? {
    val i = lastIndexOf('/')
    return if (i <= 0) null else substring(0, i)
}

fun String.fileName(): String = substringAfterLast('/')
