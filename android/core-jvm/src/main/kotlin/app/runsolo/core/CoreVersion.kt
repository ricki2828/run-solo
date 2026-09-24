package app.runsolo.core

/**
 * Placeholder for the pure-Kotlin core (journal codec, lap state machine, point acceptance,
 * HR parse, cue scheduler). Filled in Phase 1 by run-native-fable. This module must stay free
 * of Android dependencies so its tests run on any JDK 17 host.
 */
object CoreVersion {
    const val VERSION: String = "0.1.0"
}
