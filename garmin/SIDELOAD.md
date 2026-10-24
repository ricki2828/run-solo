# Run Supreme Garmin spike: tester guide

Phase 0 test of whether the watch and phone can talk. About 20 minutes. Nothing is recorded or
uploaded; results stay on your phone until you share them.

**You need:** your Garmin watch paired with **Garmin Connect** on your Android phone (Bluetooth on),
a USB cable (or Garmin Express on a computer), and this release: `garmin-spike-latest` on the
run-solo GitHub releases page.

## 1. Install on the watch
1. Download the `.prg` whose name matches your watch (e.g. `run-supreme-spike-fr265-<sha>.prg`).
   Not sure of the model? Watch Settings > System > About. If none matches, tell Ricki the model.
2. Plug the watch into a computer by USB. It appears as a drive.
3. Copy the `.prg` into the `GARMIN/APPS` folder on the watch (on a Mac use Android File Transfer
   or OpenMTP if the watch does not mount). Eject safely and unplug; the watch may restart.
4. Find **RS Spike** in the watch's app list (hold the Start button, or press it and scroll to Apps).

## 2. Install the phone test app
1. Download the dogfood APK (`run-solo-dogfood-<sha>-arm64.apk`) from the `dogfood-latest` release.
   Until the spike PR is merged, use the APK attached to the PR's CI run instead (Ricki will send it).
2. Install it. Open **Garmin Spike** (a second icon, next to Run Supreme). Allow any prompts.
3. The status line should show your watch name, and the log should say `app INSTALLED`.
   If it says `NOT INSTALLED` or `NO paired Garmin device`, stop and send the log (step 4).

## 3. Run the spike
On the watch open **RS Spike**. **DOWN / UP** (or swipe) changes page, **START** (or tap) runs that
page's test. Do these in order and keep both apps open unless told otherwise.

| Page | Press START | Then |
|---|---|---|
| 1 link | once | note the `rtt`. On the phone press **Ping**: the watch log shows `ping`. |
| 2 burst | once | **Within 5 s** press Home on the phone (Garmin Spike in the background). Wait 50 s. Reopen Garmin Spike and look at the log. Repeat, but this time **swipe Garmin Spike away from Recents** (kill it) after 10 s, wait for the burst to end, then reopen it. |
| 3 throughput | once | wait for it to finish (can take minutes). Keep the phone unlocked and the watch close. |
| 4 storage | once | takes about a minute; the watch may look busy. |
| 5 sample | once | |
| 6 results | once | resends everything to the phone. |

## 4. Send results back
In Garmin Spike press **Share** and send the text to Ricki (WhatsApp, email, anything). Also
say: watch model, phone model, Android version, and anything odd (app closed itself, watch froze).

## Notes
- The watch app may show "Garmin Connect IQ" warnings about unsigned apps: it is signed with a
  developer key, which is normal for sideloading.
- This does not touch your Run Supreme data.

---
## CI setup, now optional (for Ricki; delete before sending to a tester)
Workflow: `.github/workflows/garmin.yml`. Without secrets it runs static checks only and says so.
To get compiled `.prg` files add repo secrets (names only, never commit values):
- `GARMIN_DEVICES_URL`: the Devices bundle. One-time, on a laptop: install the Connect IQ SDK
  Manager, sign in, download the SDK plus the devices in `garmin/products.txt` (or just the tester's
  model), then `tar -czf devices.tar.gz -C ~/.Garmin/ConnectIQ/Devices .` (macOS/Windows path
  differs) and put it at a private URL. **Licence caution:** the Connect IQ agreement bars hosting
  or redistributing Program Materials; the repo is public, so never commit or release the bundle.
  Hosting it privately for your own CI is a judgement call that is yours, not Claude's.
- `GARMIN_DEVICES_SHA256` (optional): checksum of that file.
- `GARMIN_DEV_KEY_DER_BASE64` (optional): `openssl genrsa -out k.pem 4096 && openssl pkcs8 -topk8
  -inform PEM -outform DER -in k.pem -out developer_key.der -nocrypt && base64 -w0 developer_key.der`.
  Without it each run uses a throwaway key: fine for sideloading, but a store app needs one stable
  key (back it up off the repo).
Then: `gh workflow run garmin.yml --ref <branch>`; builds publish to the `garmin-spike-latest`
release (manual/main runs) or a 5-day PR artifact.

## Building on the host (current path)
CI is static checks only on purpose: the Garmin licence bars hosting the SDK/device files and the
repo is public. On the server: `garmin/tools/fetch-devices.sh` (Ricki, once: accepts the licence,
logs in to Garmin, downloads the devices) then `garmin/tools/build-local.sh` (builds the `.prg`
files into `~/.cache/run-supreme-garmin/out`, key in `~/.secrets/run-supreme/garmin`).
