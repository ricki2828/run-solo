#!/usr/bin/env bash
# Split the native debug symbols out of a signed Play AAB and re-sign it.
#
# ndk.debugSymbolLevel = FULL puts ~109 MiB of .dbg files in BUNDLE-METADATA, which is 70% of the
# 155 MiB 0.1.0 bundle. Play never ships them to devices, but they bloat the upload. Play also
# accepts the same files as a separate "native debug symbols" zip, so: collect them into that zip
# (layout <abi>/<lib>.so.dbg, what the Console expects), delete them from the bundle, and re-sign.
#
# Usage: split_native_symbols.sh <in.aab> <out-symbols.zip>
# Env (same as the release-aab job): RUN_SOLO_UPLOAD_KEYSTORE, RUN_SOLO_UPLOAD_STORE_PASSWORD,
#   RUN_SOLO_UPLOAD_KEY_ALIAS, RUN_SOLO_UPLOAD_KEY_PASSWORD. The AAB is rewritten in place.
set -euo pipefail

aab=${1:?aab path}
out_zip=${2:?output zip path}
prefix='BUNDLE-METADATA/com.android.tools.build.debugsymbols/'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! unzip -l "$aab" | grep -q "$prefix"; then
  echo "no native debug symbols in $aab" >&2
  exit 1
fi

before=$(stat -c %s "$aab")
unzip -q "$aab" "${prefix}*" -d "$work"
out_abs=$(realpath -m "$out_zip")
mkdir -p "$(dirname "$out_abs")"
rm -f "$out_abs"
(cd "$work/${prefix}" && zip -q -r "$out_abs" .)

# Drop the symbols and the old signature, then sign again with the same upload key.
zip -q -d "$aab" "${prefix}*" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' 'META-INF/MANIFEST.MF'
jarsigner \
  -keystore "$RUN_SOLO_UPLOAD_KEYSTORE" \
  -storepass:env RUN_SOLO_UPLOAD_STORE_PASSWORD \
  -keypass:env RUN_SOLO_UPLOAD_KEY_PASSWORD \
  "$aab" "${RUN_SOLO_UPLOAD_KEY_ALIAS:-upload}" > /dev/null

after=$(stat -c %s "$aab")
echo "AAB ${before} -> ${after} bytes; native symbols zip $(stat -c %s "$out_abs") bytes"
