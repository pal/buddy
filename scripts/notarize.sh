#!/usr/bin/env bash
# Notarizes Buddy.app with Apple and staples the ticket, so downloaded copies open
# without warnings. Credentials, one of:
#   App Store Connect API key: APPLE_API_KEY_P8 (contents of the .p8 file),
#                              APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#   Apple ID:                  APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password)
set -euo pipefail
APP="${1:-build/Buddy.app}"
WORK=$(mktemp -d)
if [ -n "${APPLE_API_KEY_P8:-}" ]; then
  printf '%s\n' "$APPLE_API_KEY_P8" > "$WORK/AuthKey.p8"
  AUTH=(--key "$WORK/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
elif [ -n "${APPLE_ID:-}" ]; then
  AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  echo "No notarization credentials set; skipping notarization."
  exit 0
fi
ditto -c -k --keepParent "$APP" "$WORK/Buddy.zip"
xcrun notarytool submit "$WORK/Buddy.zip" "${AUTH[@]}" --wait --timeout 30m --output-format json | tee "$WORK/result.json"
STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$WORK/result.json")
if [ "$STATUS" != "Accepted" ]; then
  ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$WORK/result.json")
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  echo "Notarization failed: $STATUS"
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
