#!/usr/bin/env bash
# deploy_site.sh [--dry-run] [--ref <git ref>]
# Publish the public pages (docs/index.html, docs/privacy/, docs/delete/) to https://runsupreme.taiaroa.xyz.
# The site is a static copy in ~/sites/run-supreme, linked to the Vercel project run-supreme-site; nothing syncs it
# from the repo, so every change to those pages needs this run (docs/RELEASE.md, "Public site").
#   1. back up ~/sites/run-supreme to ~/sites/run-supreme.bak-<UTC timestamp>
#   2. export the pages from <ref> (default origin/main) with `git archive`, never the working tree, and rsync them in
#   3. `vercel deploy --prod --yes` in ~/sites/run-supreme
#   4. fetch each page live: the body must equal the source byte for byte, and a page with "Last updated <date>"
#      must show the source's date. Exit non-zero if any page does not match.
# --dry-run: export and show what rsync would change, then stop (no backup, no copy, no deploy, no check).
# Env overrides (for tests): SITE_DIR, SITE_URL.
set -euo pipefail

ref="origin/main"
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --ref) ref="${2:?--ref needs a value}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
site="${SITE_DIR:-$HOME/sites/run-supreme}"
url="${SITE_URL:-https://runsupreme.taiaroa.xyz}"
pages=(index.html privacy/index.html delete/index.html)

[ -d "$site/.vercel" ] || { echo "$site is not the linked Vercel project (no .vercel/)" >&2; exit 2; }
case "$ref" in origin/*) git -C "$repo" fetch -q origin ;; esac
sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}")

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
git -C "$repo" archive "$sha" docs/index.html docs/privacy docs/delete | tar -x -C "$src"
for p in "${pages[@]}"; do
  [ -s "$src/docs/$p" ] || { echo "docs/$p missing at $ref" >&2; exit 1; }
done
echo "source: $ref = ${sha:0:12}"

sync() {  # $1 = extra rsync flags; index.html alone, the two folders mirrored (files gone from docs/ go from the site too)
  rsync -a $1 "$src/docs/index.html" "$site/index.html"
  rsync -a --delete $1 "$src/docs/privacy/" "$site/privacy/"
  rsync -a --delete $1 "$src/docs/delete/" "$site/delete/"
}

if [ "$dry" = 1 ]; then
  echo "dry run: rsync would change (nothing is copied or deployed):"
  sync "--dry-run --itemize-changes --checksum"
  exit 0
fi

bak="$site.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "$site" "$bak"
echo "backup: $bak"
sync "--checksum"

(cd "$site" && vercel deploy --prod --yes)

fail=0
for p in "${pages[@]}"; do
  path="/${p%index.html}"
  live=$(curl -fsS --retry 3 --retry-delay 5 -H 'Cache-Control: no-cache' "$url$path") || { echo "FAIL $path: fetch failed"; fail=1; continue; }
  want=$(grep -o 'Last updated [0-9]\{1,2\} [A-Z][a-z]* [0-9]\{4\}' "$src/docs/$p" | head -1 || true)
  if [ -n "$want" ] && ! grep -qF "$want" <<< "$live"; then
    got=$(grep -o 'Last updated [0-9]\{1,2\} [A-Z][a-z]* [0-9]\{4\}' <<< "$live" | head -1 || true)
    echo "FAIL $path: source says '$want', live says '${got:-no date}'"; fail=1; continue
  fi
  if [ "$(printf '%s' "$live" | sha256sum)" != "$(printf '%s' "$(cat "$src/docs/$p")" | sha256sum)" ]; then
    echo "FAIL $path: live body differs from docs/$p at ${sha:0:12}"; fail=1; continue
  fi
  echo "ok   $path${want:+ ($want)}"
done
if [ "$fail" != 0 ]; then
  echo "live site does not match ${sha:0:12}. Roll back: restore $bak over $site and run vercel deploy --prod --yes there." >&2
  exit 1
fi
echo "deployed ${sha:0:12} to $url"
