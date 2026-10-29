# Releasing Run Supreme

One path per target. Nothing here is hand-bumped and nothing uploads from a laptop.

| Target | Trigger | Workflow / job | Status |
|---|---|---|---|
| Android (Play) | push tag `vX.Y.Z`, or Actions > ci > Run workflow **on main** with **play_upload** ticked | `ci.yml` `release-aab` then `play-upload` | build tested; upload untested until the secret exists |
| iOS (TestFlight) | push tag `vX.Y.Z`, or Actions > ios > Run workflow **on main** with **testflight** ticked | `ios.yml` `testflight-gate` then `testflight` | **UNTESTED** (no Apple account yet) |
| Companion server | merge to main, then deploy on the host | `companion-server.yml` (CI) + `~/services/deploy-companion-logged.sh` | live |
| Public site (privacy, delete, home) | merge to main, then `tools/deploy_site.sh` on the host | none (CI ignores `docs/**`) | live |

## Release checklist

1. Update `pubspec.yaml` `version:` **name** if this is a new version (e.g. `0.1.0` to `0.2.0`). Leave the `+N` build number alone: it is only a floor now (see below).
2. Edit `store/play/release-notes/whatsnew-en-US` (max 500 characters, plain text). One file per Play listing language, named `whatsnew-<locale>`.
3. Merge to main. Wait for main's `ci` run to go green.
4. Tag main: `git tag v0.2.0 origin/main && git push origin v0.2.0`. The tag must equal the pubspec version name or `release-aab` fails.
5. The tag runs the full emulator set, `release-aab`, `play-upload`, and the iOS `verify` + `testflight` jobs.
6. Check the run summary: "Play versionCode N", "Play upload: track ..., status ...", and on iOS "TestFlight: uploaded ...". A skipped upload says which secret is missing.
7. Play Console: the build appears on the chosen track. For `internal` it is available to testers at once; for `alpha` (closed testing) or `production`, Play review applies.
8. TestFlight: build shows after 10-30 min of processing. Internal testers with automatic distribution get it.

Uploads only ever run from main or a `v*` tag: a dispatch from any other branch skips them (workflow `if:`), and the `release` Environment refuses other refs as a second lock. A manual `ci` dispatch without **play_upload** ticked still builds the signed AAB (on the `ci-aab-<run id>` prerelease, 14 days) and uploads nothing.

## Version numbers

- **Android versionCode** = `ci.yml` `github.run_number` + repo variable `ANDROID_VERSION_CODE_OFFSET` (default 0). run_number only grows (it was ~1,900 on 24-Oct-2026), so every upload is above the last. The job fails if the code is not above the pubspec `+N` floor (Play already holds +4). CI stamps the code into `pubspec.yaml` and `lib/app/version.dart` in the runner only; nothing is committed. If `ci.yml` is ever renamed or recreated, run_number restarts at 1: set `ANDROID_VERSION_CODE_OFFSET` above the last uploaded code first.
- **Android versionName** = pubspec version name.
- **Dogfood** builds are unchanged: `0.1.0+<run_number>` under the `.dogfood` app id suffix, a separate app.
- **iOS** `CFBundleVersion` = `ios.yml` `github.run_number` + repo variable `IOS_BUILD_NUMBER_OFFSET` (default 0); `CFBundleShortVersionString` = pubspec version name. Same rename caveat.

## Secrets and variables Ricki must add

### 1. Create the `release` Environment (once, before adding any upload secret)

The upload secrets are **Environment secrets**, not repo secrets, so a job on a feature branch (this repo has many agent branches) can never read them.

1. GitHub > ricki2828/run-solo > Settings > Environments > **New environment** > name `release` > Configure.
2. Deployment branches and tags > **Selected branches and tags** > Add rule: branch `main`; Add rule: tag `v*`.
3. Optional: Required reviewers > yourself, if every upload should wait for a click.
4. Save. (If a workflow ran first, GitHub auto-created `release` with no rules: open it and add them.)

### 2. Environment secrets (in `release`)

Settings > Environments > release > Environment secrets > Add. Or from a terminal (never paste into a chat): `gh secret set NAME -R ricki2828/run-solo --env release`.

| Name | Used by | What it is | Where to get it |
|---|---|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | `ci.yml` play-upload | The full JSON key file of a Google Cloud service account, pasted as is | Google Cloud Console > IAM & Admin > Service Accounts > Create (e.g. `play-ci`) > Keys > Add key > JSON. Then Play Console > Users and permissions > Invite new users > the service account's email > App permissions: Run Supreme > **Release apps to testing tracks** (and **Release to production** only if `production` will be used) > Invite. Set it with `gh secret set PLAY_SERVICE_ACCOUNT_JSON -R ricki2828/run-solo --env release < key.json`, then delete the local file. |
| `ASC_KEY_ID` | `ios.yml` testflight | App Store Connect API key id (10 characters) | App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > + > name `github-ci`, Access **Admin** (cloud-managed signing needs Admin) |
| `ASC_ISSUER_ID` | `ios.yml` testflight | Issuer id (UUID), shown above the key list | same page |
| `ASC_KEY_P8` | `ios.yml` testflight | Contents of `AuthKey_<id>.p8` (download once only). Plain PEM text or base64 of the file both work | `gh secret set ASC_KEY_P8 -R ricki2828/run-solo --env release < AuthKey_XXXX.p8` |
| `APPLE_TEAM_ID` | `ios.yml` testflight | 10-character Team ID | developer.apple.com/account > Membership details |

Already set as repo secrets and unchanged: `RUN_SOLO_UPLOAD_KEYSTORE_BASE64`, `RUN_SOLO_UPLOAD_STORE_PASSWORD`, `RUN_SOLO_UPLOAD_KEY_PASSWORD` (Play upload key), `RUN_SOLO_DOGFOOD_*` (dogfood key), `RUN_SOLO_MAPS_API_KEY`.

Note: `~/ai/plans/run-supreme-ios-plan.md` §6.3 names the iOS secrets `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_P8_BASE64`. The workflow uses the `ASC_*` names above; use these.

### 3. Repo variables (all optional; Settings > Secrets and variables > Actions > Variables)

| Name | Default | Meaning |
|---|---|---|
| `PLAY_TRACK` | `internal` | Track for tag uploads (`internal`, `alpha` = closed testing, `beta`, `production`). A dispatch's own track choice wins. |
| `PLAY_RELEASE_STATUS` | `completed` | `draft` while the app has never been published on any track (Play rejects `completed` then); `inProgress` for a staged rollout (needs `PLAY_USER_FRACTION`). |
| `PLAY_USER_FRACTION` | none | Share of users for `inProgress`, between 0 and 1 (e.g. `0.1`). The job fails if `inProgress` is set without it. |
| `ANDROID_VERSION_CODE_OFFSET` | `0` | See Version numbers. |
| `IOS_BUILD_NUMBER_OFFSET` | `0` | See Version numbers. |

## Android details

- `release-aab` (unchanged except the versionCode): play flavour, R8, obfuscated, upload-key signed, native symbols split out, 16 KB check, manifest + SHA256SUMS, published to prerelease `ci-aab-<run id>`.
- `play-upload` downloads that AAB, `mapping.txt` and `native-debug-symbols.zip` and sends all three with `r0adkll/upload-google-play` (pinned by commit SHA, v1.1.5). Play App Signing re-signs with the app-signing key.
- The action writes the service account key to the workspace; a final `always()` step deletes it.
- No secret: the job prints a notice, stays green, and the AAB is still on the prerelease for a manual Console upload.
- Untested: the upload step itself (no service account yet); whether `en-US` is a listing language (if Play rejects the notes, rename the file to the default listing language, e.g. `whatsnew-en-AU`).

## iOS details (UNTESTED)

Never run: no Apple Developer account, App Store Connect record or API key exists yet. Expect the first runs to need fixes. Prerequisites are steps R1-R5 and R8 in `~/ai/plans/run-supreme-ios-plan.md` §6.4.

- `testflight-gate` (Linux, seconds) checks the four secrets and skips everything else if any is missing, so a missing secret never starts a macOS runner.
- `testflight` (macos-15): RunCore XCFramework, `add_targets.rb`, `pod install`, `flutter build ios --release --config-only`, `xcodebuild archive` with `-allowProvisioningUpdates` and the API key (automatic signing, cloud-managed Apple Distribution cert), then `-exportArchive` with `ExportOptions` `method=app-store-connect`, `destination=upload`. Only the dSYMs go to prerelease `ci-ios-<run id>` (public): xcodebuild logs stay in the masked Actions log and are never published. The .p8 is deleted in an `always()` step.
- Known gaps: no Maps iOS key (`RUN_SOLO_MAPS_API_KEY_IOS`, Phase 2) and no `COMPANION=1` define yet; the map shows its failed state. If Xcode refuses cloud signing with the key, fall back to plan task T4b (fastlane match).

## Companion server

The one path:

1. PR touching `companion-server/**` or `coach/**`. `companion-server.yml` runs the full suite on GitHub (render goldens included, never skipped).
2. Review, then merge to main.
3. On the host: `bash ~/services/deploy-companion-logged.sh` (run in the background: the suite takes ~13-33 min). It calls `~/services/run-supreme-companion/deploy/sync-and-restart.sh`, which exports origin/main's `companion-server/` + `coach/`, refuses stale files, installs hash-pinned deps, runs the full pytest suite (render tests skipped on the host; CI ran them on the same sha), restarts `companion.service`, smokes healthz and the public endpoints. The wrapper keeps the full log on the HC volume, prints the real exit code, restarts `companion-render.service`, and exits non-zero unless the service start time changed.
4. If the PR adds an env flag: back up and edit `coach.conf`, `systemctl --user daemon-reload`, then deploy.
5. Anything merged after the deploy started needs another deploy. Check merge time vs deploy start before saying "live".

Never run `sync-and-restart.sh` piped through `tail` (hides the exit code).

### Rollback

The deploy always ships origin/main, so rollback is a revert on main:

1. `git revert <merge sha>` in a worktree, PR it, let `companion-server.yml` go green, merge.
2. `bash ~/services/deploy-companion-logged.sh`.
3. If the change came with a `coach.conf` flag: restore the matching `~/services/coach.conf.bak-<date>-<what>`, `systemctl --user daemon-reload`, restart.
4. A failed deploy leaves the old code running in memory but the new code on disk: check `systemctl --user status companion.service` "since"; do not let it crash-restart before the revert lands.

### Proposed changes to the live deploy script (not made)

- **`--ref <sha>`**: deploy a given commit instead of origin/main, so an emergency rollback does not wait for a revert PR + CI.
- **Stage, test, then swap**: today main is copied into `$APP` before pytest runs, so a failed test run leaves untested code on disk that a crash-restart would load. Run the suite in the staging dir and copy only on green.
- **Record what is live**: write `$APP/DEPLOYED_SHA` (and the log path) after a successful restart, so "which sha is live" is one `cat`.

## Public site (runsupreme.taiaroa.xyz)

`https://runsupreme.taiaroa.xyz` serves three pages from `docs/`: `index.html`, `privacy/` and `delete/`. Play and the app link to the last two, so every merged change to them must go live before the release that depends on it. Nothing syncs it automatically: the site is a static copy in `~/sites/run-supreme`, linked to the Vercel project `run-supreme-site` (`.vercel/` in that folder).

One command on the host, after the change is merged:

```bash
tools/deploy_site.sh --dry-run            # what would change, from origin/main; copies and deploys nothing
tools/deploy_site.sh                      # backup, copy, deploy, verify
tools/deploy_site.sh --ref <sha|tag>      # publish a specific commit (also the rollback path)
```

What it does:
1. Backs up `~/sites/run-supreme` to `~/sites/run-supreme.bak-<UTC timestamp>`.
2. Exports the three pages from the ref with `git archive` (never the working tree), then rsyncs them in. `privacy/` and `delete/` are mirrored, so a file removed from `docs/` leaves the site too.
3. Runs `vercel deploy --prod --yes` in `~/sites/run-supreme` (needs the host's logged-in `vercel` CLI).
4. Fetches each live page. The body must equal the source byte for byte, and a page with "Last updated <date>" must show the source's date. Any mismatch prints FAIL and exits non-zero, with the rollback line.

Rollback: `tools/deploy_site.sh --ref <previous good sha>`, or copy the printed `.bak-*` folder back and run `vercel deploy --prod --yes` in it.

Bump "Last updated" in the page whenever its content changes, so the check (and readers) can tell versions apart.

## Signing check

`play-upload` compares the AAB signer SHA-256 (`keytool -printcert -jarfile`) with repo variable `EXPECTED_UPLOAD_SHA256` (default baked in: `7F:9F:DC:C2:23:11:0B:4E:DD:83:5B:C4:EF:94:60:03:F9:62:29:A4:95:AE:55:6C:24:23:1D:0E:BA:42:FE:E3`) and fails before uploading on a mismatch. `~/ai/scripts/app-release` is the cross-app front end for this pipeline.
