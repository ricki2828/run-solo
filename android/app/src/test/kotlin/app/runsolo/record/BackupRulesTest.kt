package app.runsolo.record

import app.runsolo.core.run.RunPaths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Plan §4 W3: minSdk 29 needs BOTH rules files, each backing up the index, `runs/` and
 * `state/` and excluding in-progress journals, the overflow archive and the SQLite side
 * files. Parsed from the source tree (the Gradle working directory is `android/app`).
 */
class BackupRulesTest {
    private fun xml(name: String): Element {
        val f = listOf("src/main/res/xml/$name", "android/app/src/main/res/xml/$name").map(::File).first { it.exists() }
        return DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(f).documentElement
    }

    private fun rules(parent: Element, tag: String): Set<String> {
        val out = HashSet<String>()
        val nodes = parent.getElementsByTagName(tag)
        for (i in 0 until nodes.length) {
            val e = nodes.item(i) as Element
            out.add("${e.getAttribute("domain")}:${e.getAttribute("path")}")
        }
        return out
    }

    private val expectedIncludes = setOf("database:runsolo.db", "file:${RunPaths.RUNS_DIR}/", "file:state/")
    private val expectedExcludes = setOf(
        "database:runsolo.db-wal", "database:runsolo.db-shm", "database:runsolo.db-journal",
        "file:${RunPaths.JOURNALS_DIR}/", "file:${RunPaths.ARCHIVE_DIR}/",
    )

    @Test
    fun `fullBackupContent (API 29-30) includes db, runs, state and excludes journals, archive, wal`() {
        val root = xml("backup_rules.xml")
        assertEquals("full-backup-content", root.tagName)
        assertEquals(expectedIncludes, rules(root, "include"))
        assertEquals(expectedExcludes, rules(root, "exclude"))
    }

    @Test
    fun `dataExtractionRules (API 31+) has the same set for cloud backup and device transfer`() {
        val root = xml("data_extraction_rules.xml")
        assertEquals("data-extraction-rules", root.tagName)
        for (section in listOf("cloud-backup", "device-transfer")) {
            val e = root.getElementsByTagName(section).item(0) as Element
            assertEquals(section, expectedIncludes, rules(e, "include"))
            assertEquals(section, expectedExcludes, rules(e, "exclude"))
        }
    }

    @Test
    fun `manifest wires both rules files and keeps backup on`() {
        val f = listOf("src/main/AndroidManifest.xml", "android/app/src/main/AndroidManifest.xml").map(::File).first { it.exists() }
        val app = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(f).documentElement.getElementsByTagName("application").item(0) as Element
        // The default parser is not namespace-aware, so read the prefixed attribute names as written.
        assertEquals("true", app.getAttribute("android:allowBackup"))
        assertEquals("@xml/backup_rules", app.getAttribute("android:fullBackupContent"))
        assertEquals("@xml/data_extraction_rules", app.getAttribute("android:dataExtractionRules"))
    }

    @Test
    fun `journals live outside runs so a static exclude covers every in-progress run`() {
        assertTrue(RunPaths.journal("abc").startsWith("${RunPaths.JOURNALS_DIR}/"))
        assertTrue(!RunPaths.journal("abc").startsWith("${RunPaths.RUNS_DIR}/"))
    }
}
