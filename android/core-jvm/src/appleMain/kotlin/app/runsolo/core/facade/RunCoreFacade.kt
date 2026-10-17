package app.runsolo.core.facade

import app.runsolo.core.CoreVersion
import app.runsolo.core.fs.AppleFileSystem
import app.runsolo.core.json.Json
import app.runsolo.core.replay.ReplayRun
import app.runsolo.core.replay.ReplayScenarios

/**
 * The Swift-facing surface of the XCFramework (iOS plan §2.2 K3): String / Int / List in and out,
 * no Kotlin boxed numbers or sealed classes. Swift wraps it in `RunCore` (ios/Runner/RunCore).
 * Call from one serial queue only; the core is not thread-safe.
 */
class RunCoreFacade {
    fun coreVersion(): String = CoreVersion.VERSION

    fun replayKinds(): List<String> = ReplayScenarios.KINDS

    /** Records replay [kind] through the real core into [rootDir] (created) and returns the run file JSON. */
    @Throws(Exception::class)
    fun replayRunFileJson(kind: String, rootDir: String): String =
        ReplayRun.runFileJson(kind, AppleFileSystem(rootDir))

    /** Re-serialises [json] through core's own codec (round-trip check from Swift). */
    @Throws(Exception::class)
    fun normaliseJson(json: String): String = Json.write(Json.parse(json))
}
