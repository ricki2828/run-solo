#!/usr/bin/env bash
# K0 spike CI body (macOS runner). Every phase runs even if an earlier one failed; each writes
# logs/<phase>.log and a "phase=rc (Ns)" line to logs/status.txt. ci_digest.py summarises.
set -u
cd "$(dirname "$0")"
SPIKE=$PWD
LOGS=$SPIKE/logs
mkdir -p "$LOGS"
: > "$LOGS/status.txt"

phase() { # phase <name> <command...>
  local name=$1; shift
  local t0=$SECONDS
  ( "$@" ) > "$LOGS/$name.log" 2>&1
  local rc=$?
  echo "$name=$rc ($((SECONDS - t0))s)" >> "$LOGS/status.txt"
  echo "::group::$name rc=$rc $((SECONDS - t0))s"; tail -n 15 "$LOGS/$name.log"; echo "::endgroup::"
  return $rc
}

SIM_NAME=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
ios=[(r,x) for r,xs in d.items() if "iOS" in r for x in xs if x["name"].startswith("iPhone")]
ios.sort(key=lambda p: p[0])
print(ios[-1][1]["name"] if ios else "")')
SIM_UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
ios=[(r,x) for r,xs in d.items() if "iOS" in r for x in xs if x["name"].startswith("iPhone")]
ios.sort(key=lambda p: p[0])
print(ios[-1][1]["udid"] if ios else "")')

{
  echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
  echo "swift=$(swift --version 2>&1 | head -1)"
  echo "macos=$(sw_vers -productVersion) $(uname -m)"
  echo "java=$(java -version 2>&1 | head -1)"
  echo "kotlin=$(grep -o 'multiplatform") version "[^"]*' kmp-core/build.gradle.kts | cut -d'"' -f3)"
  echo "gradle=$(grep -o 'gradle-[0-9.]*-bin' kmp-core/gradle/wrapper/gradle-wrapper.properties)"
  echo "sim=$SIM_NAME"
} > "$LOGS/versions.txt"

G="./gradlew --no-daemon --continue '-Pk0.simDevice=$SIM_NAME'"
fail=0
phase port python3 kmp-core/port.py || fail=1
phase test bash -c "cd kmp-core && $G jvmTest macosArm64Test iosSimulatorArm64Test" || fail=1
phase xcf bash -c "cd kmp-core && $G assembleRunCoreReleaseXCFramework" || fail=1
XCF=kmp-core/build/XCFrameworks/release/RunCore.xcframework
{
  echo "xcframework $(du -sk "$XCF" 2>/dev/null | cut -f1) KB"
  for s in "$XCF"/*/; do echo "  $(basename "$s"): $(du -sk "$s" | cut -f1) KB (binary $(du -k "$s"/RunCore.framework/RunCore 2>/dev/null | cut -f1) KB)"; done
} > "$LOGS/sizes.txt" 2>&1
rm -rf swift/RunCore.xcframework && cp -R "$XCF" swift/ 2>/dev/null
phase swift_macos bash -c "cd swift && swift test" || fail=1
SCHEME=$(cd swift && xcodebuild -list -json 2>/dev/null | python3 -c '
import json,sys
w=json.load(sys.stdin); s=(w.get("workspace") or w.get("project") or {}).get("schemes", [])
print(next((x for x in s if x.endswith("-Package")), s[0] if s else "RunCoreSmoke"))')
echo "scheme=$SCHEME" >> "$LOGS/versions.txt"
phase swift_ios bash -c "cd swift && xcodebuild test -scheme $SCHEME -destination 'platform=iOS Simulator,id=$SIM_UDID' -skipPackagePluginValidation 2>&1 | grep -E 'error|Test Case|Executed|TEST (SUCCEEDED|FAILED)|xcodebuild: ' ; exit \${PIPESTATUS[0]}" || fail=1
# Watch slices: informational (Tier 2/3 targets; the plan treats them as unproven until W0).
phase watch bash -c "cd kmp-core && $G -Pk0.watch=true assembleRunCoreReleaseXCFramework" || true
echo "watch xcframework slices: $(ls "$XCF" 2>/dev/null | tr '\n' ' ')" >> "$LOGS/sizes.txt"
python3 ci_digest.py "$LOGS"
exit $fail
