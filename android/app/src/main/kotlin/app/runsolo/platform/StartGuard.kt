package app.runsolo.platform

/**
 * The start-step guard shared by `start`/`startReplay` and `resumeRecovered` (pure, no Android
 * types, unit-tested): register the session so the event bus sees its first events, run the
 * start step, and on a throw unregister and clean up — **without ever deleting a recovered
 * run's journal**. A brand-new run has nothing worth keeping and is discarded; a resume failure
 * releases the session (journal closed, kept on disk) so the next `recover()` offers it again.
 */
object StartGuard {
    enum class OnFailure {
        /** Brand-new run: delete its header-only journal. */
        DISCARD,

        /** Resumed run: close the journal and keep it for the next recover(). */
        KEEP_JOURNAL,
    }

    interface Session {
        val runId: String
        fun discard()
        fun suspend()
    }

    fun <S : Session> begin(
        session: S,
        register: (S?) -> Unit,
        onFailure: OnFailure,
        failureError: StartError,
        startStep: (S) -> Unit,
        launch: (S) -> StartResult,
        log: (String, Throwable) -> Unit = { _, _ -> },
    ): StartResult {
        register(session)
        try {
            startStep(session)
        } catch (e: Exception) {
            log("start step failed for ${session.runId} (${onFailure.name})", e)
            register(null)
            try {
                when (onFailure) {
                    OnFailure.DISCARD -> session.discard()
                    OnFailure.KEEP_JOURNAL -> session.suspend()
                }
            } catch (cleanup: Exception) {
                log("cleanup after failed start step threw", cleanup)
            }
            return StartResult(runId = null, error = failureError)
        }
        return launch(session)
    }
}
