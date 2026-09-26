package app.runsolo.core.contract

import java.io.File

/**
 * Every generated fixture, written into core-jvm and the run_engine copy in one go:
 * `./gradlew regenerateFixtures` from `android/core-jvm`. Fixtures are never hand-edited; the
 * CI core-jvm job runs this and uploads the result as the `regenerated-fixtures` artifact
 * whenever the checked-in files differ, so a host that cannot run Gradle commits that.
 */
fun main() {
    val dart = File("../../packages/run_engine/test/fixtures")
    ContractFixtures.write()
    ContractFixtures.write(File(dart, "contract"))
    EventTraceFixture.write()
    EventTraceFixture.write(File(dart, "contract-events"))
    TranscriptFixture.write()
    VoiceCopyFixture.write()
    println("wrote ${ContractFixtures.all().size} contract fixtures + ${EventTraceFixture.NAME}.ndjson to core-jvm and ${dart.path}, T4 transcripts + voice copy to core-jvm")
}
