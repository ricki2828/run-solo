#!/usr/bin/env bash
# Compiles one signed .prg per device on THIS host (monkeyc is Java, runs on aarch64). Needs the
# devices from fetch-devices.sh in ~/.Garmin/ConnectIQ/Devices. The SDK is downloaded straight from
# Garmin into ~/.local/share/garmin-ciq-sdk (not committed, not republished). The developer key is
# generated once and kept in ~/.secrets/run-supreme/garmin (mode 600, never in the repo); BACK IT UP
# off this box, a lost key blocks store updates of the same app id.
#   OUT   output dir (default ~/.cache/run-supreme-garmin/out)   SDK_VERSION (default 9.3.0)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
SDK_VERSION="${SDK_VERSION:-9.3.0}"
sdkdir="$HOME/.local/share/garmin-ciq-sdk/$SDK_VERSION"
keydir="$HOME/.secrets/run-supreme/garmin"
key="$keydir/developer_key.der"

if [ ! -f "$sdkdir/bin/monkeybrains.jar" ]; then
  url="$(SDK_VERSION="$SDK_VERSION" python3 -I - <<'PY'
import json, os, urllib.request
d = json.load(urllib.request.urlopen("https://developer.garmin.com/downloads/connect-iq/sdks/sdks.json"))
print("https://developer.garmin.com/downloads/connect-iq/sdks/" + next(x["linux"] for x in d if x["version"] == os.environ["SDK_VERSION"]))
PY
)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/sdk.zip"
  mkdir -p "$sdkdir"
  python3 -I -c "import zipfile,sys;z=zipfile.ZipFile(sys.argv[1]);z.extractall(sys.argv[2],[n for n in z.namelist() if n.startswith('bin/')])" "$tmp/sdk.zip" "$sdkdir"
fi

if [ ! -f "$key" ]; then
  umask 077; mkdir -p "$keydir"
  openssl genrsa -out "$keydir/developer_key.pem" 4096 2>/dev/null
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "$keydir/developer_key.pem" -out "$key" -nocrypt
  echo "generated developer key at $keydir (back it up off this server)"
fi

export CIQ_SDK="$sdkdir" CIQ_KEY="$key" OUT="${OUT:-$HOME/.cache/run-supreme-garmin/out}"
"$here/tools/build.sh"
echo "prg files in $OUT"
