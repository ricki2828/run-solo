package app.runsolo.core

/**
 * Version of the pure-Kotlin core (journal codec, lap state machine, point acceptance, HR
 * parse, cue scheduler, finaliser, reconciler, replay source). This module must stay free of
 * Android dependencies so its tests run on any JDK 17 host.
 */
object CoreVersion {
    const val VERSION: String = "0.1.0"
}
