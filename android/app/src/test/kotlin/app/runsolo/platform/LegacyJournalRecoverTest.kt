package app.runsolo.platform

import android.content.Context
import app.runsolo.core.fs.JvmFileSystem
import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * PR #9 review P1-1, through the real `RecorderApiImpl.recover()` on the real filesystem: a
 * Phase-1 journal (schema 1, mode free) under files/runs/<id>/ is migrated to files/journals/
 * and offered as a readable `laps` orphan.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LegacyJournalRecoverTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val fs = JvmFileSystem(context.filesDir.toPath())

    @Test
    fun `recover migrates a Phase-1 journal and lists it as laps`() {
        val id = "phase1-orphan"
        fs.mkdirs("${RunPaths.RUNS_DIR}/$id")
        val journal = """{"k":"hdr","schema":1,"t":1000,"w":1700000000000,"id":"$id","device":"Pixel 8","app":"0.1.0-debug","tz":"UTC","mode":"free","preset":null,"units":"km"}""" + "\n" +
            """{"k":"s","t":2000,"w":1700000001000,"lat":-33.8,"lon":151.2,"acc":5.0,"hr":150}""" + "\n" +
            """{"k":"lap","t":61000,"w":1700000060000,"src":"volumeKey"}""" + "\n"
        fs.writeBytes("${RunPaths.RUNS_DIR}/$id/${RunPaths.JOURNAL_NAME}", journal.toByteArray())

        val orphans = RecorderApiImpl(context).recover()

        assertEquals(listOf(id), orphans.map { it.runId })
        val o = orphans.single()
        assertTrue(o.readable)
        assertFalse(o.newer)
        assertEquals(RecordMode.LAPS, o.mode)
        assertEquals(60_000L, o.elapsedMs)
        assertTrue(fs.exists(RunPaths.journal(id)))
        assertFalse(fs.exists("${RunPaths.RUNS_DIR}/$id/${RunPaths.JOURNAL_NAME}"))
    }
}
