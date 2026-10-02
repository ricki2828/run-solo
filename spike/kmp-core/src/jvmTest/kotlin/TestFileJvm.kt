package app.runsolo.core.testio

actual fun testFileExists(abs: String) = java.io.File(abs).exists()
actual fun testReadBytes(abs: String) = java.io.File(abs).readBytes()
actual fun testWriteBytes(abs: String, bytes: ByteArray) = java.io.File(abs).writeBytes(bytes)
actual fun testMkdirs(abs: String) = java.io.File(abs).mkdirs()
actual fun testList(abs: String): List<String>? = java.io.File(abs).list()?.toList()
actual val TEST_PLATFORM: String = "jvm"
