@file:OptIn(ExperimentalForeignApi::class)

package app.runsolo.core.fs

import app.runsolo.core.platform.FileNotFoundException
import app.runsolo.core.platform.IOException
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.ENOENT
import platform.posix.EINTR
import platform.posix.F_FULLFSYNC
import platform.posix.O_APPEND
import platform.posix.O_CREAT
import platform.posix.O_RDONLY
import platform.posix.O_TRUNC
import platform.posix.O_WRONLY
import platform.posix.S_IFDIR
import platform.posix.S_IFMT
import platform.posix.close
import platform.posix.closedir
import platform.posix.errno
import platform.posix.fcntl
import platform.posix.fsync
import platform.posix.ftruncate
import platform.posix.mkdir
import platform.posix.open
import platform.posix.opendir
import platform.posix.read
import platform.posix.readdir
import platform.posix.rmdir
import platform.posix.stat
import platform.posix.strerror
import platform.posix.unlink
import platform.posix.write

/**
 * POSIX implementation for iOS/watchOS/macOS, rooted at [root] (the app's Application Support
 * directory). Durability: `fsync` on Darwin only reaches the drive's cache; `F_FULLFSYNC`
 * flushes it, so every place the JVM side calls `FileChannel.force(true)` uses F_FULLFSYNC here,
 * falling back to fsync when the filesystem refuses it (as SQLite does).
 */
class AppleFileSystem(private val root: String) : FileSystem {
    private fun p(path: String) = "$root/$path"

    private fun fail(what: String, path: String): Nothing {
        val e = errno
        val msg = "$what $path: ${strerror(e)?.toKString()}"
        throw if (e == ENOENT) FileNotFoundException(msg) else IOException(msg)
    }

    private fun mode(path: String): Int? = memScoped {
        val st = alloc<stat>()
        if (stat(p(path), st.ptr) != 0) null else st.st_mode.toInt()
    }

    override fun exists(path: String) = mode(path) != null
    override fun isDirectory(path: String) = mode(path)?.let { it and S_IFMT.toInt() == S_IFDIR.toInt() } ?: false

    override fun list(dir: String): List<String> {
        val d = opendir(p(dir)) ?: return emptyList()
        try {
            val out = ArrayList<String>()
            while (true) {
                val e = readdir(d) ?: break
                val n = e.pointed.d_name.toKString()
                if (n != "." && n != "..") out.add(n)
            }
            return out.sorted()
        } finally {
            closedir(d)
        }
    }

    override fun mkdirs(dir: String) {
        var cur = root
        for (part in dir.split('/').filter { it.isNotEmpty() }) {
            cur = "$cur/$part"
            if (mkdir(cur, 0x1ed.convert()) != 0 && !isDirAbs(cur)) fail("mkdir", cur)
        }
    }

    private fun isDirAbs(abs: String) = memScoped {
        val st = alloc<stat>()
        stat(abs, st.ptr) == 0 && (st.st_mode.toInt() and S_IFMT.toInt()) == S_IFDIR.toInt()
    }

    override fun readBytes(path: String): ByteArray {
        val fd = open(p(path), O_RDONLY)
        if (fd < 0) fail("open", path)
        try {
            var buf = ByteArray(maxOf(64, size(path).toInt()))
            var n = 0
            while (true) {
                if (n == buf.size) buf = buf.copyOf(buf.size * 2)
                val r = buf.usePinned { read(fd, it.addressOf(n), (buf.size - n).convert()) }.toInt()
                if (r < 0) { if (errno == EINTR) continue; fail("read", path) }
                if (r == 0) break
                n += r
            }
            return buf.copyOf(n)
        } finally {
            close(fd)
        }
    }

    override fun size(path: String): Long = memScoped {
        val st = alloc<stat>()
        if (stat(p(path), st.ptr) != 0) fail("stat", path)
        st.st_size
    }

    override fun lastModifiedMs(path: String): Long? = memScoped {
        val st = alloc<stat>()
        if (stat(p(path), st.ptr) != 0) null
        else st.st_mtimespec.tv_sec * 1000 + st.st_mtimespec.tv_nsec / 1_000_000
    }

    private fun writeAll(fd: Int, bytes: ByteArray, path: String) {
        var off = 0
        while (off < bytes.size) {
            val r = bytes.usePinned { write(fd, it.addressOf(off), (bytes.size - off).convert()) }.toInt()
            if (r < 0) { if (errno == EINTR) continue; fail("write", path) }
            off += r
        }
    }

    private fun fullFsync(fd: Int, path: String) {
        if (fcntl(fd, F_FULLFSYNC) == 0) return
        if (fsync(fd) != 0) fail("fsync", path)
    }

    override fun openAppend(path: String): FileSystem.Appender {
        val fd = open(p(path), O_WRONLY or O_CREAT or O_APPEND, 0x1a4) // 0644
        if (fd < 0) fail("open", path)
        return object : FileSystem.Appender {
            override fun write(bytes: ByteArray) = writeAll(fd, bytes, path)

            // write(2) goes straight to the kernel; no user-space buffer to push.
            override fun flush() = Unit
            override fun fsync() = fullFsync(fd, path)
            override fun close() {
                platform.posix.close(fd)
            }
        }
    }

    override fun writeBytes(path: String, bytes: ByteArray) {
        val fd = open(p(path), O_WRONLY or O_CREAT or O_TRUNC, 0x1a4)
        if (fd < 0) fail("open", path)
        try { writeAll(fd, bytes, path) } finally { close(fd) }
    }

    override fun fsyncFile(path: String) {
        val fd = open(p(path), O_WRONLY)
        if (fd < 0) fail("open", path)
        try { fullFsync(fd, path) } finally { close(fd) }
    }

    override fun fsyncDir(dir: String) {
        // Best effort, as on the JVM: APFS orders the rename's metadata anyway.
        val fd = open(p(dir), O_RDONLY)
        if (fd < 0) return
        try { if (fcntl(fd, F_FULLFSYNC) != 0) fsync(fd) } finally { close(fd) }
    }

    override fun truncate(path: String, size: Long) {
        val fd = open(p(path), O_WRONLY)
        if (fd < 0) fail("open", path)
        try {
            if (ftruncate(fd, size) != 0) fail("ftruncate", path)
            fullFsync(fd, path)
        } finally {
            close(fd)
        }
    }

    override fun rename(from: String, to: String) {
        if (platform.posix.rename(p(from), p(to)) != 0) fail("rename", from)
    }

    override fun delete(path: String) {
        if (unlink(p(path)) != 0 && errno != ENOENT) {
            if (rmdir(p(path)) != 0) fail("delete", path)
        }
    }

    override fun deleteRecursively(path: String) {
        if (!exists(path)) return
        if (isDirectory(path)) {
            for (child in list(path)) deleteRecursively("$path/$child")
            if (rmdir(p(path)) != 0) fail("rmdir", path)
        } else {
            delete(path)
        }
    }
}
