package app.runsolo.core.run

/** Paths relative to the app's `files/` root (plan §2 diagram). */
object RunPaths {
    const val RUNS_DIR = "runs"
    const val ARCHIVE_DIR = "runs-archive"
    const val JOURNAL_NAME = "journal.ndjson"
    private const val RUN_PREFIX = "run-"
    private const val RUN_SUFFIX = ".json.gz"
    private const val EDITS_SUFFIX = ".edits.json"
    private const val TMP_SUFFIX = ".tmp"

    fun journalDir(runId: String) = "$RUNS_DIR/$runId"
    fun journal(runId: String) = "${journalDir(runId)}/$JOURNAL_NAME"
    fun runFile(runId: String, dir: String = RUNS_DIR) = "$dir/$RUN_PREFIX$runId$RUN_SUFFIX"
    fun runFileTmp(runId: String) = "${runFile(runId)}$TMP_SUFFIX"
    fun edits(runId: String, dir: String = RUNS_DIR) = "$dir/$RUN_PREFIX$runId$EDITS_SUFFIX"

    /** `run-<id>.json.gz` → id, else null (tmp files, sidecars and directories do not match). */
    fun runIdFromFileName(name: String): String? {
        if (!name.startsWith(RUN_PREFIX) || !name.endsWith(RUN_SUFFIX)) return null
        val id = name.substring(RUN_PREFIX.length, name.length - RUN_SUFFIX.length)
        return id.takeIf { it.isNotEmpty() && isSafeId(it) }
    }

    fun isSafeId(id: String) = id.all { it.isLetterOrDigit() || it == '-' }
}
