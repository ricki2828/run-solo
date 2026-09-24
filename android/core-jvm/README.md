# core-jvm

Pure Kotlin/JVM recording core (plan §2 rule 6). No Android imports, no third-party
dependencies; the Android shell (`RecorderService`, `BleHrClient`, `LapInput`) is a thin
adapter over these packages.

| Package | What |
|---|---|
| `json` | Dependency-free JSON codec (journal lines, run file) |
| `fs` | `FileSystem` interface (`JvmFileSystem` for the device; tests inject a fake with crash points) |
| `model` | Core enums/values; names mirror the Pigeon enums so the shell maps them with `valueOf` |
| `journal` | NDJSON line types, codec, `JournalWriter` (flush every line, fsync ≤ 10 s + on lap/pause/gap), `JournalReplay` (truncated tail, bad lines, `gap` rebasing, clock-jump clamp) |
| `run` | `RunFile` (schema v1) built from a replay; `Finaliser` = journal → tmp → fsync → rename → delete journal, idempotent at every boundary |
| `reconcile` | `Reconciler`: scans `runs/` + `runs-archive/`, diffs against index rows (index / missing / restore / repath), finds orphan journals |
| `record` | `RecorderCore`: lap state machine, preset phases, cue scheduler, double-lap guard, restore-after-kill |
| `gps` | Haversine, `PointFilter` (acc ≤ 25 m, ≤ 7 m/s), `MovingDetector`, `LivePace` |
| `ble` | Heart Rate Measurement parser, `HrJoin` (≤ 2 s), `BleReconnectPolicy` (saved address, autoConnect, backoff, close-first) |
| `replay` | `ReplaySource` feeding a fixture through `LocationSink`/`HrSink` at N×; CSV / run-file fixture loaders; synthetic straight-line generator |

Contract fixtures: `src/test/fixtures/contract/*.json` are real `Finaliser` output produced by
`SampleTicker` + `RecorderCore` + `JournalWriter` in `ContractFixtures.kt`; the Dart engine holds
a verbatim copy under `packages/run_engine/test/fixtures/contract/` and CI compares the two.

Phase 1 device-test items (cannot be proven on the JVM): capture 30 s of raw `0x2A37` packets from
the founder's Whoop broadcast and check them in as a parser fixture — some broadcasters set
"sensor contact supported" without ever setting "detected", which this parser would read as
no contact (null HR); FLP fix-time vs receipt-time skew against the ±2 s HR join; a real
`am kill` mid-run on API 29/34/36 (the emulator job).

Tests: `./gradlew test` (CI, or on the host when RAM allows). Without Gradle, `kotlinc` +
`junit-platform-console-standalone` compile and run the same sources in well under 1 GB.
