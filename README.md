# Run Solo

**Run Solo: 4x4 Interval Run.** Free Android app: record a run, get a staged 4x4 verdict. No
accounts, no ads, no analytics of our own; runs stay on the phone, the post-run map comes from
Google Maps and weather from Open-Meteo (privacy: `docs/privacy/`). Plan:
`~/ai/plans/run-solo-v1-plan.md`; visuals: `~/ai/plans/run-solo-design-brief.md`.

## Repo layout

| Path | What |
|---|---|
| `lib/` | Flutter app. `theme/` = Night Session tokens, motion, type; `screens/`; `platform/` = Pigeon channel contract (generated `*.g.dart` committed) |
| `pigeons/platform_api.dart` | Source of truth for `RecorderApi` / `BleApi` / `RecorderEvents` (plan §2). Regenerate: `dart run pigeon --input pigeons/platform_api.dart` |
| `packages/run_engine/` | Pure-Dart analysis engine (laps, trimming, metrics, staged verdict, plans schedule). The only place verdict logic lives. `dart test` here |
| `android/app/` | Android shell (Kotlin, package `app.runsolo`). minSdk 29, target/compileSdk 36. Debug builds are `app.runsolo.debug` |
| `android/core-jvm/` | Pure Kotlin/JVM module (journal codec, lap state machine, haversine, HR parse, cue scheduler). Standalone Gradle build, no Android plugin, included into the app via `includeBuild` |
| `assets/fonts/` | Barlow Condensed 600/700 + Archivo variable, bundled (SIL OFL 1.1, licences beside them). Nothing is fetched at runtime |
| `tools/` | `check_16kb_alignment.sh` (16 KB page-size gate), `emulator_*.sh`, `print_cert_sha1.sh` (SHA-1s for the Maps key restriction) |
| `docs/` | GitHub Pages site (`runsolo.app`): `privacy/` policy page; `play-console.md` (every App content / Data safety / listing answer), `fgs-demo-video.md`, `closed-test-testers.md` |
| `.github/workflows/ci.yml` | CI (below) |

## Building: CI only for Android

The dev host is aarch64 Linux with no Android SDK (`aapt2` cannot run there), so APKs and
Android-module tests are built **only in GitHub Actions**. Every push to `main` and every PR runs:

1. `flutter` job: Pigeon drift check, `dart format`, `flutter analyze`, `flutter test`, `dart test` in `packages/run_engine`.
2. `core-jvm` job: `./gradlew test` in `android/core-jvm` (pure JVM).
3. `build-apk` job: `flutter build apk --debug --flavor play` (uploaded as artifact **`run-solo-debug-apk`**), a release AAB build (debug-signed for now), and the 16 KB page-size check on both (ELF `LOAD` alignment of every 64-bit `.so` plus `zipalign -P 16`). Fails the job if misaligned.
4. `emulator` job: API 29 / 34 / 36 x86_64 emulators install and launch the debug APK, then run the replay-mode lifecycle test.
5. `release-aab` job (**manual run or a `v*` tag only**, not on PRs): `flutter build appbundle --release --flavor play`, signed with the Play upload key, signer + 16 KB + Maps meta-data verified, artifacts `run-solo-play-aab-<ref>` (the `.aab` to upload to Play) and `run-solo-play-symbols-<ref>` (R8 `mapping.txt`, native debug symbols zip, Dart split-debug-info) kept 90 days. Upload the mapping and native symbols with the release in Play Console so vitals traces are readable.
6. `build-dogfood` job: optimised sideload build for the Pixel, artifact **`run-solo-dogfood-apk`** (see below). `emulator-dogfood` runs the launch smoke and a logcat-only replay check (auto-laps fire) on its x86_64 twin on API 36, so R8 stripping is caught in CI; the full lifecycle test needs `run-as` and stays on the debug build.

Flutter is pinned to **3.47.5** in `ci.yml` (`FLUTTER_VERSION`); the host install at `~/tools/flutter` is the same version. Bump both together.

### Getting the APK onto a phone

From the terminal (gh CLI logged in):

```bash
gh run list --repo ricki2828/run-solo --branch main --limit 3          # find a green run
gh run download <run-id> --repo ricki2828/run-solo -n run-solo-debug-apk -D ~/Downloads/run-solo
adb install -r ~/Downloads/run-solo/app-debug.apk                       # or copy to the phone and open it
```

Or on GitHub: Actions → the run → Artifacts → `run-solo-debug-apk` (zip) → unzip → copy
`app-debug.apk` to the phone → open it (allow "install unknown apps" for the file manager once).
The debug package is `app.runsolo.debug`, so it installs beside a Play build.

## Working on the host (aarch64, shared, low RAM)

- Flutter: `~/tools/flutter/bin` (add `~/tools/bin` first on PATH: it holds an `unzip` shim the Flutter tool needs). Use it for `flutter create`, `flutter analyze`, `flutter test`, `dart run pigeon`, `dart test`. **Do not** run `flutter doctor --android-licenses` or any `flutter build`/`flutter run` for Android here.
- Memory: `earlyoom` SIGTERMs the largest process once available RAM drops below ~10% (~1.5 GB). The Flutter tool build, the Dart analysis server (~860 MB) and Gradle each need headroom, so run one heavy thing at a time and expect `flutter analyze` / `flutter test` to be killed when other services are busy; CI is the gate. `export FLUTTER_TOOL_ARGS=--old_gen_heap_size=400` keeps the tool smaller.
- Gradle: `android/core-jvm/gradle.properties` disables the daemon, caps the JVM at 768 MB and runs the Kotlin compiler in-process. `cd android/core-jvm && ./gradlew test` is the only Gradle invocation that works on the host.
- Java 17 is present; no Android SDK, no Gradle install (the wrapper downloads Gradle 9.3.1).

## Dogfood build (the one to put on the Pixel)

The debug APK is ~160 MB, JIT and unsigned-for-purpose: fine for the emulator, useless for
battery or smoothness. For phone testing download **`run-solo-dogfood-apk`** instead:

- release-mode AOT Dart, R8 + resource shrinking, `--obfuscate --split-debug-info`, arm64-v8a only, target under 30 MiB (CI fails above it and prints the size in the job summary)
- applicationId **`app.runsolo.dogfood`**, so it installs beside `app.runsolo.debug` and a future Play build; plain `app.runsolo` is reserved for Play-signed builds
- replay mode and the debug intents stay available (`BuildConfig.REPLAY_ENABLED`), same as debug
- signed with the CI dogfood key (`CN=Run Solo dogfood`). Secrets: `RUN_SOLO_DOGFOOD_KEYSTORE_BASE64`, `RUN_SOLO_DOGFOOD_STORE_PASSWORD`, `RUN_SOLO_DOGFOOD_KEY_PASSWORD`; offline copy in `~/.secrets/run-solo/` on the dev host (never committed). Reinstalling over an older dogfood build works as long as this key is unchanged.

```bash
gh run download <run-id> --repo ricki2828/run-solo -n run-solo-dogfood-apk -D ~/Downloads/run-solo
adb install -r ~/Downloads/run-solo/app-arm64-v8a-dogfood-release.apk
```

Flavours: `play` (Play track, no suffix) and `dogfood`. Every `flutter build`/`flutter run` now needs `--flavor play` or `--flavor dogfood`; Gradle tasks are `:app:lintPlayDebug`, `:app:testPlayDebugUnitTest`, etc.

## Release signing (Play upload key)

The `play` flavour signs with the upload key when `RUN_SOLO_UPLOAD_KEYSTORE` points at the
keystore (the `release-aab` job decodes it from secrets); otherwise it falls back to the debug
key so PR builds and `flutter run --release` still work. Play App Signing holds the app-signing
key; we only ever hold the upload key (`CN=Run Solo upload`, alias `upload`, RSA 4096).

| Secret | Contents |
|---|---|
| `RUN_SOLO_UPLOAD_KEYSTORE_BASE64` | base64 of the upload keystore (`.jks`) |
| `RUN_SOLO_UPLOAD_STORE_PASSWORD` | keystore password |
| `RUN_SOLO_UPLOAD_KEY_PASSWORD` | key password |
| `RUN_SOLO_MAPS_API_KEY` | Google Maps key (manifest placeholder; builds pass with it absent) |
| `PLAY_SERVICE_ACCOUNT_JSON` | later, for uploading tagged builds to the internal track automatically |

Offline copy of the keystore and passwords: `~/.secrets/run-solo/run-solo-upload.{jks,env}` on
the dev host (mode 600, never committed). Losing the upload key is recoverable via a Play Console
upload-key reset, not a new listing.

### Google Maps key

Resolved in `android/app/build.gradle.kts` (`mapsApiKey()`): env `RUN_SOLO_MAPS_API_KEY`, then
Gradle property / `android/local.properties` `runsolo.mapsApiKey=...`, then empty. It lands in
the manifest as `com.google.android.geo.API_KEY` and is never read from Dart or printed by CI.
Restrict the key to Android apps with one entry per package + signing SHA-1 (upload key, **Play
app-signing certificate**, dogfood key, your local debug key); see `docs/play-console.md` §12.
CI's debug APK is signed by a per-runner debug key, so the emulator smoke always sees the
"Map failed to load" state.

### GitHub Pages (`runsolo.app`)

Settings → Pages → Source "Deploy from a branch", branch `main`, folder `/docs`; custom domain
`runsolo.app` (add the `A`/`AAAA` records GitHub lists plus `www` CNAME, tick Enforce HTTPS).
Pages on a private repo needs GitHub Pro; otherwise make the repo public or host `docs/`
elsewhere. The privacy policy is then `https://runsolo.app/privacy/`.

## Licences

Fonts: Barlow Condensed (© Jeremy Tribby) and Archivo (© Omnibus-Type), both SIL Open Font
Licence 1.1 (`assets/fonts/OFL-*.txt`). App code: proprietary, all rights reserved.
