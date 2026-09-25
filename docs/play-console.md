# Play Console: App content and listing answers (week 4)

Draft answers for every Play Console form Run Supreme must submit before the first closed-track
release. Source of truth for the claims: plan §10, §11, §18.3, §18.6 (v5.4) and the design brief
§6 + addendum A7. Where two documents disagree the difference is flagged for the founder.

Founder approves the wording (plan §18.9 item 8) before anything is typed into the Console.

## 0. Prerequisites

| Item | Value | Status |
|---|---|---|
| Package name | `app.runsolo` (Play build only; `.debug` and `.dogfood` never go to Play) | fixed |
| Privacy policy URL | `https://runsolo.app/privacy` (served from this repo's `docs/` via GitHub Pages while the repo is public; when it goes private at launch the page moves to a public host with the same URL, see README) | founder: turn Pages on + DNS |
| Play App Signing | Enrol at first upload; Google holds the app-signing key, we upload with `CN=Run Solo upload` | first AAB upload |
| Upload key SHA-1 | `6D:E0:ED:82:5F:B7:80:73:3A:C5:EC:9D:37:5F:8F:63:1F:6E:D0:57` | for the Maps key restriction |
| Trademark | "Supreme" is a well-known registered streetwear mark (Supreme / VF Corp). "Run Supreme" for a running app is a different class, but the founder should run the trademark search (plan Phase 0) again for the new name before the listing goes live, and avoid Supreme's red-box logo styling anywhere | founder: open |
| Domain | `runsolo.app` URLs are kept until the founder decides on a Run Supreme domain; the privacy URL on the Play forms must not change afterwards, so decide before week 4 | founder: open |
| Contact email in the listing | `privacy@runsolo.app` is used on the privacy page | founder: confirm the mailbox exists or change it |

## 1. Store listing

- **App name (30 chars)**: `Run Supreme: 4x4 Interval Run` (29). The brief's alternative
  `Run Supreme: Norwegian 4x4 Run` is 30, at the limit; founder picks.
- **Short description (80)**: `4x4 interval timer with GPS pace. Tells you if you beat your last run.` (70)
- **Long description**: design brief §6, with the A7 privacy paragraph replacing the older line:

> Run Supreme is a Norwegian 4x4 timer that records your pace with GPS and tells you, in one word, whether you beat your last 4x4.
>
> Warm up as long as you like, tap START 4x4, and the app runs every rep and recovery with voice and vibration cues, so your phone can stay in your pocket. When you stop, you get the verdict: FASTER, HOLDING or SLOWER, with the rep paces, fade and recovery pace that decided it. Small differences inside GPS noise are called what they are: no real change.
>
> Pair any Bluetooth heart rate strap, including Whoop broadcast, and Run Supreme adds time in zone and tells you when you ran faster at the same effort.
>
> Free runs get a clean summary. Every 4x4 goes on a trend line with your bests. Follow a fixed 8-week 4x4 plan or a 5k plan: pick your days, tick sessions off, start the right session from the plan.
>
> No account. No feed. No ads. No analytics of our own. Your recorded route, times and heart rate stay on your phone. Map tiles come from Google, which sees the map area you view and your IP address, like any maps app. Weather comes from Open-Meteo using your location rounded to about 10 km. Export JSON or TCX any time.
>
> Coming in the paid version: tempo and easy-run verdicts, adaptive plans, iOS. Join the waitlist inside the app.

- **Category**: Health & Fitness. **Tags**: Running, Fitness tracker, Interval training.
- **Countries**: English-speaking non-EU per plan §10: AU, NZ, US, CA, GB, SG, ZA. (IE is EU, so not in the list.)
- **Graphics**: icon `store/play/icon-512.png` (Lap Line R), feature graphic `store/play/feature-graphic-1024x500.png` (vector version until the hero photo is licensed, `store/art/LICENSES.md`); both rebuilt by `assets/brand/build_brand.py`; 6 screenshots 1080x2400 with the brief's captions; HR pairing as #7 if there is room. No Hyrox marks or keywords anywhere.
- **Contact details**: email above; website `https://runsolo.app`.

## 2. Privacy policy

URL: `https://runsolo.app/privacy`. Also linked in-app from Settings, About. Content = `docs/privacy/index.html`.

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

Data types. "Collected" in Play's sense includes what the Maps SDK sends to Google from inside the app. Purposes: **App functionality** everywhere; **Analytics** added to Device or other IDs because Google states the SDK identifier measures daily active SDK users. Nothing is "shared" (transferred to a third party) in Play's definition: Google and Open-Meteo act as service providers for the app's own functionality. Nothing is optional except weather (the user can turn it off), and the Maps data is only sent when the user opens a run's detail.

| Category | Data type | Collected? | Shared? | Ephemeral? | Required or optional | Purposes | Why (for the founder) |
|---|---|---|---|---|---|---|---|
| Location | **Precise location** | Yes | No | No (Google retains map camera/interaction events "to improve Google services") | Required (the post-run map has no toggle) | App functionality, **Analytics** | Post-run map fits the camera to the route at zoom 15/16 and the full-screen map is panned/zoomed; the camera events Google receives describe an area smaller than Play's ~3 km² "approximate" threshold (R1) |
| Location | **Approximate location** | Yes | No | No | Required for the map's IP-derived part; the Open-Meteo part is optional (weather toggle) | App functionality, **Analytics** | Maps SDK derives it from the IP and Google says IP + request metadata are used "to understand SDK usage"; Open-Meteo gets the run location rounded to ~10 km |
| Device or other IDs | **Device or other IDs** | Yes | No | No | Required (part of the Maps SDK whenever a map loads) | App functionality, **Analytics** | Maps SDK identifier used by Google to measure daily active SDK users |
| App activity | **App interactions** | Yes | No | No | Required | App functionality, **Analytics** | Google lists "map interaction events (panning, zooming)" as its own collected item; Play's matching type is App interactions. Plan §18.6 did not cover this category; declared to over- rather than under-declare |
| App info and performance | **Crash logs** | Yes | No | No | Required | App functionality | Maps SDK crash reporting (Google's disclosure) |
| App info and performance | **Diagnostics** | Yes | No | No | Required | App functionality, **Analytics** | Maps SDK request metadata / performance data, used by Google "to understand SDK usage" |
| Health and fitness | Health info / Fitness info | **No** | No | | | | Heart rate, pace, route files stay on the device; never transmitted by us. Auto Backup is a system feature under the user's Google account and Play's guidance excludes it. |
| Personal info | any | No | | | | | No account, no name, no email |
| Financial info | any | No | | | | | |
| Messages / Photos / Audio / Files / Calendar / Contacts / Web browsing / Search history | any | No | | | | | TTS cues are generated on-device; nothing recorded |

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
> **Demo video URL:** (unlisted YouTube link recorded per `docs/fgs-demo-video.md`).

Also true of the app and worth having ready if asked: `FOREGROUND_SERVICE_LOCATION` is declared in the manifest, the service is `START_NOT_STICKY`, `stopWithTask=false` only so the notification survives a task swipe while a run is live, and no `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (the setup checklist deep-links to the battery-optimisation settings page instead).

## 9. Government apps / Financial features / Health apps declarations

- Government app: **No**.
- Financial features: **None**.
- Health apps declaration (mandatory for every app now): app **does** have health features → **Activity and fitness tracking** (running workouts, heart rate from a paired strap). Not a medical device, no clinical or diagnostic claims, health data stays on the device, no Health Connect integration in v1 (Phase 2 backlog; when it lands the declaration and Data safety are updated together).

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
