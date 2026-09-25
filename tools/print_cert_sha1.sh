#!/usr/bin/env bash
# Print the SHA-1 / SHA-256 of a signing certificate, for the Maps API key's Android-app
# restriction (plan §18.3: one entry per package name + SHA-1).
# Usage: tools/print_cert_sha1.sh <keystore.jks> <alias>      (prompts for the store password)
#        tools/print_cert_sha1.sh --debug                      (~/.android/debug.keystore, androiddebugkey)
set -euo pipefail
if [ "${1:-}" = "--debug" ]; then
  KS="$HOME/.android/debug.keystore"; ALIAS=androiddebugkey; PASS=android
  keytool -list -v -keystore "$KS" -alias "$ALIAS" -storepass "$PASS" 2>/dev/null | grep -E 'SHA1:|SHA256:'
  exit 0
fi
KS="${1:?keystore path}"; ALIAS="${2:?alias}"
keytool -list -v -keystore "$KS" -alias "$ALIAS" 2>/dev/null | grep -E 'SHA1:|SHA256:'
