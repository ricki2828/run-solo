package app.runsolo.core.testio

/**
 * The slice of java.io.File the core-jvm tests use, so they compile for Native. Relative paths
 * resolve against android/core-jvm (the JVM tests' working directory); [CORE_JVM_DIR] is written
 * by port.py.
 */
class File(val path: String) {
    constructor(dir: String, name: String) : this("$dir/$name")
    constructor(dir: File, name: String) : this("${dir.path}/$name")

    val name: String get() = path.substringAfterLast('/')
    val nameWithoutExtension: String get() = name.substringBeforeLast('.')
    val parentFile: File get() = File(path.substringBeforeLast('/', "."))
    private val abs: String get() = if (path.startsWith("/")) path else "$CORE_JVM_DIR/$path"

    fun exists(): Boolean = testFileExists(abs)
    fun readText(): String = testReadBytes(abs).decodeToString()
    fun writeText(text: String) = testWriteBytes(abs, text.encodeToByteArray())
    fun mkdirs(): Boolean = testMkdirs(abs)

    /** Like java.io.File: directories included, null when not a directory. */
    fun listFiles(): Array<File>? = testList(abs)?.map { File(this, it) }?.toTypedArray()
    fun listFiles(filter: (File) -> Boolean): Array<File>? = listFiles()?.filter(filter)?.toTypedArray()

    override fun toString() = path
}

expect fun testFileExists(abs: String): Boolean
expect fun testReadBytes(abs: String): ByteArray
expect fun testWriteBytes(abs: String, bytes: ByteArray)
expect fun testMkdirs(abs: String): Boolean
expect fun testList(abs: String): List<String>?

expect val TEST_PLATFORM: String
