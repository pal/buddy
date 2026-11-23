#!/usr/bin/env bash
# Checks the latest release the way an installed Buddy sees it: asks GitHub's API without
# credentials, downloads Buddy.zip from the address in the answer, and checks the app
# inside: the version in the tag, Buddy's bundle identifier, a valid signature from the
# expected Developer ID team, and Gatekeeper acceptance (notarized).
#
#   scripts/check-release.sh                      # the latest release as it is now
#   scripts/check-release.sh 0.1.4 Q4RJ7389LU     # wait until 0.1.4 is the latest; signed by that team
set -euo pipefail
FEED="https://api.github.com/repos/pal/buddy/releases/latest"
EXPECTED="${1:-}"
TEAM="${2:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=000
tag=""
remaining=""
for attempt in $(seq 1 12); do
  # No Authorization header: exactly what Buddy sends.
  status=$(curl -sS -o "$WORK/latest.json" -D "$WORK/headers" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H 'User-Agent: Buddy-updater' "$FEED" || echo 000)
  remaining=$(awk 'tolower($1) == "x-ratelimit-remaining:" { print $2 }' "$WORK/headers" 2>/dev/null | tr -d '\r')
  if [ "$status" = 200 ]; then
    tag=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$WORK/latest.json")
    if [ -z "$EXPECTED" ] || [ "$tag" = "v$EXPECTED" ]; then
      break
    fi
    echo "The latest release is $tag; waiting for v$EXPECTED (attempt $attempt)"
  elif [ "$status" = 404 ]; then
    echo "::error::GitHub answered 404 without credentials: the repository is private or has no release, so installed copies of Buddy cannot update."
    exit 1
  else
    echo "GitHub answered $status (requests left without credentials: ${remaining:-?}), attempt $attempt"
  fi
  sleep 10
done
if [ "$status" != 200 ]; then
  echo "::error::The release feed answered $status without credentials"
  cat "$WORK/latest.json" || true
  exit 1
fi
if [ -n "$EXPECTED" ] && [ "$tag" != "v$EXPECTED" ]; then
  echo "::error::The latest release is $tag, not v$EXPECTED"
  exit 1
fi

url=$(python3 - "$WORK/latest.json" <<'EOF'
import json, sys
release = json.load(open(sys.argv[1]))
print(next((a["browser_download_url"] for a in release.get("assets", []) if a["name"] == "Buddy.zip"), ""))
EOF
)
if [ -z "$url" ]; then
  echo "::error::Release $tag has no Buddy.zip"
  exit 1
fi
echo "Latest release: $tag, $url (API requests left without credentials: ${remaining:-?})"

curl -sSfL -o "$WORK/Buddy.zip" -H 'User-Agent: Buddy-updater' "$url"
ditto -x -k "$WORK/Buddy.zip" "$WORK/unpacked"
APP="$WORK/unpacked/Buddy.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ "v$version" != "$tag" ]; then
  echo "::error::Buddy.zip in $tag contains version $version"
  exit 1
fi
if [ "$identifier" != "io.github.pal.buddy" ]; then
  echo "::error::Buddy.zip in $tag contains $identifier"
  exit 1
fi
codesign --verify --deep --strict "$APP"
team=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -n "$TEAM" ] && [ "$team" != "$TEAM" ]; then
  echo "::error::Buddy.zip in $tag is signed by team $team, not $TEAM"
  exit 1
fi
spctl --assess --type execute -vv "$APP"
echo "OK: $tag downloads without credentials and contains Buddy $version ($identifier), signed by team $team and accepted by Gatekeeper."
