package app.runsolo.core.journal

import app.runsolo.core.json.Json
import app.runsolo.core.model.LapSource
import app.runsolo.core.model.LiveBoard
import app.runsolo.core.model.LiveBoardKind
import app.runsolo.core.model.LiveContext
import app.runsolo.core.model.LiveEntry
import app.runsolo.core.model.LiveTarget
import app.runsolo.core.model.NudgePlan
import app.runsolo.core.model.RunMode
import app.runsolo.core.model.SessionSpec
import app.runsolo.core.model.Units
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Phase 4 LC1: the `lctx` and `cf` journal lines (BLOCK-1) and the LiveContext contract. */
class LiveContextJournalTest {
    private val t0 = 100_000L
    private val w0 = 1_700_000_000_000L
    private val header = JournalLine.Header(t0, w0, "id1", "dev", "app", "UTC", RunMode.free, null, Units.km)

    private fun enc(vararg lines: JournalLine) = lines.joinToString("") { JournalCodec.encode(it) + "\n" }

    private fun sample(t: Long) = JournalLine.Sample(t, w0 + (t - t0), 1.0, 2.0, null, 5.0, 3.0, null)

    private fun entry(id: String, splits: List<Long>, final: Double) =
        LiveEntry(runId = id, dateMs = w0 - 86_400_000L, fromStartSplitsMs = splits, finalMetric = final)

    /** A full context: 3 boards (distance, intervals with an unclean rep, Cooper), target, stub, Cooper fields. */
    private val context = LiveContext(
        boards = listOf(
            LiveBoard(
                key = "be:5k",
                label = "5K",
                kind = LiveBoardKind.distance,
                targetM = 5000.0,
                entries = listOf(
                    entry("a", listOf(290_000L, 585_000L, 880_000L, 1_175_000L, 1_470_000L), 1_470_000.0),
                    entry("b", listOf(300_000L, 600_000L, 905_000L, 1_210_000L, 1_512_000L), 1_512_000.0),
                ),
            ),
            LiveBoard(
                key = "d400x8",
                label = "8 × 400 m",
                kind = LiveBoardKind.intervals,
                entries = listOf(
                    LiveEntry("c", w0, liveRepPacesSecPerKm = listOf(230.5, null, 232.0), finalMetric = 231.2),
                ),
            ),
            LiveBoard(
                key = "cooper",
                label = "12-minute test",
                kind = LiveBoardKind.cooper,
                entries = listOf(
                    LiveEntry("d", w0, cooperMinuteM = (1..12).map { it * 233.0 }, finalMetric = 51.3),
                ),
            ),
        ),
        target = LiveTarget(distanceM = 5000.0, targetMs = 1_470_000L, predicted = true),
        nudges = NudgePlan(),
        cooperCurve = listOf(0.0884, 0.1717, 0.2548, 0.3378, 0.4206, 0.5032, 0.5856, 0.6678, 0.7498, 0.8317, 0.9133, 1.0),
        cooperHistory = listOf(49.4, 51.3),
        coachingMuted = false,
        builtAtMs = w0,
        engineVersion = 3,
    )

    @Test
    fun `live context and cue fired lines round trip`() {
        val lines = listOf(
            JournalLine.LiveContextLine(t0, w0, context),
            JournalLine.CueFired(t0 + 900_000, w0 + 900_000, JournalLine.FiredKind.compare, "be:5k", 3, 880_500),
            JournalLine.CueFired(t0 + 901_000, w0 + 901_000, JournalLine.FiredKind.nudge, "fade", 3, 881_000),
        )
        for (line in lines) assertEquals(line, JournalCodec.decode(JournalCodec.encode(line)))
    }

    @Test
    fun `line formats are pinned`() {
        val cf = JournalCodec.encode(JournalLine.CueFired(5, 6, JournalLine.FiredKind.compare, "be:5k", 3, 880_500))
        assertEquals("""{"k":"cf","t":5,"w":6,"kind":"compare","key":"be:5k","i":3,"at":880500}""", cf)
        val lctx = Json.parseObject(JournalCodec.encode(JournalLine.LiveContextLine(5, 6, context)))
        assertEquals(listOf("k", "t", "w", "ctx"), lctx.keys.toList())
        assertEquals("lctx", lctx["k"])
        @Suppress("UNCHECKED_CAST")
        val ctx = lctx["ctx"] as Map<String, Any?>
        assertEquals(
            listOf("boards", "target", "nudges", "cooperCurve", "cooperHistory", "coachingMuted", "builtAtMs", "engineVersion"),
            ctx.keys.toList(),
        )
    }

    @Test
    fun `a full context stays a few KB`() {
        val full = context.copy(
            boards = List(3) { b ->
                LiveBoard(
                    key = "be:10k$b", label = "10K", kind = LiveBoardKind.distance, targetM = 10_000.0,
                    entries = List(LiveContext.MAX_ENTRIES) { i ->
                        entry("run-$b-$i-0123456789abcdef", List(10) { k -> (k + 1) * 300_000L + i }, 3_000_000.0 + i)
                    },
                )
            },
        )
        val bytes = JournalCodec.encode(JournalLine.LiveContextLine(t0, w0, full)).length
        assertTrue(bytes < 16_000, "lctx line is $bytes bytes")
    }

    @Test
    fun `replay keeps the context and fired cues aside, the run timeline is unchanged`() {
        val plain = JournalReplay.read(enc(header, sample(t0 + 1000), JournalLine.Lap(t0 + 2000, w0 + 2000, LapSource.button)).toByteArray())
        val withLive = JournalReplay.read(
            enc(
                header,
                JournalLine.LiveContextLine(t0, w0, context),
                sample(t0 + 1000),
                JournalLine.CueFired(t0 + 1000, w0 + 1000, JournalLine.FiredKind.compare, "be:5k", 1, 1000),
                JournalLine.Lap(t0 + 2000, w0 + 2000, LapSource.button),
            ).toByteArray(),
        )
        assertEquals(plain.events, withLive.events)
        assertEquals(plain.endT, withLive.endT)
        assertEquals(0, withLive.badLines)
        assertEquals(context, withLive.liveContext)
        assertEquals(listOf("be:5k"), withLive.cuesFired.map { it.key })
    }

    @Test
    fun `no live_context line (older build or null context) restores silent`() {
        val r = JournalReplay.read(enc(header, sample(t0 + 1000)).toByteArray())
        assertNull(r.liveContext)
        assertTrue(r.cuesFired.isEmpty())
    }

    @Test
    fun `a corrupt live_context line is dropped and counted, the run survives`() {
        val bad = """{"k":"lctx","t":$t0,"w":$w0,"ctx":{"boards":"nope"}}""" + "\n"
        val r = JournalReplay.read((enc(header) + bad + enc(sample(t0 + 1000))).toByteArray())
        assertNull(r.liveContext)
        assertEquals(1, r.badLines)
        assertEquals(1, r.events.size)
    }

    @Test
    fun `last Cooper VO2 is the newest history entry`() {
        assertEquals(51.3, context.lastCooperVo2)
        assertNull(context.copy(cooperHistory = null).lastCooperVo2)
    }

    @Test
    fun `contract limits are enforced`() {
        val b = context.boards.first()
        assertFailsWith<IllegalArgumentException> { context.copy(boards = List(4) { b }) }
        assertFailsWith<IllegalArgumentException> {
            b.copy(entries = List(LiveContext.MAX_ENTRIES + 1) { b.entries.first() })
        }
        assertFailsWith<IllegalArgumentException> {
            // A distance board entry without from-start splits.
            b.copy(entries = listOf(LiveEntry("x", w0, cooperMinuteM = listOf(1.0), finalMetric = 1.0)))
        }
        assertFailsWith<IllegalArgumentException> { context.copy(cooperCurve = listOf(0.5, 1.0)) }
    }

    @Test
    fun `a header with a session still round trips next to it`() {
        val h = header.copy(mode = RunMode.cooper, session = SessionSpec.COOPER)
        val r = JournalReplay.read(enc(h, JournalLine.LiveContextLine(t0, w0, context)).toByteArray())
        assertEquals(SessionSpec.COOPER, r.header.session)
        assertEquals(context, r.liveContext)
    }
}
