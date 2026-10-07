package app.runsolo.core.fs

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.stream.Collectors

/** java.nio implementation rooted at [root] (the app's `files/` directory on Android). */
class JvmFileSystem(private val root: Path) : FileSystem {
    private fun p(path: String): Path = root.resolve(path)

    override fun exists(path: String) = Files.exists(p(path))
    override fun isDirectory(path: String) = Files.isDirectory(p(path))

    override fun list(dir: String): List<String> {
        val d = p(dir)
        if (!Files.isDirectory(d)) return emptyList()
        // Not Stream.toList(): that is Java 16 and crashes Android 10 (API 29) with NoSuchMethodError.
        Files.list(d).use { s -> return s.map { it.fileName.toString() }.collect(Collectors.toList()).sorted() }
    }

    override fun mkdirs(dir: String) {
        Files.createDirectories(p(dir))
    }

    override fun readBytes(path: String): ByteArray = Files.readAllBytes(p(path))
    override fun size(path: String): Long = Files.size(p(path))
    override fun lastModifiedMs(path: String): Long? =
        if (Files.exists(p(path))) Files.getLastModifiedTime(p(path)).toMillis() else null

    override fun openAppend(path: String): FileSystem.Appender {
        val ch = FileChannel.open(
            p(path),
            StandardOpenOption.CREATE,
            StandardOpenOption.WRITE,
            StandardOpenOption.APPEND,
        )
        return object : FileSystem.Appender {
            override fun write(bytes: ByteArray) {
                val buf = ByteBuffer.wrap(bytes)
                while (buf.hasRemaining()) ch.write(buf)
            }

            // FileChannel writes go straight to the OS; there is no user-space buffer to push.
            override fun flush() = Unit
            override fun fsync() = ch.force(true)
            override fun close() = ch.close()
        }
    }

    override fun writeBytes(path: String, bytes: ByteArray) {
        Files.write(p(path), bytes)
    }

    override fun fsyncFile(path: String) {
        FileChannel.open(p(path), StandardOpenOption.WRITE).use { it.force(true) }
    }

    override fun fsyncDir(dir: String) {
        // Directory fsync is POSIX-only; on JDKs/filesystems that refuse it, the rename is still
        // atomic at the kernel level, so treat the refusal as best-effort.
        try {
            FileChannel.open(p(dir), StandardOpenOption.READ).use { it.force(true) }
        } catch (_: IOException) {
        }
    }

    override fun truncate(path: String, size: Long) {
        FileChannel.open(p(path), StandardOpenOption.WRITE).use { it.truncate(size); it.force(true) }
    }

    override fun rename(from: String, to: String) {
        Files.move(p(from), p(to), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    override fun delete(path: String) {
        Files.deleteIfExists(p(path))
    }

    override fun deleteRecursively(path: String) {
        val d = p(path)
        if (!Files.exists(d)) return
        Files.walk(d).use { s -> s.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) } }
    }
}
