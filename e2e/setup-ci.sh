#!/usr/bin/env bash
# Prepares a GitHub Actions macOS runner for Buddy's e2e tests:
#  - a virtual audio device (BlackHole) as default input and output, so speech played
#    with `say` reaches Buddy's microphone;
#  - microphone and speech recognition permission for Buddy, so no dialogs appear;
#  - permission for the e2e tool (Probe) to click and type like a person.
# Only for throwaway CI machines: it edits the user's privacy database.
# Problems are reported as warnings; the e2e runs show what they lead to.
set -uo pipefail
APP="${1:-build/Buddy.app}"
warn() { echo "::warning::$1"; }

echo "== System"
sw_vers
csrutil status || true
system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type" || true

echo "== Virtual audio device"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
brew install --cask blackhole-2ch || warn "Could not install BlackHole"
brew install switchaudio-osx || warn "Could not install SwitchAudioSource"
sudo killall -9 coreaudiod || true
for _ in $(seq 1 30); do
  if SwitchAudioSource -a 2>/dev/null | grep -q "BlackHole 2ch"; then break; fi
  sleep 1
done
SwitchAudioSource -a || true
SwitchAudioSource -t input -s "BlackHole 2ch" || warn "Could not make BlackHole the default input"
SwitchAudioSource -t output -s "BlackHole 2ch" || warn "Could not make BlackHole the default output"
echo "Input: $(SwitchAudioSource -c -t input 2>/dev/null), output: $(SwitchAudioSource -c -t output 2>/dev/null)"

echo "== Swedish voices"
say -v '?' | grep -E 'sv[_-]SE' || warn "No Swedish voice installed"

echo "== Permissions for Buddy"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
REQUIREMENT=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
TMP=$(mktemp -d)
echo "$REQUIREMENT" | csreq -r- -b "$TMP/csreq.bin"
CSREQ=$(xxd -p "$TMP/csreq.bin" | tr -d '\n')
NOW=$(date +%s)
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
for SERVICE in kTCCServiceMicrophone kTCCServiceSpeechRecognition; do
  if sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ('$SERVICE', '$BUNDLE_ID', 0, 2, 3, 1, X'$CSREQ', 0, $NOW);"; then
    echo "Granted $SERVICE to $BUNDLE_ID"
  else
    warn "Could not grant $SERVICE (the audio e2e run will report it)"
  fi
done
sqlite3 "$DB" "SELECT service, client, auth_value FROM access WHERE client = '$BUNDLE_ID';" || true

echo "== Permission for the e2e tool that clicks and types like a person"
PROBE="$(cd "$(dirname "$0")/.." && pwd)/build/e2e-tools/Probe"
SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"
for SERVICE in kTCCServiceAccessibility kTCCServicePostEvent; do
  if sudo sqlite3 "$SYSTEM_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) VALUES ('$SERVICE', '$PROBE', 1, 2, 4, 1, NULL, 0, $NOW);"; then
    echo "Granted $SERVICE to $PROBE"
  else
    warn "Could not grant $SERVICE to the e2e tool (T29 reports what that leads to)"
  fi
done
sudo killall tccd 2>/dev/null || true
killall tccd 2>/dev/null || true
exit 0
