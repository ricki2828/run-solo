#!/usr/bin/env bash
# Ricki runs this himself, once, in a terminal. It installs the open-source (Apache-2.0)
# connect-iq-sdk-manager-cli, has YOU read and accept Garmin's licence and log in, then downloads
# the devices listed in products.txt into ~/.Garmin/ConnectIQ/Devices (the folder monkeyc reads).
# Credentials are typed by you at Garmin's own prompt/browser flow; this script never reads, stores
# or logs them. Re-run any time to add devices (edit products.txt first).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
VER=0.8.4
bindir="$HOME/.local/share/garmin-ciq-cli"
bin="$bindir/connect-iq-sdk-manager"

if [ ! -x "$bin" ]; then
  case "$(uname -m)" in aarch64|arm64) arch=ARM64;; x86_64) arch=x86_64;; *) echo "unsupported arch $(uname -m)" >&2; exit 1;; esac
  tgz="connect-iq-sdk-manager-cli_${VER}_Linux_${arch}.tar.gz"
  base="https://github.com/lindell/connect-iq-sdk-manager-cli/releases/download/v${VER}"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$base/$tgz" -o "$tmp/$tgz"
  curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt"
  (cd "$tmp" && grep " $tgz\$" checksums.txt | sha256sum -c -)
  mkdir -p "$bindir"; tar -xzf "$tmp/$tgz" -C "$bindir"
  [ -x "$bin" ] || { echo "binary not found after extract; contents:" >&2; ls "$bindir" >&2; exit 1; }
fi
"$bin" --help >/dev/null

echo "== 1. Garmin Connect IQ licence (read it, then accept) =="
"$bin" agreement view; echo "Read the agreement at the URL above."
read -r -p "Accept the Garmin Connect IQ licence agreement? [y/N] " yn
[ "$yn" = y ] || { echo "not accepted, stopping"; exit 1; }
"$bin" agreement accept

echo "== 2. Log in (Garmin SSO; follow the prompt/URL it prints; type credentials only there) =="
"$bin" login

echo "== 3. Devices from products.txt =="
devs=()
while read -r line; do line="${line%%#*}"; line="$(echo "$line" | xargs || true)"; [ -n "$line" ] && devs+=("$line"); done < "$here/products.txt"
args=(); for d in "${devs[@]}"; do args+=(-d "$d"); done
"$bin" device download "${args[@]}" || echo "device download reported errors (unknown ids are expected in products.txt); check below"

echo "== Result =="
ls "$HOME/.Garmin/ConnectIQ/Devices" 2>/dev/null | head -80 || echo "no ~/.Garmin/ConnectIQ/Devices; see where the CLI put them: $bin device list --help"
