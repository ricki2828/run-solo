# Play Console: App content and listing answers (week 4)

Draft answers for every Play Console form Run Supreme must submit before the first closed-track
release. Source of truth for the claims: plan §10, §11, §18.3, §18.6 (v5.4) and the design brief
§6 + addendum A7. Where two documents disagree the difference is flagged for the founder.

Founder approves the wording (plan §18.9 item 8) before anything is typed into the Console.

## 0. Prerequisites

| Item | Value | Status |
|---|---|---|
| Package name | `app.runsolo` (Play build only; `.debug` and `.dogfood` never go to Play) | fixed |
| Privacy policy URL | `https://runsupreme.taiaroa.xyz/privacy/` (Vercel project `run-supreme-site`, copy at `~/sites/run-supreme`; repo is private so Pages is not used) | done 7-Oct |
| Play App Signing | Enrol at first upload; Google holds the app-signing key, we upload with `CN=Run Solo upload` | first AAB upload |
| Upload key SHA-1 | `6D:E0:ED:82:5F:B7:80:73:3A:C5:EC:9D:37:5F:8F:63:1F:6E:D0:57` | for the Maps key restriction |
| Trademark | "Supreme" is a well-known registered streetwear mark (Supreme / VF Corp). "Run Supreme" for a running app is a different class, but the founder should run the trademark search (plan Phase 0) again for the new name before the listing goes live, and avoid Supreme's red-box logo styling anywhere | founder: open |
| Domain | `runsupreme.taiaroa.xyz` chosen 7-Oct; the privacy URL on the Play forms must not change afterwards | decided |
| Contact email in the listing | `privacy@taiaroa.xyz` (chosen by Ricki 11-Oct) is used on the privacy and delete pages | founder: confirm the mailbox receives mail |

## 1. Store listing

- **App name (30 chars)**: `Run Supreme: 4x4 Interval Run` (29). Founder approved 3-Oct-2026. (The ampersand version is 32 chars, over the limit.)
- **Short description (80)**: `Run scores, honest verdicts and trail runs. See what is improving. No account.` (78)
- **Tagline** (feature graphic, first screenshot): Track progress. Get better. Approved 3-Oct-2026; the old "You against your last run" line is retired.
- **Long description** (source: `store/play/listing.md`):

> Run Supreme shows you how your running is going, whatever mix of runs you do.
>
> Run Supreme is where you get better at your runs, with no account and nothing uploaded. It tells you honestly how you are progressing and what to run next, free, on your phone.
>
> Your Home screen opens with where you stand, in plain words, against research-based norms for your age and sex. Under that are four scores: AEROBIC, SPEED, MID and LONG, each in its own colour. Each is a percentile estimate from your own runs. You see what moved, and over what period. Then comes one suggested session and why it would help, with Start already set to it. Tap Change to pick something else.
>
> 4-week plan
> Build a 4-week plan around your scores. If a week is well above your usual load, Run Supreme says so and suggests an easy run instead. A missed session is not added on top of next week.
>
> Intervals and 4x4
> Pick a session, warm up as long as you like, then the app runs every rep and recovery with voice and vibration cues. Your phone can stay in your pocket. When you stop you get a plain verdict: faster, holding or slower, with the rep paces and fade that decided it. Differences inside GPS noise are called no real change.
>
> A run screen built for running
> The number that matters is the biggest one on screen, and it changes with the phase: rep pace in a rep, time to go in a recovery. The screen takes the colour of your heart rate zone, with a zone ladder down the edge, and shows your target band in a rep. Switch to a live map if you want one, then switch back.
>
> Voice coaching
> Turn on voice coaching and your phone tells you the next step, whether you are on pace, and when your heart rate drifts out of the zone. Pick Minimal or Full detail, or keep just the cues. Speech uses your phone's own text-to-speech.
>
> Heart rate zones
> Pair a Bluetooth heart rate strap. Set your zones as a share of max heart rate, with heart rate reserve, or enter your own ranges. Run charts, splits and time in zone use the same colours, so you can see where the effort went.
>
> Trail runs
> Trail runs get their own verdicts. Run the same trail again and you are compared with your last run on that trail, not with a flat road. Elevation comes from your phone's barometer where it has one. Grade-adjusted pace is an estimate of your flat-ground equivalent.
>
> Offline Topo maps
> Download a region in Settings and use the Topo map on Free and Trail runs with no signal. Map data is from OpenStreetMap contributors, Protomaps and Mapterhorn.
>
> Follow a route
> Load a route and follow it, with turn alerts and an off-route warning if you drift.
>
> Also
> - Auto-pause at traffic lights and gates
> - Estimated race times from your recent runs
> - Your bests and recent attempts on a chart, like for like
> - Send a workout or route to your watch as a FIT or GPX file
> - Send any run to Health Connect, Intervals.icu, or as a TCX or GPX file (works with Strava)
>
> Private by default
> No account. No feed. No ads. Your routes, times and heart rate stay on your phone unless you choose to send them. Map tiles for the standard map come from Google, which sees the map area you view and your IP address. An offline map download tells our map host which region you picked and your IP address. Weather comes from Open-Meteo using your location rounded to about 10 km. Your phone's own geocoder names a run's start point and may use Google Play services.
>
> Run Supreme is a training tool, not medical advice. Scores and estimates are guides based on research, not measurements of your health.

- **Category**: Health & Fitness. **Tags**: Running, Fitness tracker, Interval training.
- **Countries**: English-speaking non-EU per plan §10: AU, NZ, US, CA, GB, SG, ZA. (IE is EU, so not in the list.)
- **Graphics**: icon `store/play/icon-512.png` (Lap Line R), feature graphic `store/play/feature-graphic-1024x500.png` (light look, Lap Line R, built by `store/play/build_screens.py`; the wordmark version is `feature-graphic-wordmark-1024x500.png` from `assets/brand/build_brand.py`); 8 screenshots 1080x1920 in `store/play/screens/` (refreshed 7-Oct-2026 for the light look: Home, run screen with zone ladder, verdict, 4-week plan, zone-coloured charts, offline maps, Start, History; also `build_screens.py`; Play wants each side 320-3840 px and the long side at most twice the short one, so 1080x2400 would be rejected). The fake-map shots were dropped; a real device capture of the Topo map or live map would make a stronger shot 6 (optional). No Hyrox marks or keywords anywhere.
- **Contact details**: email above; website `https://runsupreme.taiaroa.xyz`.

## 2. Privacy policy

URL: `https://runsupreme.taiaroa.xyz/privacy/`. Also linked in-app from Settings, About. Content = `docs/privacy/index.html`.

## 3. App access

"All functionality is available without special access." No login, no restricted areas. (Replay mode exists only in debug/dogfood builds, never in the Play package.)

## 4. Ads

"No, my app does not contain ads." (No ad SDKs; the transitive dependency audit in plan §10/§18.6 lists only `google_maps_flutter` and `http` as INTERNET users.)

## 5. Content rating (IARC questionnaire)

- Category: **Utility, Productivity, Communication, or Other** (a fitness tracker with no user-generated content).
- Violence / sexuality / language / controlled substances / gambling: **No** to all.
- User interaction: **No** (no chat, no sharing between users inside the app; export goes through the Android share sheet).
- Shares location with other users: **No**.
- Purchases digital goods: **No** (v1 is free; the paywall stub is inert).
- Personal information shared: **No**.
- Expected outcome: Everyone / PEGI 3.

## 6. Target audience and content

- Target age group: **18 and over** only (untick 13-15 and 16-17). Rationale: an intense-interval training tool; picking adults keeps the app out of the Families policy and the "designed for teens" questions.
- "Could your app unintentionally appeal to children?": **No** (no cartoon characters, no child-oriented themes).
- Store presence: not in "Designed for Families".

## 7. Data safety

Plan §18.6 (v5.4). Over-declare rather than under-declare. Answer the overview questions first:

| Overview question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** (Maps SDK and Open-Meteo use HTTPS) |
| Do you provide a way for users to request that their data is deleted? | **Yes**: "Delete all" in Settings, Data removes everything on the device; nothing is held off-device by us. Pick "Yes, deletion is via the app" and link the privacy page. What Google's Maps SDK collected is Google's to delete (Google account controls), and the privacy page says so. |
| Have you reviewed the Google Play Families policy? | Not applicable (18+ only) |
| Is your app's data handling independently validated against a security standard (MASA)? | **No** |

Data types. "Collected" in Play's sense includes what the Maps SDK sends to Google from inside the app. Purposes: **App functionality** everywhere; **Analytics** added to Device or other IDs because Google states the SDK identifier measures daily active SDK users. Nothing is "shared" (transferred to a third party) in Play's definition: Google and Open-Meteo act as service providers for the app's own functionality. Nothing is optional except weather (the user can turn it off), and the Maps data is only sent when the user opens a run's detail, Home shows recent runs (map images for recent runs load from Google and are kept on the phone), or the user selects MAP on the record screen during a run (NUMBERS is the default; no map loads while it shows or the screen is off).

| Category | Data type | Collected? | Shared? | Ephemeral? | Required or optional | Purposes | Why (for the founder) |
|---|---|---|---|---|---|---|---|
| Location | **Precise location** | Yes | No | No (Google retains map camera/interaction events "to improve Google services") | Required (the post-run map has no toggle; the live MAP view is the user's choice, off by default) | App functionality, **Analytics** | Live MAP view (2-Oct) follows the runner at zoom 17, so while it is selected the camera area is the runner's current position (still well under Play's ~3 km² threshold); the app never sends its own location to Google. Post-run map fits the camera to the route at zoom 15/16 and the full-screen map is panned/zoomed; the camera events Google receives describe an area smaller than Play's ~3 km² "approximate" threshold (R1) |
| Location | **Approximate location** | Yes | No | No | Required for the map's IP-derived part; the Open-Meteo part is optional (weather toggle) | App functionality, **Analytics** | Maps SDK derives it from the IP and Google says IP + request metadata are used "to understand SDK usage"; Open-Meteo gets the run location rounded to ~10 km |
| Location | **Precise location** (place name lookup) | Covered by the Precise location row above | No | Yes (nothing is retained by us) | Required for the place name; failure just leaves no name | App functionality | A run's start point is turned into a place name by Android's on-device `Geocoder` (`getFromLocation`). Run Supreme sends nothing itself; the system geocoder may use Google Play services, a service provider acting for the app's own function, so it is declared as collected, not shared. No new Data safety category beyond Precise location is added. |
| Device or other IDs | **Device or other IDs** | Yes | No | No | Required (part of the Maps SDK whenever a map loads) | App functionality, **Analytics** | Maps SDK identifier used by Google to measure daily active SDK users |
| App activity | **App interactions** | Yes | No | No | Required | App functionality, **Analytics** | Google lists "map interaction events (panning, zooming)" as its own collected item; Play's matching type is App interactions. Plan §18.6 did not cover this category; declared to over- rather than under-declare |
| App info and performance | **Crash logs** | Yes | No | No | Required | App functionality | Maps SDK crash reporting (Google's disclosure) |
| App info and performance | **Diagnostics** | Yes | No | No | Required | App functionality, **Analytics** | Maps SDK request metadata / performance data, used by Google "to understand SDK usage" |
| Health and fitness | Health info / Fitness info | **Base release: No.** Companion release: Yes, see section 13. The text below describes the base release. | No | | | | Heart rate, pace, route files stay on the device; we never transmit them. **User-initiated sharing:** the runner can tap Send on a run to hand a TCX or GPX file to an app they pick in the Android share sheet (or to Strava's website by hand). Nothing leaves the phone unless they do that, so this is not declared as data we collect or share (check the wording against Play's Data safety guidance on user-initiated transfers before each submit). **Health Connect (write only, runner-enabled):** if the runner switches it on or taps Send to Health Connect, the run goes into the on-device Health Connect store, which is Android's own store on the same phone, not a transfer to us or a third-party server. Run Supreme reads nothing from it. Declare nothing as collected or shared for it; the Health apps declaration (section 9) covers it. **Send to watch (4 Oct):** from a session or a route the runner can tap Send to watch. A workout (.fit) or a GPX course (the whole route, not trimmed) goes to the Android share sheet and an app the runner picks; nothing leaves the phone otherwise. If the runner has connected Intervals.icu, they can also tap Add for today or tomorrow, which sends a planned workout to their Intervals.icu calendar: the session name, its steps (lengths, heart rate or pace ranges, repeats), the chosen date and an id so a second send replaces the first. No run, route or heart rate history is in it. Same user-initiated, opt-in basis as below; Intervals.icu then passes it to the watch brand the runner linked there. **Intervals.icu (shipped 2 Oct, off by default):** data is shared with Intervals.icu only when the runner connects their own account (API key + athlete id) and then sends a run (button) or switches automatic sending on. What goes: the run's TCX (route minus first/last 200 m, laps, heart rate), the run title and the run id. The key sits in Keystore-backed secure storage, is excluded from Auto Backup, is never logged and is deleted on Disconnect. This is a user-initiated, opt-in transfer to a service the user chose; decide with the founder whether to declare Health and fitness / Location as **shared, optional, user-initiated** before submit (Play's wording on user-initiated transfers is unverified here). Auto Backup is a system feature under the user's Google account and Play's guidance excludes it. |
| Personal info | any | **Base release: No.** Companion release: see section 13 | | | | | No account, no name, no email in the base release. The optional Run companion adds rows, listed in section 13. |
| Financial info | any | No | | | | | |
| Messages / Photos / Audio / Files / Calendar / Contacts / Web browsing / Search history | any | No | | | | | TTS cues are generated on-device; nothing recorded |
| Files and docs | **Files and docs** | **No** | No | | | | **Follow a route (3 Oct):** the runner may pick one GPX/TCX file with the system file picker (Storage Access Framework, no storage permission). It is read on the phone and only a simplified copy of the route (points, optional elevation) is kept in the app's own `files/state/routes.json`, which Auto Backup includes like the rest of `state/`. Nothing is uploaded; the "Off route" alert and turn hints are computed on the phone and spoken by on-device TTS. No new Data safety declaration. The terrain map is the same Maps SDK, so the Location rows above already cover it. |
| Offline maps (Topo) | **No new data type** | **No** | No | | | | **Offline maps (4 Oct):** a map pack download sends only the region id (in the URL path, e.g. `milos`) and the IP address to our own R2 hosting, only when the user taps Download or Refresh in Settings, Offline maps. No account, device ID, location, run or route is sent, and drawing the Topo map is entirely on-device from the downloaded file (no network, no Google SDK, so a Free/Trail run on Topo sends nothing to Google). The hosting can see downloaded regions by IP, which is standard server-log data and not tied to anything else; declare nothing new, but if Play's review asks, answer: region id + IP, user-initiated, not linked to the user. The Maps SDK rows above still apply to every run that uses the Google map (other run types, no covering pack, or the user picks Google). Attribution (OSM, Protomaps, Mapterhorn, Copernicus DEM) is shown on the map and in Settings, About; the privacy page has section 2a. **Review before Play submission.** |

Offline maps (4-Oct): the user taps Download in Settings and the app fetches map files from our Cloudflare R2 bucket. The request carries the region picked and the IP address, plus a User-Agent naming the app and version. No new Play data type: the IP address is already covered by the approximate location row, and nothing is added to Device IDs or App activity. Re-check against the live form when Topo tiles land.

Since 4-Oct (checked 7-Oct-2026 against `AndroidManifest.xml` and the merged PRs): **no new permission** (the manifest is unchanged) and **no new data flow**.
- **Voice coaching** (#204) speaks through Android's on-device `TextToSpeech`, as the existing cues do; nothing is recorded, no `RECORD_AUDIO`, no new category.
- **Heart rate zones** (#193: % of max, reserve, custom) are local settings only. The strap's resting-HR readiness line (#189) is computed on the phone.
- **4-week plan, load guard, zone ladder, zone-coloured charts, splits labels, race times**: all computed on the phone from local runs.
- **Offline Topo maps** (#178, #181): already covered by the 4-Oct row above; `maplibre_gl` draws from the downloaded file with no Google SDK. The new `crypto` dependency only checks a pack's sha256.
- Fonts (Saira, Schibsted Grotesk) are bundled; nothing is fetched.
Re-check before each submit if the manifest or `pubspec.yaml` dependencies change.

Notes the founder should confirm against the live form (plan §18.6 leaves these to him):

1. Open-Meteo is declared as **collected** (the app itself sends the rounded coordinate to a service provider), not as **shared**.
2. The waitlist link opens a browser page; the browser form, not the app, collects the email. If Play's reviewer asks, the privacy page and the in-app copy already say so.
3. Whether a later Data safety change restarts the 14-day closed-test clock is unverified; the reason to declare everything in week 4, before the code that uses it all lands, is to never find out.

## 8. Foreground service permissions (FGS declaration)

Play Console → App content → **Foreground service permissions**. Declare the type **`location`** only. Copy:

> **Which foreground service type(s) does your app use?** Location.
>
> **Describe the user-facing feature that uses the foreground service:** Run Supreme records GPS pace and route during a running workout that the user starts by pressing Start. A persistent notification with LAP and Stop actions is shown for the whole run. The service starts only from the visible app in response to that tap, keeps recording while the screen is off or the user is in another app (music, for example), and stops when the user presses Stop in the app or the notification. There is no background location outside a run the user started, and recording never restarts on its own after the user stops it.
>
> **Why can this task not be completed without a foreground service?** Interval pace needs a continuous GPS sample stream for 30–60 minutes while the screen is off and the phone is in a pocket or armband; without a foreground service the process is suspended and pace and lap times are lost.
>
> **Demo video URL:** (unlisted YouTube link recorded per `docs/fgs-demo-video.md`; the 30-second phone version is at the top of that file. An emulator recording was judged unsuitable: it would show a debug package and replay mode, which the reviewer must not see).

Also true of the app and worth having ready if asked: `FOREGROUND_SERVICE_LOCATION` is declared in the manifest, the service is `START_NOT_STICKY`, `stopWithTask=false` only so the notification survives a task swipe while a run is live, and no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the setup checklist deep-links to the battery-optimisation settings page instead).

## 9. Government apps / Financial features / Health apps declarations

- Government app: **No**.
- Financial features: **None**.
- Health apps declaration (mandatory for every app now): app **does** have health features → **Activity and fitness tracking** (running workouts, heart rate from a paired strap). Not a medical device, no clinical or diagnostic claims, health data stays on the device unless the runner chooses to send it.
  - **Health Connect (Send runs, write only)**: answer that the app uses Health Connect. Data types and the justification to enter per type (Play asks for one each; all four are write only, and the app reads no Health Connect data):
    - Exercise (`WRITE_EXERCISE`): "Run Supreme saves each finished run as a running exercise session, with its laps and pauses, so the runner's run appears in their health apps."
    - Exercise route (`WRITE_EXERCISE_ROUTE`): "Saves the GPS route of the run (without the first and last 200 m) on the session so the runner can see the run's map in their health apps. Optional: runs are saved without it if the runner declines."
    - Heart rate (`WRITE_HEART_RATE`): "Saves the heart-rate readings from the runner's own chest strap during the run on the session."
    - Distance (`WRITE_DISTANCE`): "Saves the distance covered in the run on the session."
  - Off by default; switched on by the runner in Settings, Send runs to, or per run with Send. A privacy-policy screen is wired for Health Connect's permission page (`PrivacyPolicyActivity`, alias `ViewPermissionUsageActivity`; opens https://runsolo.app/privacy/). The policy page names the four permissions (section 4).
  - Before the Play submit: the Health Connect permissions form in Play Console must be completed for the new permissions, or the upload is blocked. Founder to confirm on submit.

## 10. News app / COVID / other

All **No**.

## 11. Testing track order (plan §11)

1. Internal testing: founder + a couple of devices from week 3 (Play-signed builds replace sideloaded `app.runsolo` release builds; dogfood `.dogfood` package stays).
2. Closed testing (Alpha): create the track, add the tester email list (≥ 15 recruited, ≥ 12 must stay opted in 14 continuous days, Google checks usage), submit for review with all the forms above done. See `docs/closed-test-testers.md`.
3. Production access questionnaire after the 14 days (week 7), then staged rollout 20% → 100%.

## 12. Founder checklist for the Maps key (plan §18.9)

1. Google Cloud project → enable **Maps SDK for Android** → billing account attached → budget alert at US$1 → per-day quota cap on the key (W9).
2. Create the API key. Application restriction: **Android apps**, entries for each package + SHA-1:
   - `app.runsolo` + upload key SHA-1 above
   - `app.runsolo` + **Play app-signing certificate SHA-1** (Play Console → Test and release → Setup → App signing, available after the first upload) — without this the Play build shows "Map failed to load"
   - `app.runsolo.dogfood` + dogfood key SHA-1 (`tools/print_cert_sha1.sh ~/.secrets/run-solo/<dogfood>.jks dogfood`)
   - `app.runsolo.debug` + your local `~/.android/debug.keystore` SHA-1 (CI's debug APK uses a per-runner debug key, so the emulator smoke never shows a map; that is expected)
   API restriction: **Maps SDK for Android** only.
3. Add it as repo secret `RUN_SOLO_MAPS_API_KEY` (`gh secret set RUN_SOLO_MAPS_API_KEY -R ricki2828/run-solo`). Builds pass without it; with it, `build-apk` stops warning.
4. Locally: `runsolo.mapsApiKey=...` in `android/local.properties` (gitignored) for `flutter run`.

## 13. Play submission: companion release

Applies to the first release where the Run companion can be switched on by anyone other than the founder. Plan: `~/ai/plans/run-supreme-companion.md` (B2). Do not ship it until every item below is done in the same release: the Data safety rows, the web deletion link, the store copy and the privacy page. Facts below were checked against `companion-server/companion/{db,service,writer,backup}.py` and `lib/state/companion.dart` on 10-Oct-2026.

### 13.1 Data safety: companion rows

Overview answers that change: "Is all user data encrypted in transit?" stays **Yes** (companion API, Telegram and Meta are HTTPS). "Do you provide a way to request deletion?" stays **Yes**, now with two paths: in the app (Settings, Companion, Delete everything) and the web link below. Enter the deletion URL as `https://runsupreme.taiaroa.xyz/delete/`. Play requires a link that works without the app, and `docs/delete/index.html` is that page.

Every row below: **Collected: Yes. Optional: yes** (off unless the user turns it on; "Not now" is equal weight). **Purpose: App functionality** only (no Analytics, no advertising). **Encrypted in transit: Yes.** **Deletable: Yes** (in-app, DELETE keyword in the chat, web link). **Ephemeral: No.**

| Category | Data type | What the companion holds | Shared? |
|---|---|---|---|
| Health and fitness | **Fitness info** | Per-run summary: type, start time, duration, distance, pace, True Pace, verdict, zone minutes, climb, and the Easy/Right/Hard tap. Never the GPS route or heart rate trace. | No (see note 1) |
| Location | **Approximate location** | The run's locality (suburb name, never the street), plus the time zone. | No |
| Personal info | **Phone number** | Only when WhatsApp is switched on: the user's WhatsApp number, which WhatsApp supplies when they message first. Not typed into the app. | No (Meta delivers the user's own chat) |
| App activity | **App interactions** | Feel taps, button answers (goal, race month, usual days, niggle area), and whether a suggestion was taken or skipped. | No |

Rows the founder did not list, added to over-declare (confirm on the live form):
- **Personal info, User IDs** and **Name**: the Telegram chat id and chat name the server stores for a Telegram user (the dogfood channel). Optional, App functionality.
- **Health and fitness, Health info**: the niggle answer (none, calf, knee, hip, foot, other). It expires after 8 weeks. Optional, App functionality.

Notes:
1. Shared with a processor, not "shared" in Play's sense, same basis as Open-Meteo above: OpenRouter and the model provider receive the run facts as sentences and the answers as fixed options, never the phone number, chat id or any typed text, with `data_collection: deny` and zero-retention routing. Founder to confirm on the live form that service-provider processing is not declared as sharing.
2. The base-release rows (Maps SDK) are unchanged.
3. Retention to state if Play asks: run summaries and answers until deleted or six months without a run; message log 30 days; backups 14 days (encrypted); Meta keeps WhatsApp messages up to 30 days.
4. The app's Health Connect and user-initiated Send rows are unchanged.

### 13.2 Store copy that must change

The base copy says "No account. Nothing uploaded." and "Your routes, times and heart rate stay on your phone unless you choose to send them." That stays true for the base app but is no longer true once the companion exists. Change before the release, in the listing and in `docs/closed-test-testers.md`.

- **Short description (72)**, replacing the one in section 1:
  `Run scores, honest verdicts and trail runs. See what is improving. Free.`
  (drops "No account". The app has no account to create, but the companion links to a chat, so the claim reads as too strong.)
- **Long description, first paragraph**, replacing "with no account and nothing uploaded":
  > Run Supreme is where you get better at your runs. It tells you honestly how you are progressing and what to run next, free, on your phone. There is no account to create.
- **Long description, "Private by default" paragraph**, replacing the first sentence:
  > No feed. No ads. Your routes, times and heart rate stay on your phone unless you choose to send them. The optional Run companion is off until you turn it on. If you do, a short summary of each run (no GPS route, no heart rate trace) goes to our server and the notes reach you in Telegram. You can delete it all in the app or from the web at runsupreme.taiaroa.xyz/delete.
- **Closed-test message** in `docs/closed-test-testers.md`: replace "No account, no ads, your runs stay on your phone." with "No account to create, no ads. Your runs stay on your phone unless you turn on the optional Run companion."
- **Screenshots and graphic**: re-check any frame that says "Nothing uploaded".
- **Health apps declaration (section 9)**: add that health data leaves the device only if the runner turns on the companion or sends a file, and then goes to our server in Germany.

### 13.3 Submission checklist

1. Privacy page section 2b and `/delete/` are live at runsupreme.taiaroa.xyz. Deletion email address on `/delete/` is privacy@taiaroa.xyz.
2. Data safety form updated per 13.1, and the deletion URL entered.
3. Store copy per 13.2 pasted into the listing.
4. The server enrol allowlist and the dogfood compile flag are off only when the above are done (plan B2).
5. WhatsApp stays off until Meta business verification, the approved templates and the written AI-policy check exist (`~/Files/RunSupreme/whatsapp/PROMPTS.md`). The first release can ship Telegram only; the phone number row is then not collected, and the form can omit it until WhatsApp ships. Data safety changes later need the form updated before the release that uses them.
6. CI ignores `docs/**`, so none of the above is checked by a pipeline. Check by hand.
