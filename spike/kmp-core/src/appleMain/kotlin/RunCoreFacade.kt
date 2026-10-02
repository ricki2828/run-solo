package app.runsolo.core.spike

import app.runsolo.core.fs.AppleFileSystem
import app.runsolo.core.json.Json
import app.runsolo.core.replay.ReplayScenarios

/**
 * The Swift-facing surface for the K0 spike: plain String/Int/List in and out (no Kotlin boxed
 * types, no sealed classes). Call from one serial queue.
 */
class RunCoreFacade {
    fun replayKinds(): List<String> = ReplayScenarios.KINDS

    /** Records replay [kind] through the real core into [rootDir] (created) and returns the run file JSON. */
    @Throws(Exception::class)
    fun replayRunFileJson(kind: String, rootDir: String): String {
        val fs = AppleFileSystem(rootDir)
        return SpikeReplay.runFileJson(kind, fs)
    }

    /** Re-serialises [json] through core's own codec (round trip check from Swift). */
    fun normaliseJson(json: String): String = Json.write(Json.parse(json))
}
