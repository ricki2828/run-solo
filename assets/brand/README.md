# Run Supreme brand: "Track Bend" (direction C, Munich lanes)

Production vectors for the logo the founder chose on 26-Oct-2026 (direction C of the logo round, replacing the Lap Line R). The mark is five lanes of a 400 m bend seen from above, open to the right: straight, bend, straight, a "C" laid on its side. Z1 is the outer lane and Z5 the inner one, in the zone ramp (`HrZones.distributionLight` #2F6DB5 #2E9E5B #D9A21B #E86A1C #D6283B; `distributionDark` on dark), separated by thin gaps (the lane lines). Inner lanes end shorter on the right, the 400 m stagger. The wordmark is RUN SUPREME in Barlow Condensed Bold with five thin zone stripes under it.

The generator draws everything as outlined filled paths, so the files have no live text, strokes, masks or clip paths. The same path data works in SVG and in Android VectorDrawable.

## Files

| File | Use |
|---|---|
| `svg/mark-on-light.svg`, `svg/mark-on-dark.svg` | Mark in the light / dark zone ramp |
| `svg/mark-mono-black.svg`, `svg/mark-mono-white.svg` | One colour, lane gaps kept |
| `svg/wordmark-*.svg` | RUN SUPREME with its five stripes, same four treatments (ink `#121417` on light, Bone on dark) |
| `svg/icon/ic_launcher_{foreground,background,monochrome,full}.svg` | Adaptive icon layers on the 108 dp canvas. `full` is a flattened preview |
| `svg/icon/ic_launcher_safe-zone-guide.svg` | Review aid: 108 dp canvas, 72 dp mask, 66 dp safe zone |
| `svg/icon/splash_icon.svg` | Android 12 splash icon, 288 dp canvas, mark inside the 192 dp circle |
| `svg/icon/ic_stat_runsupreme.svg` | 24 dp notification small icon, white on transparent, three lanes |

Generated straight into the app and the store folder (do not hand-edit; regenerate):

| File | Use |
|---|---|
| `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | Adaptive icon with a `<monochrome>` layer (Android 13+ themed icons). minSdk 29 makes the adaptive icon universal |
| `res/drawable/ic_launcher_{foreground,background,monochrome}.xml` | The three layers. Background is a white tile |
| `res/drawable/ic_stat_runsupreme.xml` | Notification small icon, used by `RecorderNotification` with `setColor(#2F6DB5)`, the Z1 blue (the old teal accent no longer exists in the brand) |
| `res/drawable/splash_icon.xml` | Android 12 splash icon, on the light `window_ground` `#FBFBF9` |
| `lib/brand/track_bend_paths.dart` | Flutter paths: five lane centrelines (stroke with `laneStroke`, butt caps) and the wordmark outline. Used by `lib/brand/track_bend.dart`, the in-app marks (`TrackBendMark`, `TrackBendDrawMark` in `lib/widgets/chrome.dart`) and the intro (`lib/splash/track_bend_intro.dart`) |
| `store/play/icon-512.png` | Play Store icon, 512 x 512, the launcher artwork cropped to the central 80 dp |
| `ios/.../AppIcon.appiconset/Icon-App-1024x1024@1x.png` | iOS icon, RGB, no alpha |
| `store/play/feature-graphic-wordmark-1024x500.png` | Alternate Play feature graphic (the primary is built by `store/play/build_screens.py`): wordmark with stripes left, large mark right, on the light ground. `--hero` blends the licensed photo at 12 % |

## Geometry

- Lane `k` (0 = Z1) has centre radius `r0 + pitch * (n - 1 - k) + pitch / 2` about the bend centre, stroke `pitch - gap`, and its straights end `stagger` earlier per lane going inward. Specs in `build_brand.py`:
  - Mark (masters, splash, Dart): pitch 4.2, gap 0.9, r0 4.0, straight 28, stagger 3.2 (mark units).
  - Launcher and splash icon, seen at 48 px: gap 1.5 (a third of the pitch), tighter bend, straight 15, so the lane gaps stay visible and the mark fills the circle.
  - Notification icon: three lanes (Z1, Z3, Z5), gap 2.2, since five close up at 24 dp.
- Launcher: every path point sits within 32 dp of the centre (the safe zone is 33 dp). The monochrome layer uses the same transform, one colour, gaps kept.
- Wordmark: Barlow Condensed Bold (`assets/fonts`, OFL), shaped with HarfBuzz using kerning, tracking +20. Stripes 5.5 % of cap height thick on a 7.1 % pitch, starting 13.7 % of cap height under the baseline, as wide as the word.
- Splash (`track_bend_intro.dart`): lanes draw on from the top straight round the bend, Z1 first, the others starting 40 ms apart; first launch of a version then sets the wordmark under the mark and draws the stripes left to right; exit by about 1400 ms. The short intro (every other cold start) is the lanes only, 600 ms. Light ground, flat colours. Reduced motion shows the final frame for 300 ms.

Regenerate after any change (the Android XML and Dart are generated; do not hand-edit them):

```
python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install -r assets/brand/requirements.txt
/tmp/brandvenv/bin/python assets/brand/build_brand.py            # add --hero store/art/hero.jpg once licensed
```

Dependencies are pinned in `requirements.txt`. Running twice gives byte-identical output (checked for the PNGs).

## Trademark and look-alike check (Track Bend, 26-Oct)

- **Supreme box logo:** white Futura Heavy Oblique in a red rectangle. Nothing here is red-boxed or slanted; the wordmark never sits in a box, and SUPREME never appears alone. The icon carries no word, only lanes. A zone colour (Z5 red) appears only as one lane, never as a ground.
- **Olympic rings:** the risk with coloured lanes is a read as interlocking rings. The mark is one shape: concentric, nested and non-overlapping lanes, never circles, never interlocked, on a single centre. Keep it that way: no ring or full circle, no five-colour row of circles, no overlap between lanes. The colours are the zone ramp (blue, green, amber, orange, red), not the Olympic blue, yellow, black, green, red set, and there is no black.
- **Colour:** flat fills only, no gradients.
- **Residual:** themed icons take their tint from the wallpaper; a single colour of concentric lanes is still not a ring set. The name risk sits with the word "Supreme" (D11: a paid clearance search before public launch or any apparel), not with the artwork.

## Not verified

- The drawables compile in CI (the Gradle build and emulator job); they cannot be compiled on the build host, whose SDK copy is the wrong architecture.
- Legibility at 48 px was checked on a rendered mock home screen with plain placeholder tiles (Python rasteriser, same path data), not on a phone next to real icons. Still open: a device screenshot on a real home screen, and the intro seen running on a device (the preview keyframes are a Python approximation of the Dart animation).
- Kerning in the wordmark has had no human designer pass.
