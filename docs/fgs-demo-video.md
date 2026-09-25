# FGS demo video: script and shot list (week 4 declaration)

Play's Foreground service permissions form (type `location`) wants a video that shows the
user starting the feature, the app going to the background while the service keeps working,
and the user stopping it. Google's reviewer watches for: a clear user action that starts it,
a visible notification, and a clear way to stop. Keep it under 60 seconds, no narration
needed, captions optional.

Recorded from the founder's **real run** (the Tuesday or Saturday 4x4 in week 4) on the Pixel
with the Play internal-track build (`app.runsolo`), not the dogfood package. Do the dry run
first at the desk with **replay mode** on the dogfood build so the shot order is rehearsed and
the screen recorder settings are right; the replay footage is not what gets uploaded.

## Setup

- Phone: Pixel, Play internal-track build installed, location permission already granted
  ("While using the app", precise), notifications allowed, Whoop broadcast on (HR badge visible
  makes the run look real; optional).
- Screen recording: Android's built-in Screen record (Quick Settings tile), "Record audio: off",
  "Show touches: ON" (Settings → System → Developer options → Show taps). Portrait. Do not
  record the lock screen PIN entry; unlock before starting, or use fingerprint.
- Clock, battery and status bar visible the whole time (they prove real time is passing).
- Dry run: dogfood build, `replay` at 10× via the debug intent, same shot list; check the file
  plays and the touches show. Then delete it.

## Shot list (one continuous recording, ~45–60 s of the run kept in the edit)

| # | Time | On screen | Purpose |
|---|---|---|---|
| 1 | 0:00 | Home screen of the phone, tap the Run Supreme icon | App opened by the user |
| 2 | 0:03 | Start screen: 4x4 selected. Tap **START WARM-UP**, then on the recording screen tap **START 4x4** | The user action that starts recording |
| 3 | 0:06 | Recording screen: timer running, pace, GPS dot solid. Hold 5 s | Feature is live |
| 4 | 0:11 | Swipe down the notification shade: the **Run Supreme** recording notification with LAP, Pause and Stop actions. Hold 4 s | Persistent notification while the FGS runs |
| 5 | 0:15 | Swipe shade closed, press **Home**. Open Spotify (or any other app), play a track. Hold 5 s | App in background, service continues |
| 6 | 0:20 | Press the **power** button: screen off. Wait ~10 s (real run: this is a whole rep; trim in the edit to ~5 s of black with the wake at the end) | Screen off, service continues |
| 7 | 0:30 | Wake. Lock screen shows the notification with the timer still counting and the phase moved on by itself (the 4x4 runs its reps and recoveries automatically) | Service kept running with no app in front |
| 8 | 0:35 | Open Run Supreme from the notification: recording screen shows the current rep/recovery, timer continuous with what was on the lock screen | Proof it never stopped |
| 9 | 0:40 | Tap **Stop**, confirm. Finalising, then the verdict / summary screen | Clear stop by the user |
| 10 | 0:48 | Swipe down the shade: the recording notification is gone. Hold 3 s | Service ended when the user stopped |
| 11 | 0:52 | (Optional) Settings → About → the privacy paragraph and the "Precise location: used only during a run you started" line | Policy alignment |

## Edit

- Cut the middle of long reps but keep the status-bar clock readable across every cut so the
  timeline is obviously continuous. No music, no effects.
- Export 1080p, MP4. Upload to YouTube as **Unlisted** (not Private; Play's reviewer must open it
  without signing in). Title "Run Supreme — foreground location service demo". Paste the link into
  the FGS form (`docs/play-console.md` §8).
- Keep the raw recording in `~/Files/Run Supreme/fgs-demo/` (not in this repo).

## Things the reviewer must NOT see

- Any deep-link to Settings for location (plan §10: system prompt only).
- Replay mode, debug intents or the `.dogfood` package name.
- A permission prompt for background location (there is none; if one appears, the build is wrong).
- Recording restarting after Stop, or a notification that survives Stop.

## Acceptance

- [ ] Real run, Play-signed build, `app.runsolo` visible in Settings → Apps if asked.
- [ ] Start → notification → background → screen off → lock-screen LAP → Stop → notification gone, all in one recording.
- [ ] Under 60 s in the edit, clock continuous across cuts, touches visible.
- [ ] Unlisted YouTube link opens in a private browser window.
