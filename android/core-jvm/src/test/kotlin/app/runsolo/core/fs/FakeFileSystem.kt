package app.runsolo.core.fs

/**
 * In-memory [FileSystem] with two failure models:
 *
 *  - **Process kill**: set [crashBefore] to an operation name (`writeBytes`, `fsyncFile`,
 *    `rename`, `fsyncDir`, `deleteRecursively`, `delete`, `truncate`) and the next call of that
 *    operation throws [Crash] before doing anything; everything written so far stays.
 *  - **Power loss**: [powerLoss] discards whatever was not made durable — file bytes not yet
 *    fsynced (a file created but never synced comes back zero-length), directory entries
 *    (creates, renames, deletes) not followed by `fsyncDir` of that directory. Appender
 *    `write()` is volatile until `fsync()`; `writeBytes` until `fsyncFile`.
 *
 * Operation names are recorded in [ops].
 */
class FakeFileSystem : FileSystem {
    class Crash(op: String) : RuntimeException("simulated kill before $op")

    /** Volatile (page-cache) view: what a running process sees. */
    private val files = LinkedHashMap<String, ByteArray>()
    private val dirs = LinkedHashSet<String>()
    private val mtimes = HashMap<String, Long>()

    /** Durable view: content by inode (identity survives renames), and names per directory. */
    private class Inode(var synced: ByteArray)
    private val inodes = HashMap<String, Inode>() // volatile path → inode
    private val durableNames = HashMap<String, MutableMap<String, Inode>>() // dir → name → inode

    val ops = ArrayList<String>()
    var crashBefore: String? = null
    var failAppendWrites = false
    var fsyncCount = 0
    var clock: Long = 1_700_000_000_000L

    private fun op(name: String) {
        ops.add(name)
        if (crashBefore == name) {
            crashBefore = null
            throw Crash(name)
        }
    }

    private fun ensureParent(path: String) {
        val parent = path.parentPath() ?: return
        check(parent in dirs) { "parent directory missing: $parent (for $path)" }
    }

    fun snapshotPaths(): List<String> = files.keys.sorted()

    /** Lose everything not durable. */
    fun powerLoss() {
        val survivors = LinkedHashMap<String, ByteArray>()
        for ((dir, names) in durableNames) {
            for ((name, inode) in names) survivors["$dir/$name"] = inode.synced.copyOf()
        }
        files.clear()
        files.putAll(survivors)
        inodes.clear()
        for ((dir, names) in durableNames) for ((name, inode) in names) inodes["$dir/$name"] = inode
        // Directories themselves: keep those that were fsynced or hold durable files.
        val keep = LinkedHashSet<String>()
        for (d in durableNames.keys) {
            val parts = d.split('/')
            for (i in 1..parts.size) keep.add(parts.subList(0, i).joinToString("/"))
        }
        dirs.retainAll(keep)
        dirs.addAll(keep)
    }

    override fun exists(path: String) = path in files || path in dirs
    override fun isDirectory(path: String) = path in dirs

    override fun list(dir: String): List<String> {
        if (dir !in dirs) return emptyList()
        val prefix = "$dir/"
        val names = LinkedHashSet<String>()
        for (p in files.keys + dirs) {
            if (p.startsWith(prefix)) names.add(p.removePrefix(prefix).substringBefore('/'))
        }
        return names.sorted()
    }

    override fun mkdirs(dir: String) {
        val parts = dir.split('/')
        for (i in 1..parts.size) dirs.add(parts.subList(0, i).joinToString("/"))
    }

    override fun readBytes(path: String): ByteArray = files[path] ?: throw java.io.FileNotFoundException(path)
    override fun size(path: String): Long = readBytes(path).size.toLong()
    override fun lastModifiedMs(path: String): Long? = mtimes[path]

    private fun inodeFor(path: String): Inode = inodes.getOrPut(path) { Inode(ByteArray(0)) }

    override fun openAppend(path: String): FileSystem.Appender {
        ensureParent(path)
        files.putIfAbsent(path, ByteArray(0))
        inodeFor(path)
        return object : FileSystem.Appender {
            override fun write(bytes: ByteArray) {
                if (failAppendWrites) throw java.io.IOException("ENOSPC")
                files[path] = files[path]!! + bytes
                mtimes[path] = clock
            }

            override fun flush() = Unit
            override fun fsync() {
                fsyncCount++
                inodeFor(path).synced = files[path]!!.copyOf()
            }

            override fun close() = Unit
        }
    }

    override fun writeBytes(path: String, bytes: ByteArray) {
        op("writeBytes")
        ensureParent(path)
        files[path] = bytes.copyOf()
        mtimes[path] = clock
        inodeFor(path)
    }

    override fun fsyncFile(path: String) {
        op("fsyncFile")
        check(path in files)
        inodeFor(path).synced = files[path]!!.copyOf()
    }

    override fun fsyncDir(dir: String) {
        op("fsyncDir")
        val names = durableNames.getOrPut(dir) { LinkedHashMap() }
        names.clear()
        for (p in files.keys) if (p.parentPath() == dir) names[p.fileName()] = inodeFor(p)
    }

    override fun truncate(path: String, size: Long) {
        op("truncate")
        val b = files[path] ?: throw java.io.FileNotFoundException(path)
        files[path] = b.copyOf(size.toInt())
        inodeFor(path).synced = files[path]!!.copyOf() // JvmFileSystem forces after truncate
    }

    override fun rename(from: String, to: String) {
        op("rename")
        val b = files.remove(from) ?: throw java.io.FileNotFoundException(from)
        ensureParent(to)
        files[to] = b
        mtimes[to] = mtimes.remove(from) ?: clock
        inodes.remove(from)?.let { inodes[to] = it }
    }

    override fun delete(path: String) {
        op("delete")
        files.remove(path)
        inodes.remove(path)
    }

    override fun deleteRecursively(path: String) {
        op("deleteRecursively")
        files.keys.removeIf { it == path || it.startsWith("$path/") }
        inodes.keys.removeIf { it == path || it.startsWith("$path/") }
        dirs.removeIf { it == path || it.startsWith("$path/") }
    }
}
