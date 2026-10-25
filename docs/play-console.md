# Play Console: paste-ready answers

Section by section, in Play Console order. Each section says **where** in the Console, then **what to paste or tick**.
Text in `>` quotes is pasted as is. Code citations (`file:line`) sit in HTML comments, so they show in the source and not on the rendered page. Checked against main on 25-Oct-2026 (after #387 and #390).

The closed-test AAB includes the optional Run coach (`--dart-define=COMPANION=1`, `.github/workflows/ci.yml` release-aab). Every answer below assumes that build. It is off in the app until the runner turns it on and accepts the consent sheet.

## 0. Before you start

| Item | Value | Status |
|---|---|---|
| Package name | `app.runsupreme` (Play build only; `.debug` and `.dogfood` never go to Play) | fixed |
| Privacy policy URL | `https://runsupreme.taiaroa.xyz/privacy/` | live; redeploy after this PR (section 2) |
| Account deletion URL | `https://runsupreme.taiaroa.xyz/delete/` | live; redeploy after this PR |
| Contact email | `privacy@taiaroa.xyz` | **Ricki: confirm the mailbox receives mail** |
| Play App Signing | Enrol at first upload; we upload with `CN=Run Solo upload` | first AAB upload |
| Upload key SHA-1 | `6D:E0:ED:82:5F:B7:80:73:3A:C5:EC:9D:37:5F:8F:63:1F:6E:D0:57` | for the Maps key restriction |
| Trademark | "Supreme" is a registered streetwear mark (Supreme / VF Corp). Different class, but re-run the trademark search for "Run Supreme" before the listing goes live; never use the red-box style | Ricki: open |
| Uploads | `docs/RELEASE.md` (tag `vX.Y.Z` or a dispatch from main) | pipeline merged #390 |

The `docs/` site is not deployed by CI. After merging, copy `docs/privacy/` and `docs/delete/` to the site (`~/sites/run-supreme`, Vercel project `run-supreme-site`) and check both URLs return the new text before entering anything below.

## 1. Main store listing

**Grow > Store presence > Main store listing.**

- **App name**: `Run Supreme: 4x4 Interval Run` (29 of 30). Approved 3-Oct-2026. "Run Supreme: 4x4 & Interval Runs" is 32, over the limit.
- **Short description**: `Run scores, honest verdicts and trail runs. See what is improving. Free.` (72 of 80)
- **Full description**: paste the "Full description" block of `store/play/listing.md` (updated by #387 for the coach). It names the coach, OpenRouter and Anthropic, memory, `/memory`, and the delete link.
- **App icon**: `store/play/icon-512.png`.
- **Feature graphic**: `store/play/feature-graphic-1024x500.png` (tagline "Track progress. Get better.").
- **Phone screenshots**: `store/play/screens/01..08` (1080x1920; Play wants each side 320-3840 px and long side at most 2x short, so 1080x2400 is rejected).
  - **TODO (do last, not in this PR):** regenerate the screenshots with `store/play/build_screens.py` after the open UI PRs merge. The current set is from 7-Oct and predates many UI changes. Check no frame says "Nothing uploaded".
- **Category**: Health & Fitness. **Tags**: Running, Fitness tracker, Interval training.
- **Contact details**: email `privacy@taiaroa.xyz`; website `https://runsupreme.taiaroa.xyz`.
- **Countries** (Test and release > Production/track > Countries): AU, NZ, US, CA, GB, SG, ZA (English-speaking, non-EU).
- No Hyrox marks or keywords anywhere.

## 2. Privacy policy

**Policy > App content > Privacy policy.** Paste:

> https://runsupreme.taiaroa.xyz/privacy/

Source: `docs/privacy/index.html`. In-app: Settings, About; and Health Connect's permission screen opens the same URL.
<!-- android/app/src/main/kotlin/app/runsolo/PrivacyPolicyActivity.kt:23 PRIVACY_URL -->

## 3. App access

**Policy > App content > App access.**

Pick **"All or some functionality in my app is restricted"**. The core app needs no login, but the optional Run coach needs the reviewer's own Telegram account and, during the closed test, an invitation. Add one instruction set:

- **Name**: `Run coach (optional)`
- **Username / Password**: leave empty (there is no account in the app).
- **Any other information required to access your app**, paste:

> Run Supreme works fully without an account or sign-in: recording, verdicts, plans, maps, history and exports need no access. The Run coach is optional and off by default. It is not needed to review any other part of the app.
>
> To see the coach screens: Settings, Companion. The consent screen explains what is sent, with "Turn on" and "Not now" at equal weight. Turn on opens Telegram; tapping Start there sends a 6-digit code, which is typed back into the app. The coach then writes in that Telegram chat. During the closed test the coach is open to invited testers only, so an uninvited Telegram account gets the reply "Run Supreme's companion isn't open yet." The app keeps working normally after that reply.
>
> Deleting coach data: Settings, Companion, Delete everything; or send DELETE in the Telegram chat; or https://runsupreme.taiaroa.xyz/delete/.

<!-- enrolment refused unless open_enrolment or allowlisted: companion-server/companion/service.py:541; reply text service.py:72 NOT_OPEN;
     open_enrolment default off: companion-server/companion/config.py:82; 6-digit code prompt lib/screens/companion_screen.dart:330;
     Turn on / Not now equal weight: lib/screens/companion_screen.dart:136,214 -->

**Ricki decides (default: as above).** If Play's review asks to see the coach working, either (a) set `COMPANION_OPEN_ENROLMENT=1` on the server for the review window (also opens enrolment to anyone who finds the bot, up to `max_users`), or (b) ask the reviewer for their Telegram id and add `telegram:<id>` to the enrol allowlist. Coach chat itself needs `COMPANION_COACH_OPEN=1` or an allowlist entry, plus the in-app consent (`config.py:156`). As checked on 25-Oct, the live server has `COMPANION_COACH_CHAT=1` and neither open flag.

## 4. Ads

**App content > Ads.** Tick **"No, my app does not contain ads."** No ad SDKs.

## 5. Content rating (IARC questionnaire)

**Policy > App content > Content rating > Start new questionnaire.** Email: `privacy@taiaroa.xyz`.

Redone 25-Oct for the coach. The coach is an AI that answers free text in Telegram, and Ricki (the operator) can message testers there. The app itself has no in-app chat and no user-to-user features. Answer conservatively:

| Question | Answer | Why |
|---|---|---|
| Category | **Utility, Productivity, Communication or Other** | A fitness tracker. Not a game, not social. |
| Violence, fear, sexuality, nudity, language, crude humour, controlled substances, gambling | **No** to all | The app shows none of it. The coach's model is instructed to stay on training; its output is not pre-moderated, so see the AI row. |
| Does the app allow users to interact or exchange content? | **Yes** | Over-declared: the coach chat takes free text and replies with generated text, and the operator can write to testers. All of it happens in Telegram, not inside the app, and runners never see each other's content. Adds the "Users Interact" notice; it does not raise the age rating. |
| Does the app share the user's current location with other users? | **No** | Nothing is shown to other users. |
| Does the app allow purchase of digital goods? | **No** | Free; no billing library. |
| Is it a web browser or search engine? | **No** | |
| If asked about generative AI or AI chat features | **Yes**, the optional coach answers questions with AI-generated text | Unverified whether the current IARC form asks this; answer Yes if it does. |
| News, gambling, social casino | **No** | |

Expected result: Everyone / PEGI 3 with a "Users Interact" notice. If the result is higher, record the descriptors here.

## 6. Target audience and content

**App content > Target audience and content.**

- Target age: **18 and over** only (untick 13-15 and 16-17). Intense interval training; keeps the app out of the Families policy.
- "Could your app unintentionally appeal to children?": **No**.
- Not in "Designed for Families".

## 7. Data safety

**Policy > App content > Data safety.** One answer per Play data type, covering every source: the base app (Google Maps SDK, Open-Meteo, the on-device geocoder) and the optional Run coach (our server in Germany, OpenRouter and Anthropic as AI processors, Telegram as delivery).

### 7.1 Overview page

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** (Maps SDK, Open-Meteo, our server, OpenRouter, Telegram are all HTTPS) |
| Do you provide a way for users to request that their data is deleted? | **Yes**. Deletion URL: `https://runsupreme.taiaroa.xyz/delete/` |
| Families policy | Not applicable (18+) |
| Independent security review (MASA) | **No** |

What deletion covers: the coach's server data, by Settings, Companion, Delete everything; by sending DELETE in Telegram; or by email from the delete page. All three erase every row for the runner at once. Runs on the phone: in History, press and hold a run, then Delete (one run at a time), or uninstall / clear the app's storage. There is no "Delete all" button for on-phone runs. What the Maps SDK sent is Google's, under the runner's Google account controls.
<!-- DELETE keyword: companion-server/companion/service.py:660 -> db.hard_delete_user db.py:707 (every user table, one transaction);
     in-app: lib/screens/companion_screen.dart:494 ctl.deleteEverything (DELETE /v1/me); per-run delete: lib/screens/history_screen.dart:204,308 (long press);
     no "Delete all" / "Export all" string anywhere in lib/ (grep 25-Oct) -->

### 7.2 Data types to tick

Shared column: Play does not count a service provider processing for us as "sharing". The rule here (set by #387, kept): anything that reaches the AI provider (OpenRouter, Anthropic) is ticked **Shared** to over-declare; Google (Maps SDK), Open-Meteo, OpenStreetMap and Telegram are service providers and are **not** shared. Ricki can untick Shared if he reads Play's service-provider exemption as covering zero-retention AI processing; either answer is defensible, ticking is the safe one.

For every type below: **Encrypted in transit: Yes. Deletion: Yes.**

| Category | Type | Collected | Shared | Processed ephemerally? | Required or optional | Purposes |
|---|---|---|---|---|---|---|
| Location | **Approximate location** | Yes | **Yes** | No | Required | App functionality, Analytics |
| Location | **Precise location** | Yes | No | No | Required | App functionality, Analytics |
| Personal info | **Name** | Yes | **Yes** | No | Optional | App functionality |
| Personal info | **User IDs** | Yes | No | No | Optional | App functionality, Analytics |
| Personal info | Phone number | **No** while WhatsApp is off | | | | |
| Health and fitness | **Health info** | Yes | **Yes** | No | Optional | App functionality |
| Health and fitness | **Fitness info** | Yes | **Yes** | No | Optional | App functionality, Analytics |
| Messages | **Other in-app messages** | Yes | **Yes** | No | Optional | App functionality |
| App activity | **App interactions** | Yes | No | No | Required | App functionality, Analytics |
| App activity | **Other user-generated content** | Yes | **Yes** | No | Optional | App functionality, Analytics |
| App info and performance | **Crash logs** | Yes | No | No | Required | App functionality |
| App info and performance | **Diagnostics** | Yes | No | No | Required | App functionality, Analytics |
| Device or other IDs | **Device or other IDs** | Yes | No | No | Required | App functionality, Analytics |
| Financial info, Photos and videos, Audio, Files and docs, Calendar, Contacts, Web browsing, Search history, Emails, SMS | | **No** | | | | |

"Required" on a mixed row is because of its base-app part (the Maps SDK loads with any map, including Home's recent runs); the coach parts are optional. Play takes the strictest answer per type.

### 7.3 What each ticked type covers (for Ricki, and for review questions)

**Approximate location**
- Maps SDK: Google derives it from the IP when a map loads; used "to understand SDK usage" (Analytics).
- Open-Meteo (weather for each run, Settings, Recording): the run location rounded to about 10 km.
- Coach (only if turned on): the area name where a run started, never the street; the time zone; with "Weather in suggestions" on, the start rounded to 0.1 degree (about 11 km) on the phone, latest one, 30 days; with "Show route shape on cards" (default on), an outline of the route with a random 150-300 m cut off each end, no coordinates, 30 days; with "Show trail names on cards" (default off), the trail's name, taken from the street or place it starts in.
- Coach care finder: if the runner asks for a physio or GP, the place they type, or the coarse start of their last run, goes to OpenStreetMap (Nominatim, Overpass) rounded to about 1 km; nothing is stored.
- Shared: Yes because, with coach chat on, the coach is given the runner's time zone (and can look up weather for a 0.1 degree area or a typed place name, which goes to Open-Meteo, not the AI provider).
<!-- time zone to the model: companion-server/companion/coach/tools.py:192; weather cell only: coach/ext/weather.py:4-5;
     locality: lib/state/companion.dart:2430 ('locality', "never the street"); area 0.1 deg: companion.dart:2439-2442;
     trail name: lib/state/trail_facts.dart:116 + blurb lib/screens/companion_screen.dart:67; route outline trim:
     packages/run_engine/lib/src/engine/companion_shape.dart:388; care finder: companion-server/companion/coach/ext/places.py:1-8 -->

**Precise location**
- Maps SDK: camera and interaction events of the map area viewed (zoom 15-17, smaller than Play's ~3 km² line), retained by Google.
- On-device geocoder: names a run's start; may use Google Play services.
- Coach care finder: if the runner taps Share location in Telegram, the point is used once, rounded to 0.01 degree (about 1 km) before any search, and never written down. Tick "processed ephemerally" is **not** possible on this row because the Maps part is retained, so the row stays "No".
- The app never sends its own GPS points to us or to Google.
<!-- Telegram location parse: companion-server/companion/channels.py:624-630; never persisted: coach/ext/places.py:4-6 -->

**Name, User IDs** (coach only)
- The Telegram chat id, the Telegram display name, and a tester number (T-number) used for pseudonymous counts.
- Name is Shared: with coach chat on, the coach is given the first word of the Telegram display name, to greet the runner. The chat id and T-number never reach the AI provider.
<!-- chat_name stored at confirm: companion-server/companion/service.py:520; first name to the model: coach/tools.py:178,192 -->

**Health info** (coach only)
- The niggle answer (none, calf, knee, hip, foot, other), expires after 8 weeks.
- Check-in answers "Sore somewhere" and "Feeling ill": kept 14 days, not in backups.
- Health flags from the safety check (a kind and times, no text).
- With coach memory on and "Keep health notes too" ticked (off by default): niggles, injuries and illness the runner told the coach. Turning the tick off deletes them and the chat summary at once.
- Heart rate on cards (off by default): up to 64 bpm values and zones for a trail run with a strap, 30 days.
- Shared: Yes. With coach chat on (consent v3), the coach is given the active health flags and reads the last 14 days of check-in answers and run notes to reply, so they reach the AI provider. Health notes kept by memory are read by the coach too.
<!-- niggle TTL: companion-server/companion/facts.py:591; check-ins private tables: backup.py:28; health_flags no text: db.py:357-366;
     health notes opt-in: coach/ext/memory.py:68-96, service.py:1165-1170; coach reads check-ins + notes: coach/tools.py:288-296; health_flags to the model: coach/tools.py:192 -->

**Fitness info** (coach only)
- Per-run summary: type, start time and time zone, duration, distance, pace, True Pace, verdict, minutes per heart rate zone, climb, the Easy/Right/Hard tap, pace per km with its zone, rep times, an interval session's name (a custom session goes as a short code), plan facts (session type, plan week and length, next session).
- Coach memory (consent v4, "Share training numbers" on by default): estimated race times, best efforts, weekly load and plan. The switch is stored today; the app does not send a training-numbers payload yet (no such field in the run upload). Declared now so the form does not change mid-test.
- Purposes include Analytics: pseudonymous per-tester counts (runs per week) to judge the coach and its cost. No advertising.
- Shared: Yes, the run facts go to the AI provider to write cards, chat replies and spoken briefings.
<!-- payload: lib/state/companion.dart:2416-2450; consent copy: lib/screens/companion_screen.dart:33-46, 118-131;
     training_sync stored only: companion-server/companion/service.py:1227 (no reader) -->

**Other in-app messages** (coach chat, consent v3)
- What the runner types to the coach in Telegram, and the coach's replies. Kept 30 days, then deleted; not in the nightly backup. Sent to OpenRouter, which routes to Anthropic in the US, with zero data retention and data collection denied.
- Turning the coach off in the app deletes the chats and any coach memory at once.
<!-- 30-day purge: companion-server/companion/service.py:2563; not in backup: db.py:323-325 comment; ZDR provider block:
     coach/chat.py:774, coach/screen.py:39; model anthropic/claude-sonnet-5.5: config.py:168; consent sheet:
     lib/screens/companion_screen.dart:105-112 -->

**Other user-generated content**
- Run notes typed after "Add a note" (up to 500 characters, one per run), kept with the run. With coach chat on they are read by the coach (so they reach the AI provider); without it they are only quoted back in the weekly recap.
- Coach memory (consent v4): up to 20 facts of up to 160 characters, and one chat summary of up to 700 characters. Kept until the runner deletes them (`/memory` in Telegram, Turn off memory, or Delete everything; `lib/screens/companion_screen.dart:1180`). In the encrypted nightly backup, which ages out in 14 days.
- Feedback ("Tell Ricki" or `/feedback`): up to 1000 characters, 30 days, read by the operator only, not in backups.
- Analytics: counted per tester (a kind and a time, never content).
<!-- memory caps: companion-server/companion/coach/ext/memory.py:36-38; coach_memory table + backup note: db.py:379-393;
     backup retention 14 days: backup.py:24 -->

**App interactions**
- Maps SDK: map interaction events (pan, zoom), Google's own collected item.
- Coach: feel taps, button answers, suggestion taken or skipped, survey answers (fixed options); an activity log of kind and time only, 120 days, not in backups.
<!-- inbound_events 120 days: companion-server/companion/measure.py:21 -->

**Crash logs, Diagnostics, Device or other IDs**: Maps SDK only (crash reporting, request metadata, the SDK identifier Google uses to count daily active SDK users).

### 7.4 Not declared, and why

- **Health Connect** (write only, runner-enabled): writes to Android's on-device store; nothing reaches us. Covered by section 9.
- **Send / share a run** (TCX, GPX, FIT): user-initiated through the Android share sheet to an app the runner picks.
- **Intervals.icu** (off by default, runner connects their own account): user-initiated transfer to a service the runner chose. Ricki: decide whether to also tick Fitness info and Location as shared for it; Play's wording on user-initiated transfers is unverified here.
- **Follow a route** (GPX/TCX picked with the system file picker): read on the phone, nothing uploaded.
- **Offline maps**: a download sends the region id and the IP to our own hosting only when the runner taps Download; covered by Approximate location.
- **Voice cues**: on-device text-to-speech; no microphone.
- **Phone number**: only if WhatsApp is switched on; WhatsApp is off for the closed test. Tick it in the release that turns WhatsApp on.

### 7.5 Corrections found while checking (25-Oct)

- Earlier drafts said check-in answers and run notes are "never sent to OpenRouter or the model provider". True for a runner without coach chat; **false for a runner with coach chat on**: the coach's `get_checkins` tool reads 14 days of answers and notes (`coach/tools.py:288-296`). The coach consent sheet already says check-in answers go to the AI provider, but the in-app check-ins paragraph (`lib/screens/companion_screen.dart:19-32`, "they never leave our server, so no writing service ... ever sees them") contradicts it. That app copy needs a fix in a lib/ PR before the closed release.
- The privacy page named a Settings, Data, "Delete all" and "Export all" that do not exist in the app. Fixed in this PR (section 6 of the policy).

## 8. Foreground service permissions

**Policy > App content > Foreground service permissions.** Type: **Location** only.

> **Describe the user-facing feature:** Run Supreme records GPS pace and route during a running workout that the user starts by pressing Start. A persistent notification with LAP and Stop actions is shown for the whole run. The service starts only from the visible app in response to that tap, keeps recording while the screen is off or the user is in another app (music, for example), and stops when the user presses Stop in the app or the notification. There is no background location outside a run the user started, and recording never restarts on its own after the user stops it.
>
> **Why a foreground service:** Interval pace needs a continuous GPS sample stream for 30 to 60 minutes while the screen is off and the phone is in a pocket or armband; without a foreground service the process is suspended and pace and lap times are lost.

**Demo video URL**: the unlisted YouTube link recorded per `docs/fgs-demo-video.md` (phone recording, never the emulator: it would show the debug package and replay mode).

If asked: `FOREGROUND_SERVICE_LOCATION` in the manifest, the service is `START_NOT_STICKY`, `stopWithTask=false` only so the notification survives a task swipe during a live run, and no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.

## 9. Health apps and Health Connect

**Policy > App content > Health apps.**

- Health features: **Yes**, **Activity and fitness tracking**. Paste in the description box:

> Run Supreme records running workouts with GPS pace and, from a paired Bluetooth chest strap, heart rate. It is a training tool, not a medical device, and makes no clinical or diagnostic claims. Health and fitness data stays on the phone unless the runner chooses to send it: as a file through the share sheet, to Health Connect, to Intervals.icu, or, with the optional Run coach turned on, as run summaries to our server in Germany (and to an AI provider to write coaching replies). The coach is off until the runner turns it on and accepts a consent screen.

**Policy > App content > Health Connect permissions** (must be completed before an AAB with these permissions can roll out). The app requests exactly four, all write only, and reads nothing:
<!-- android/app/src/main/AndroidManifest.xml:29-32 -->

| Permission | Paste as the justification |
|---|---|
| Exercise (`WRITE_EXERCISE`) | Run Supreme saves each finished run as a running exercise session, with its laps and pauses, so the run appears in the runner's health apps. |
| Exercise route (`WRITE_EXERCISE_ROUTE`) | Saves the GPS route of the run on the session, without the first and last 200 m, so the runner can see the run's map in their health apps. Optional: the run is saved without the route if the runner declines this permission. |
| Heart rate (`WRITE_HEART_RATE`) | Saves the heart-rate readings from the runner's own chest strap during the run on the session. |
| Distance (`WRITE_DISTANCE`) | Saves the distance covered in the run on the session. |

<!-- session + laps + pauses: android/app/src/main/kotlin/app/runsolo/platform/HealthRecords.kt:58-110; route only when granted:
     HealthRecords.kt:79, HealthApiImpl.kt:106-115 (WRITTEN_WITHOUT_ROUTE); 200 m trim: lib/state/health_workout.dart:36-38 -->

Also enter, if asked:
- **How users turn it on**: off by default. Settings, Send runs to, Health Connect; or Send on a single run.
- **Privacy policy for Health Connect**: the permission rationale screen opens `https://runsupreme.taiaroa.xyz/privacy/` (section 4 of the policy names the four permissions). <!-- PrivacyPolicyActivity.kt:23; alias ViewPermissionUsageActivity, AndroidManifest.xml:81 -->

## 10. Other declarations

**Policy > App content.** Government app: **No**. Financial features: **None**. News app: **No**. COVID-19 contact tracing or status: **No**. Data deletion is in section 7.1.

## 11. Testing track order

1. **Internal testing**: Ricki and a couple of devices; Play-signed builds via `docs/RELEASE.md`.
2. **Closed testing (Alpha)**: tester list (at least 15 recruited, at least 12 opted in for 14 continuous days), submitted for review with every section above done. See `docs/closed-test-testers.md`.
3. **Production access** questionnaire after the 14 days, then a staged rollout.

Whether a Data safety change mid-test restarts the 14-day clock is unverified; enter section 7 in full before the first closed release so it never has to change.

## 12. Maps API key (Google Cloud)

1. Enable **Maps SDK for Android**, attach billing, budget alert at US$1, per-day quota cap.
2. Key restriction **Android apps**, one entry per package + SHA-1:
   - `app.runsupreme` + upload key SHA-1 (section 0)
   - `app.runsupreme` + **Play app-signing SHA-1** (Test and release > Setup > App signing, after the first upload). Without it the Play build shows "Map failed to load".
   - the dogfood package + dogfood key SHA-1 (`tools/print_cert_sha1.sh ~/.secrets/run-solo/<dogfood>.jks dogfood`)
   - `app.runsupreme.debug` + your local debug keystore SHA-1
   API restriction: Maps SDK for Android only.
3. Repo secret `RUN_SOLO_MAPS_API_KEY` (already set).

## 13. Submission checklist

1. This PR merged; `docs/privacy/` and `docs/delete/` redeployed; both URLs show the 25-Oct text.
2. `privacy@taiaroa.xyz` receives mail (send a test).
3. App copy fix for check-ins (section 7.5) merged and in the AAB being submitted.
4. Sections 2-10 entered in the Console.
5. Screenshots regenerated (section 1 TODO) and uploaded.
6. AAB uploaded per `docs/RELEASE.md`; Health Connect permissions form done before rollout.
7. WhatsApp stays off until Meta business verification, approved templates and the AI-policy check exist. When it ships, tick Phone number (section 7.2) in the same release.
8. CI ignores `docs/**`; none of this is checked by a pipeline.
