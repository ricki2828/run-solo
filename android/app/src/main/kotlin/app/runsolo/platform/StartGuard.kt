package app.runsolo.platform

/**
 * The start-step guard shared by `start`/`startReplay` and `resumeRecovered` (pure, no Android
 * types, unit-tested): register the session so the event bus sees its first events, run the
 * start step, and on a throw unregister and call [Session.abortStart] — the ONE place that
 * decides what happens to the journal: a brand-new run has nothing worth keeping and is
 * discarded; a resumed run keeps its journal (closed) so the next `recover()` offers it again.
 * Every path that can fail before recording is up (start step, `startForegroundService`,
 * `startForeground`) goes through `abortStart`, so no failure can delete a crashed run.
 */
object StartGuard {
    interface Session {
        val runId: String

        /** True for a session continuing an orphaned journal (`resumeRecovered`). */
        val resumed: Boolean

        /** Undo a start that did not reach recording: discard a new run, suspend (keep) a resumed one. */
        fun abortStart()
    }

    /** The typed error for a start that failed before recording, by session kind. */
    fun failureError(session: Session, newRunError: StartError): StartError =
        if (session.resumed) StartError.RESUME_FAILED else newRunError

    fun <S : Session> begin(
        session: S,
        register: (S?) -> Unit,
        startStep: (S) -> Unit,
        launch: (S) -> StartResult,
        log: (String, Throwable) -> Unit = { _, _ -> },
    ): StartResult {
        register(session)
        try {
            startStep(session)
        } catch (e: Exception) {
            log("start step failed for ${session.runId} (resumed=${session.resumed})", e)
            register(null)
            try {
                session.abortStart()
            } catch (cleanup: Exception) {
                log("abortStart after a failed start step threw", cleanup)
            }
            return StartResult(runId = null, error = failureError(session, StartError.START_FAILED))
        }
        return launch(session)
    }
}
