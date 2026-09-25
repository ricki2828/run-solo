# Run Supreme brand: "Lap Line" (B1, wired in B2)

These are the production vectors for the logo the founder chose on 25-Sep (plan `run-supreme-phase3-plan.md` §5, D9). The mark is a condensed R cut by the lap line at 40% of cap height. The Arc lap line runs through the cut and leaves to the right. The wordmark RUN SUPREME carries the same cut, with a dash after the word.

The generator draws everything as outlined, boolean-cut filled paths, so the files have no live text, masks or clip paths. The same path data works in SVG and in Android VectorDrawable.

## Files

| File | Use |
|---|---|
| `svg/mark-on-dark.svg`, `svg/mark-on-light.svg` | R mark, Bone + Arc `#19E6FF` / ink `#0F1114` + Arc light `#0098B2` |
| `svg/mark-mono-black.svg`, `svg/mark-mono-white.svg` | One colour. The lap line appears only as the tail outside the letter, so the cut stays readable |
| `svg/wordmark-*.svg` | RUN SUPREME in the same four treatments |
| `svg/icon/ic_launcher_{foreground,background,monochrome,full}.svg` | Adaptive icon layers on the 108 dp canvas. `full` is a flattened preview |
| `svg/icon/ic_launcher_safe-zone-guide.svg` | Review aid: 108 dp canvas, 72 dp mask, 66 dp safe zone |
| `svg/icon/splash_icon.svg` | Android 12 splash icon, 288 dp canvas, mark inside the 192 dp circle |
| `svg/icon/ic_stat_runsupreme.svg` | 24 dp notification small icon, white on transparent |

Generated straight into the app and the store folder (do not hand-edit; regenerate):

| File | Use |
|---|---|
| `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml` | Adaptive icon with a `<monochrome>` layer (Android 13+ themed icons). The Flutter PNG mipmaps are deleted; minSdk 29 makes the adaptive icon universal |
| `res/drawable/ic_launcher_{foreground,background,monochrome}.xml` | The three layers |
| `res/drawable/ic_stat_runsupreme.xml` | Notification small icon, used by `RecorderNotification` with `setColor(#19E6FF)` |
| `res/drawable/splash_icon.xml` | Android 12 splash icon. Not referenced yet: B3 sets it as `windowSplashScreenAnimatedIcon` on `#0A0B0D` |
| `store/play/icon-512.png` | Play Store icon, 512 x 512, the launcher artwork cropped to the central 80 dp (Play masks the corners) |
| `store/play/feature-graphic-1024x500.png` | Play feature graphic: wordmark left, large R right, one lap line through both. Vector version; `--hero` adds the licensed photo (`store/art/LICENSES.md`) |

## Geometry (font units, cap height 700)

- Typeface: Barlow Condensed Bold (`assets/fonts`, OFL). Shaped with HarfBuzz using kerning, tracking +20 (2% of the em, brief §2.2).
- Cut: centred at 40% of cap height. It is 7.5% of cap height in the mark and wordmark, 12% in the launcher and splash icons (seen at 48 px), and 15% in the 24 dp notification icon.
- Lap line: 60% of the cut thickness (8% of cap height in the icons), with a round leading end. In colour it enters at the leg, so it shows through the leg's cut. In the mark it runs 0.25 cap past the R, 0.2 cap in the icons. In the wordmark it is a separate dash 0.76 cap long, 0.18 cap after the E.
- Launcher: every path point sits within 30 dp of the centre (the safe zone is 33 dp, so about a 9% inset; at 32 dp the R looked oversized next to other running apps). Notification icon: 2 dp padding on the 24 dp grid. The monochrome layer uses the same transform as the colour layer.

Regenerate after any change (the Android XML is generated; do not hand-edit it):

```
python3 -m venv /tmp/brandvenv && /tmp/brandvenv/bin/pip install -r assets/brand/requirements.txt
/tmp/brandvenv/bin/python assets/brand/build_brand.py            # add --hero store/art/hero.jpg once licensed
```

Dependencies are pinned in `requirements.txt`. Running twice gives byte-identical output (checked for the PNGs).

## Supreme box-logo check (re-done on the production mark, 25-Sep)

The mark to avoid is white Futura Heavy Oblique in a filled red rectangle.

- **Type:** Barlow Condensed is an upright, condensed grotesk. Futura is a geometric typeface, not condensed, set oblique in that mark. None of these files is slanted.
- **Colour:** black, Bone and Arc teal. No red appears anywhere, and no colourway may add it.
- **Container:** the wordmark never sits in a box. The launcher icon is a filled shape only because Android masks every icon. Its content is a single upright R with the cut, not a word.
- **Word:** SUPREME never appears alone, and the icon carries no word at all.
- **Residual:** themed icons take their tint from the wallpaper, so a red wallpaper gives a pale pink tile with a dark R. That tile is still an upright letter with a cut, not white oblique text on red. We cannot control it, and the risk is low.
- The plan (§5, §9) says the condensed R sits near the box logo's typographic register. That overstates it: the box logo is not condensed type. The mark and name risk sits with the word "Supreme" (D11: a paid clearance search before public launch or any apparel), not with the letterform.

## Not verified

- The drawables compile in CI (the Gradle build and emulator job); they cannot be compiled on the build host, whose SDK copy is the wrong architecture.
- Legibility at 48 px was checked on a rendered mock home screen with plain placeholder tiles, not next to the real NRC, Strava and Runna icons on a phone. Still open: a device screenshot on a real home screen.
- Kerning in the wordmark has had no human designer pass (brief §7 keeps that for post-gate).
