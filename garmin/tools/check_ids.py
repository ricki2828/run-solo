"""Fails unless the watch manifest id, the Rez AppId string and the Android GarminSpike.APP_ID agree
(Phase 0 exit check f: the sideloaded app id must be the one the phone addresses)."""
import re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
manifest = re.search(r'<iq:application[^>]*\bid="([0-9a-f]+)"', (root / "garmin/manifest.xml").read_text()).group(1)
rez = re.search(r'id="AppId">([0-9a-f]+)<', (root / "garmin/resources/strings/strings.xml").read_text()).group(1)
kt = next((root / "android/app/src/dogfood").rglob("GarminSpike.kt")).read_text()
android = re.search(r'APP_ID\s*=\s*"([0-9a-f]+)"', kt).group(1)
print(f"manifest={manifest} rez={rez} android={android}")
if not (manifest == rez == android and len(manifest) == 32):
    sys.exit("app id mismatch between manifest.xml, strings.xml and GarminSpike.kt")
