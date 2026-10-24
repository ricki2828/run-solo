package app.runsolo.core.watch

import app.runsolo.core.fs.FakeFileSystem
import app.runsolo.core.gps.Geo
import app.runsolo.core.json.Json
import app.runsolo.core.json.list
import app.runsolo.core.platform.decodeUtf8
import app.runsolo.core.platform.encodeUtf8
import app.runsolo.core.reconcile.IndexRow
import app.runsolo.core.reconcile.Reconciler
import app.runsolo.core.reconcile.RunFileRef
import app.runsolo.core.run.RunFile
import app.runsolo.core.run.RunPaths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WatchRunImporterTest {
    private val fs = FakeFileSystem()

    private fun bytes(body: Map<String, Any?>) = encodeUtf8(WatchRunPayload.sign(body))
    private fun import(body: Map<String, Any?>, on: FakeFileSystem = fs) = WatchRunImporter(on).import(bytes(body))
    private fun runFiles(on: FakeFileSystem = fs) = on.snapshotPaths().filter { it.endsWith(".json.gz") }

    private fun fixture() = WatchPayloadFixtures.fiveSecondTrack()
    private val id = "gw-5strack"
    private fun committed() = RunFile.readJson(fs.readBytes(RunPaths.runFile(id)))

    // ---- the ACK contract ----

    @Test
    fun `imports once then says already have`() {
        val first = import(fixture())
        assertEquals(WatchRunImporter.Result.Imported(id, RunPaths.runFile(id)), first)
        assertTrue(first.ack)
        val second = import(fixture())
        assertEquals(WatchRunImporter.Result.AlreadyHave(id), second)
        assertTrue(second.ack)
        assertEquals(listOf(RunPaths.runFile(id)), runFiles())
    }

    @Test
    fun `app killed between receiving the run and writing it - nothing committed and no ack so a rerun imports once`() {
        fs.crashBefore = "rename"
        assertFailsWith<FakeFileSystem.Crash> { import(fixture()) } // no Result: the caller cannot ACK
        assertFalse(fs.exists(RunPaths.runFile(id)), "no committed file")
        // The process restarts: a fresh importer over the same disk, the watch resends.
        val retry = import(fixture(), fs)
        assertIs<WatchRunImporter.Result.Imported>(retry)
        assertEquals(WatchRunImporter.Result.AlreadyHave(id), import(fixture()))
        assertEquals(listOf(RunPaths.runFile(id)), runFiles())
        assertFalse(fs.exists(RunPaths.runFileTmp(id)))
    }

    @Test
    fun `killed before the first byte is written - same story`() {
        fs.crashBefore = "writeBytes"
        assertFailsWith<FakeFileSystem.Crash> { import(fixture()) }
        assertTrue(runFiles().isEmpty())
        assertIs<WatchRunImporter.Result.Imported>(import(fixture()))
    }

    @Test
    fun `crash after the rename before the directory fsync - a retry completes and never makes two files`() {
        fs.crashBefore = "fsyncDir"
        assertFailsWith<FakeFileSystem.Crash> { import(fixture()) }
        // Process kill only: the rename is visible. The retry makes it durable before it ACKs.
        val retry = import(fixture())
        assertEquals(WatchRunImporter.Result.AlreadyHave(id), retry)
        fs.powerLoss()
        assertEquals(listOf(RunPaths.runFile(id)), runFiles(), "the retry's directory fsync made the entry durable")
        assertEquals(1, runFiles().size)
    }

    @Test
    fun `power loss after the rename before the directory fsync - the run is gone so the retry imports it again`() {
        fs.crashBefore = "fsyncDir"
        assertFailsWith<FakeFileSystem.Crash> { import(fixture()) }
        fs.powerLoss()
        assertTrue(runFiles().isEmpty(), "never ACKed, so nothing was lost")
        assertIs<WatchRunImporter.Result.Imported>(import(fixture()))
        assertEquals(1, runFiles().size)
    }

    @Test
    fun `an acked run survives power loss`() {
        assertTrue(import(fixture()).ack)
        fs.powerLoss()
        assertEquals(listOf(RunPaths.runFile(id)), runFiles())
        assertEquals("garmin:forerunner265", committed()["device"])
    }

    @Test
    fun `a leftover tmp from a crash is discarded and rebuilt`() {
        fs.mkdirs(RunPaths.RUNS_DIR)
        fs.writeBytes(RunPaths.runFileTmp(id), byteArrayOf(9, 9, 9))
        assertIs<WatchRunImporter.Result.Imported>(import(fixture()))
        assertFalse(fs.exists(RunPaths.runFileTmp(id)))
        assertEquals("garmin:forerunner265", committed()["device"]) // real content, not the junk
    }

    @Test
    fun `the same run id delivered twice or already archived is one file and an ack both times`() {
        assertTrue(import(fixture()).ack)
        assertTrue(import(fixture()).ack)
        assertEquals(1, runFiles().size)

        val other = FakeFileSystem()
        other.mkdirs(RunPaths.ARCHIVE_DIR)
        other.writeBytes(RunPaths.runFile(id, RunPaths.ARCHIVE_DIR), byteArrayOf(1))
        val r = import(fixture(), other)
        assertEquals(WatchRunImporter.Result.AlreadyHave(id), r)
        assertTrue(r.ack)
        assertFalse(other.exists(RunPaths.runFile(id)), "not rewritten into runs/")
        assertEquals(listOf(RunPaths.runFile(id, RunPaths.ARCHIVE_DIR)), runFiles(other))
    }

    @Test
    fun `a storage error is reported and never acked`() {
        val broke = object : app.runsolo.core.fs.FileSystem by fs {
            override fun writeBytes(path: String, bytes: ByteArray) = throw app.runsolo.core.platform.IOException("ENOSPC")
        }
        val r = WatchRunImporter(broke).import(bytes(fixture()))
        assertIs<WatchRunImporter.Result.Failed>(r)
        assertFalse(r.ack)
        assertTrue(runFiles().isEmpty())
    }

    // ---- rejection writes nothing ----

    private fun assertRejected(payload: ByteArray, why: String) {
        val before = fs.snapshotPaths()
        val r = WatchRunImporter(fs).import(payload)
        assertIs<WatchRunImporter.Result.Rejected>(r, why)
        assertFalse(r.ack, why)
        assertEquals(before, fs.snapshotPaths(), "$why: the file system is unchanged")
        assertTrue(fs.ops.none { it == "writeBytes" || it == "rename" }, why)
    }

    private fun mutated(f: (LinkedHashMap<String, Any?>) -> Unit): ByteArray = bytes(fixture().also(f))

    @Test
    fun `malformed truncated and tampered payloads are rejected with the file system untouched`() {
        assertRejected(encodeUtf8("not json at all"), "malformed")
        assertRejected(encodeUtf8("[1,2]"), "not an object")
        val good = bytes(fixture())
        assertRejected(good.copyOf(good.size / 2), "truncated")
        assertRejected(encodeUtf8(decodeUtf8(good).replace("forerunner265", "forerunner965")), "wrong hash")
        val noHash = LinkedHashMap(Json.parseObject(decodeUtf8(good))).also { it.remove("payloadHash") }
        assertRejected(encodeUtf8(Json.write(noHash)), "no hash")
        assertRejected(ByteArray(WatchRunPayload.MAX_BYTES + 1), "oversize")
    }

    @Test
    fun `invalid content is rejected even when the hash is right`() {
        assertRejected(mutated { it["v"] = 2 }, "unknown payload version")
        assertRejected(mutated { it["runId"] = "../escape" }, "unsafe run id")
        assertRejected(mutated { it["runId"] = "gw-é" }, "non-ascii run id the Dart reader would refuse")
        assertRejected(mutated { it["mode"] = "intervals" }, "mode other than free")
        assertRejected(mutated { it["endEpochMs"] = (it["startEpochMs"] as Long) - 1 }, "end before start")
        assertRejected(mutated { it["samples"] = (it["samples"] as List<*>).reversed() }, "samples descending in t")
        assertRejected(
            mutated {
                @Suppress("UNCHECKED_CAST")
                val s = (it["samples"] as List<List<Any?>>).toMutableList()
                s[10] = s[10].toMutableList().also { row -> row[6] = 1.0 } // distance falls back
                it["samples"] = s
            },
            "distM decreasing",
        )
        assertRejected(mutated { it["rateChanges"] = listOf(listOf(5000L, 5L)) }, "rateChanges not starting at 0")
        assertRejected(mutated { it["rateChanges"] = listOf(listOf(0L, 5L), listOf(900_000L, 1L), listOf(300_000L, 0L)) }, "rateChanges descending")
        assertRejected(mutated { it["rateChanges"] = listOf(listOf(0L, -1L)) }, "negative rate")
        assertRejected(mutated { it["rateChanges"] = emptyList<Any?>() }, "no rateChanges")
        assertRejected(
            mutated { it["laps"] = listOf(linkedMapOf("i" to 0, "t0" to 0, "t1" to 9_999_999, "d0" to 0, "d1" to 5, "kind" to "manual")) },
            "lap beyond the run",
        )
        assertRejected(mutated { it["coach"] = linkedMapOf("surprise" to 1) }, "unknown coach key")
        assertRejected(mutated { it["samples"] = listOf(listOf(0L, 1.0, null, null, null, null, 0, null)) }, "lat without lon")
    }

    // ---- the watch is the source of truth ----

    @Test
    fun `distance and splits are the watch's as sent - a tight curve is not shortened`() {
        // A 5 s track on a 25 m circle at 3 m/s: each 15 m step is a chord, so a lat/lon sum reads ~2% short.
        val end = 120_000L
        val samples = (0..end step 5_000).map { t ->
            val d = 3.0 * t / 1000.0
            val f = WatchPayloadFixtures.fix(d, radiusM = 25.0)
            listOf(t, f[0], f[1], null, 4.0, 3.0, d, null)
        }
        val body = fixture().also {
            it["endEpochMs"] = (it["startEpochMs"] as Long) + end
            it["samples"] = samples
            it["laps"] = listOf(linkedMapOf("i" to 0, "t0" to 0, "t1" to end, "d0" to 0.0, "d1" to 360.0, "kind" to "manual"))
        }
        assertIs<WatchRunImporter.Result.Imported>(import(body))
        val rows = committed().list("samples").map { it as List<*> }
        assertEquals(360.0, (rows.last()[6] as Number).toDouble())
        var path = 0.0
        for (i in 1 until rows.size) path += Geo.haversineM(rows[i - 1][1] as Double, rows[i - 1][2] as Double, rows[i][1] as Double, rows[i][2] as Double)
        assertTrue(path < 358.0, "the track alone reads short ($path m), so the watch's figure must win")
        val lap = committed().list("laps").single() as Map<*, *>
        assertEquals(360.0, (lap["d1"] as Number).toDouble())
        assertEquals(0.0, (lap["d0"] as Number).toDouble())
    }

    @Test
    fun `a thinned track is marked by two rate changes and keeps the watch's closing distance`() {
        assertIs<WatchRunImporter.Result.Imported>(import(WatchPayloadFixtures.thinned()))
        val m = RunFile.readJson(fs.readBytes(RunPaths.runFile("gw-thinned")))
        val watch = m["watch"] as Map<*, *>
        assertEquals(listOf(listOf(0L, 5L), listOf(360_000L, 0L)), watch["rateChanges"])
        assertEquals("forerunner265", watch["model"])
        val last = m.list("samples").last() as List<*>
        assertEquals(600_000L, last[0])
        assertNull(last[1]) // no fix after the cutoff
        assertEquals(1800.0, (last[6] as Number).toDouble())
        assertTrue(RunFile.WatchInfo("m", listOf(0L to 5, 360_000L to 0)).trackThinned)
        assertFalse(RunFile.WatchInfo("m", listOf(0L to 5)).trackThinned)
    }

    @Test
    fun `two-step degrade round-trips through the writer - three entries as sent`() {
        assertIs<WatchRunImporter.Result.Imported>(import(WatchPayloadFixtures.twoStepDegrade()))
        val m = RunFile.readJson(fs.readBytes(RunPaths.runFile("gw-degrade2")))
        assertEquals(
            listOf(listOf(0L, 5L), listOf(240_000L, 10L), listOf(420_000L, 0L)),
            (m["watch"] as Map<*, *>)["rateChanges"],
        )
    }

    @Test
    fun `the imported file is a schema 8 free run with the watch block and the device model`() {
        import(WatchPayloadFixtures.thinned())
        val m = RunFile.readJson(fs.readBytes(RunPaths.runFile("gw-thinned")))
        assertEquals(8L, m["schema"])
        assertEquals("free", m["mode"])
        assertEquals("garmin:forerunner265", m["device"])
        assertEquals("garmin-watch/0.1.0", m["app"])
        assertNull(m["session"])
        assertFalse(m.containsKey("elev_src"))
        assertFalse(m.containsKey("route"))
        val coach = m["coach"] as Map<*, *>
        assertEquals("chase", coach["choice"])
        assertEquals(listOf(listOf("ahead", 1L, 333_000L)), coach["cues"])
    }

    @Test
    fun `a phone-recorded run has no watch key`() {
        val file = WatchRunImporter.toRunFile(WatchRunPayload.parse(decodeUtf8(bytes(fixture())))).copy(watch = null)
        assertFalse(file.toJson().containsKey("watch"))
    }

    // ---- the reconciler ----

    @Test
    fun `the reconciler indexes an imported run for a store that has no row`() {
        import(fixture())
        val plan = Reconciler(fs).reconcile(emptyList<IndexRow>())
        assertEquals(listOf(RunFileRef(id, RunPaths.runFile(id))), plan.index)
    }
}
