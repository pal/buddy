#!/usr/bin/env bash
# Checks that Buddy.app is ready to hand out: universal binary, valid signature,
# required Info.plist keys, and whether Gatekeeper lets a downloaded copy open.
# With REQUIRE_NOTARIZED=1 a Gatekeeper rejection fails the check; otherwise it is a warning.
set -uo pipefail
APP="${1:-build/Buddy.app}"
failed=0
report=()
pass() { report+=("| ✅ | $1 |"); echo "PASS  $1"; }
fail() { report+=("| ❌ | $1 |"); echo "FAIL  $1"; failed=1; }
warn() { report+=("| ⚠️ | $1 |"); echo "WARN  $1"; }

archs=$(lipo -archs "$APP/Contents/MacOS/Buddy" 2>/dev/null || true)
if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then pass "Universal binary ($archs)"; else fail "Universal binary ($archs)"; fi

if codesign --verify --deep --strict "$APP" 2>/dev/null; then pass "Code signature is valid"; else fail "Code signature is invalid"; fi
authority=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
pass "Signed by: ${authority:-ad hoc (no certificate)}"

for key in CFBundleIdentifier LSUIElement NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription CFBundleIconFile; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1; then pass "Info.plist has $key"; else fail "Info.plist lacks $key"; fi
done
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && pass "App icon" || fail "App icon missing"

# Gatekeeper, as for a copy downloaded with a browser.
TMP=$(mktemp -d)
ditto "$APP" "$TMP/Buddy.app"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$TMP/Buddy.app"
if spctl --assess --type execute -vv "$TMP/Buddy.app" > "$TMP/spctl.txt" 2>&1; then
  pass "Gatekeeper opens a downloaded copy: $(tr '\n' ' ' < "$TMP/spctl.txt")"
else
  message="Gatekeeper blocks a downloaded copy: $(tr '\n' ' ' < "$TMP/spctl.txt")"
  if [ "${REQUIRE_NOTARIZED:-0}" = "1" ]; then fail "$message"; else warn "$message – sign with a Developer ID and notarize (see README)"; fi
fi
if xcrun stapler validate "$APP" >/dev/null 2>&1; then pass "Notarization ticket is stapled"; else warn "No notarization ticket stapled"; fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## Distribution"; echo; echo "| | Check |"; echo "|---|---|"; printf '%s\n' "${report[@]}"; echo; } >> "$GITHUB_STEP_SUMMARY"
fi
exit $failed
