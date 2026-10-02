package app.runsolo.core.fs

import app.runsolo.core.contract.ContractFixtures
import app.runsolo.core.json.Json
import app.runsolo.core.run.RunPaths
import app.runsolo.core.spike.RunCoreFacade
import app.runsolo.core.testio.File
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** K0: the real pipeline on a real Apple file system (journal appends with F_FULLFSYNC, rename, gzip). */
class AppleFileSystemTest {
    private fun tmp() = NSTemporaryDirectory().trimEnd('/') + "/k0-" + NSUUID().UUIDString

    @Test
    fun replay4x4OnDiskMatchesTheJvmFixture() {
        val root = tmp()
        val json = RunCoreFacade().replayRunFileJson("4x4", root)
        assertEquals(Json.parse(File(ContractFixtures.DIR, "replay_4x4.json").readText()), Json.parse(json))
        val fs = AppleFileSystem(root)
        assertTrue(fs.exists(RunPaths.runFile("replay-4x4")))
        fs.deleteRecursively("runs")
        assertFalse(fs.exists("runs"))
    }

    @Test
    fun appendTruncateRenameList() {
        val fs = AppleFileSystem(tmp())
        fs.mkdirs("a/b")
        assertTrue(fs.isDirectory("a/b"))
        fs.openAppend("a/b/j").use { it.write("hello\n".encodeToByteArray()); it.fsync(); it.write("tail".encodeToByteArray()) }
        assertEquals(10L, fs.size("a/b/j"))
        fs.truncate("a/b/j", 6)
        assertContentEquals("hello\n".encodeToByteArray(), fs.readBytes("a/b/j"))
        fs.writeBytes("a/b/k.tmp", byteArrayOf(1, 2, 3))
        fs.fsyncFile("a/b/k.tmp")
        fs.rename("a/b/k.tmp", "a/b/k")
        fs.fsyncDir("a/b")
        assertEquals(listOf("j", "k"), fs.list("a/b"))
        assertTrue(fs.lastModifiedMs("a/b/k")!! > 1_600_000_000_000L)
        assertFailsWith<app.runsolo.core.platform.FileNotFoundException> { fs.readBytes("a/b/missing") }
        fs.delete("a/b/missing")
        fs.deleteRecursively("a")
        assertFalse(fs.exists("a"))
    }
}
