# Closed test: tester onboarding

Play requires a personal developer account's first app to run a **closed test with at least 12
testers opted in for 14 continuous days**, and Google checks that testers actually used the app,
before production access can be requested. Recruit **15+** (drop-outs happen), on at least three
brands (≥ 1 Samsung, ≥ 1 Xiaomi/Oppo, the rest Pixel or anything). The 14 days count from the
**last** opt-in, so get everyone in on day 1 (plan §11: week 5 day 1) and message them weekly.

## Founder: set-up steps in Play Console

1. Testing → **Closed testing** → Create track ("Alpha" is fine) → Testers tab → create an email
   list "run-solo-alpha" and paste the testers' Google-account emails (the address they use on
   their phone's Play Store, not their work address). Save.
2. Feedback URL: your email or a Google Form link. Countries: same as the listing.
3. Releases tab → create release → upload the `.aab` from the `release-aab` CI job (Actions → the
   run → artifact `run-solo-play-aab-<tag>`), release notes below, review and roll out. Play App
   Signing is enrolled at this first upload; then copy the **app-signing certificate SHA-1** into
   the Maps API key restriction (`docs/play-console.md` §12) or every tester sees "Map failed to load".
4. Copy the **opt-in link** from the Testers tab (`https://play.google.com/apps/testing/app.runsolo`)
   into the message below.
5. Track the roster in a sheet: name, email, device, opted-in date, last-heard-from. The clock
   starts when the 12th person is in; note that date.

Release notes (first closed release):

> First test build. Record a 4x4 (or a free run), get the verdict, check the route map. Please read the tester notes you were sent, and tell me anything that felt wrong, even small.

## Message to send testers (copy, paste, personalise the first line)

> Hey, thanks for helping test Run Supreme. It is a simple Android running app: a 4x4 interval timer that records your pace with GPS and tells you if you beat your last run. No account, no ads, your runs stay on your phone.
>
> **To get it (two steps, both needed):**
> 1. Open this link on your phone, signed in to the Google account your Play Store uses, and tap **Become a tester**: `<opt-in link>`
> 2. Then install it from Play: `https://play.google.com/store/apps/details?id=app.runsolo` (the link on the opt-in page goes to the same place).
>
> Google needs you to stay opted in and actually open the app now and then for 14 days, so please do not uninstall it before I say the test is done, even if you only run once a week.
>
> **What to try (any of these, in your own time):**
> - Do one real run with the app: pick 4x4 if you do intervals, otherwise Free run. Put the phone in your pocket or armband with the screen off, like you normally would.
> - 4x4: tap **START WARM-UP**, warm up, then tap **START 4x4**; the reps and recoveries run by themselves with voice and vibration cues.
> - Laps run: press LAP from the lock-screen notification at least once. Volume-key laps work in Laps runs too, but not on Android 14.
> - After the run: does the verdict/summary make sense? Does the route on the map look right?
> - If you own a heart-rate strap (or Whoop), pair it in Settings and run with it.
> - Kill the app mid-run once on purpose (swipe it away from recents) and reopen it: it should offer to recover the run.
>
> **How to report:** reply to this message, or email `<founder email>`. Most useful: your phone model, what you did, what you expected, what happened, and a screenshot. If the app crashed, say roughly when. If a run went missing, do not delete anything: Settings → Data → Export all, and send me the file.
>
> Two honest notes: this is an early build, so expect rough edges; and Google's map and weather services see the map area you view and a rounded location, the same as any maps app (full details: https://runsolo.app/privacy).

## Weekly nudge (days 7 and 12)

> Quick one: still running with Run Supreme? Even one short run or just opening the app this week keeps you counted for the test. Anything annoying you yet? Tell me, that is the whole point.

## What to test, by device type (for the founder's tracker)

| Device | Extra checks |
|---|---|
| Samsung | Screen-off run ≥ 30 min without the recording dying (battery killer). If it dies, ask them to screenshot Settings → Apps → Run Supreme → Battery. |
| Xiaomi / Oppo / Realme | Same, plus notification LAP works from the lock screen; autostart/battery saver prompts noted. |
| Pixel / others | HR strap pairing, map rendering, kill-and-recover flow. |
| Any with a Whoop | Whoop broadcast pairing shows live bpm on the record screen. |

## Triage

Reports go into GitHub issues on `ricki2828/run-solo` with labels `closed-test`, `device:<brand>`
and P0 (lost run / crash on start) → P3 (copy). A lost or wrong run needs the exported JSON attached
before it is worked on.

## Exit criteria (plan §13 Phase 4)

- ≥ 12 testers opted in for 14 continuous days, with usage.
- Crash-free ≥ 99% in Play vitals for the closed-test builds.
- No open P0/P1 from testers.
- Then: Production access questionnaire (week 7), staged rollout 20% → 100%.
