package app.runsolo.core.testio

/**
 * The slice of java.io.File the core tests use, so they compile for Native. Relative paths
 * resolve against android/core-jvm (the JVM tests' working directory); [CORE_JVM_DIR] is written
 * by the build (build.gradle.kts, writeTestPaths) because a Native test binary, and the iOS
 * simulator above all, does not run there.
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

/**
 * java.util.Random's generator (the elevation test's noise). JVM: the class itself; Apple: the
 * same LCG and polar method, so the seeded sequence matches up to the last ulp of log/sqrt.
 */
expect class JavaRandom(seed: Long) {
    fun nextGaussian(): Double
}
