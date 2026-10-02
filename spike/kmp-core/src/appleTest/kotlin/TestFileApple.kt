@file:OptIn(ExperimentalForeignApi::class)

package app.runsolo.core.testio

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.pointed
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.F_OK
import platform.posix.SEEK_END
import platform.posix.SEEK_SET
import platform.posix.access
import platform.posix.closedir
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fread
import platform.posix.fseek
import platform.posix.ftell
import platform.posix.fwrite
import platform.posix.mkdir
import platform.posix.opendir
import platform.posix.readdir

actual fun testFileExists(abs: String) = access(abs, F_OK) == 0

actual fun testReadBytes(abs: String): ByteArray {
    val f = fopen(abs, "rb") ?: error("cannot open $abs")
    try {
        fseek(f, 0, SEEK_END)
        val n = ftell(f).toInt()
        fseek(f, 0, SEEK_SET)
        val buf = ByteArray(n)
        if (n > 0) buf.usePinned { fread(it.addressOf(0), 1u, n.convert(), f) }
        return buf
    } finally {
        fclose(f)
    }
}

actual fun testWriteBytes(abs: String, bytes: ByteArray) {
    val f = fopen(abs, "wb") ?: error("cannot open $abs")
    try {
        if (bytes.isNotEmpty()) bytes.usePinned { fwrite(it.addressOf(0), 1u, bytes.size.convert(), f) }
    } finally {
        fclose(f)
    }
}

actual fun testMkdirs(abs: String): Boolean {
    var p = ""
    for (part in abs.split('/').filter { it.isNotEmpty() }) {
        p += "/$part"
        mkdir(p, 0x1ed.convert()) // 0755; EEXIST ignored
    }
    return testFileExists(abs)
}

actual fun testList(abs: String): List<String>? {
    val d = opendir(abs) ?: return null
    try {
        val out = ArrayList<String>()
        while (true) {
            val e = readdir(d) ?: break
            val n = e.pointed.d_name.toKString()
            if (n != "." && n != "..") out.add(n)
        }
        return out
    } finally {
        closedir(d)
    }
}

@OptIn(kotlin.experimental.ExperimentalNativeApi::class)
actual val TEST_PLATFORM: String = "${Platform.osFamily.name.lowercase()}-${Platform.cpuArchitecture.name.lowercase()}" +
    (if (platform.Foundation.NSProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != null) "-simulator" else "")
