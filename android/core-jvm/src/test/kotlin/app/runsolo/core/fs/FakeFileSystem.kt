package app.runsolo.core.fs

/**
 * In-memory [FileSystem] with crash injection: set [crashBefore] to an operation name
 * (`writeBytes`, `fsyncFile`, `rename`, `fsyncDir`, `deleteRecursively`, `delete`) and the next
 * call of that operation throws [Crash] before doing anything, leaving "disk" exactly as a
 * process kill at that boundary would. Operation names are also recorded in [ops].
 */
class FakeFileSystem : FileSystem {
    class Crash(op: String) : RuntimeException("simulated kill before $op")

    private val files = LinkedHashMap<String, ByteArray>()
    private val dirs = LinkedHashSet<String>()
    private val mtimes = HashMap<String, Long>()
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

    override fun openAppend(path: String): FileSystem.Appender {
        ensureParent(path)
        files.putIfAbsent(path, ByteArray(0))
        return object : FileSystem.Appender {
            override fun write(bytes: ByteArray) {
                if (failAppendWrites) throw java.io.IOException("ENOSPC")
                files[path] = files[path]!! + bytes
                mtimes[path] = clock
            }

            override fun flush() = Unit
            override fun fsync() {
                fsyncCount++
            }

            override fun close() = Unit
        }
    }

    override fun writeBytes(path: String, bytes: ByteArray) {
        op("writeBytes")
        ensureParent(path)
        files[path] = bytes.copyOf()
        mtimes[path] = clock
    }

    override fun fsyncFile(path: String) {
        op("fsyncFile")
        check(path in files)
    }

    override fun fsyncDir(dir: String) {
        op("fsyncDir")
    }

    override fun rename(from: String, to: String) {
        op("rename")
        val b = files.remove(from) ?: throw java.io.FileNotFoundException(from)
        ensureParent(to)
        files[to] = b
        mtimes[to] = mtimes.remove(from) ?: clock
    }

    override fun delete(path: String) {
        op("delete")
        files.remove(path)
    }

    override fun deleteRecursively(path: String) {
        op("deleteRecursively")
        files.keys.removeIf { it == path || it.startsWith("$path/") }
        dirs.removeIf { it == path || it.startsWith("$path/") }
    }
}
