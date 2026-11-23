#!/usr/bin/env bash
# Checks the latest release the way installed copies of Buddy find it, without credentials:
#  1. GitHub's release page (what Buddy 0.1.4 and later use): /releases/latest must redirect to
#     the release's tag, and Buddy.zip must download from /releases/download/<tag>/Buddy.zip.
#  2. GitHub's API (what Buddy up to 0.1.3 uses): the same tag and the same Buddy.zip. The API
#     allows only 60 requests an hour per address without credentials, and CI machines share
#     addresses; when that limit is used up, the answer's contents are checked with the job's
#     token instead (the page check above has already shown that no login is needed).
# Then the app in Buddy.zip: the tag's version, Buddy's bundle identifier, a valid signature
# from the expected Developer ID team, and Gatekeeper acceptance (notarized).
#
#   scripts/check-release.sh                      # the latest release as it is now
#   scripts/check-release.sh 0.1.4 Q4RJ7389LU     # wait until 0.1.4 is the latest; signed by that team
set -euo pipefail
REPO="pal/buddy"
PAGE="https://github.com/$REPO/releases/latest"
API="https://api.github.com/repos/$REPO/releases/latest"
EXPECTED="${1:-}"
TEAM="${2:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AGENT="User-Agent: Buddy-updater"

# GitHub's release page can keep pointing at the previous release for several minutes after
# a new one is published, so a check for a new version waits up to 15 minutes.
if [ -n "$EXPECTED" ]; then attempts=90; else attempts=12; fi

# 1. The release page, without credentials.
tag=""
for attempt in $(seq 1 "$attempts"); do
  location=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -H "$AGENT" "$PAGE" || echo "000 ")
  status=${location%% *}
  url=${location#* }
  tag=$(printf '%s' "$url" | sed -n "s#^https://github.com/$REPO/releases/tag/\\(v[0-9.]*\\)\$#\\1#p")
  if [ "$status" = 302 ] && [ -n "$tag" ] && { [ -z "$EXPECTED" ] || [ "$tag" = "v$EXPECTED" ]; }; then
    break
  fi
  echo "The release page answered $status ${url:-without a redirect} (attempt $attempt)"
  tag=""
  sleep 10
done
if [ -z "$tag" ]; then
  echo "::error::$PAGE does not lead to a release${EXPECTED:+ v$EXPECTED} without credentials, so installed copies of Buddy cannot update."
  exit 1
fi
archive="https://github.com/$REPO/releases/download/$tag/Buddy.zip"
echo "Release page: $PAGE → $tag"

# 2. The API, as Buddy up to 0.1.3 asks it. It may also lag behind a new release for a while.
api_tag="-"
api_archive="-"
for attempt in $(seq 1 "$attempts"); do
  api_status=$(curl -sS -o "$WORK/latest.json" -D "$WORK/headers" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H "$AGENT" "$API" || echo 000)
  remaining=$(awk 'tolower($1) == "x-ratelimit-remaining:" { print $2 }' "$WORK/headers" 2>/dev/null | tr -d '\r')
  if [ "$api_status" = 404 ]; then
    echo "::error::The API answered 404 without credentials: the repository is private or has no release."
    exit 1
  fi
  if [ "$api_status" != 200 ] && [ "${remaining:-}" = 0 ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "The API's limit for requests without credentials is used up on this machine; checking its answer with the job's token."
    api_status=$(curl -sS -o "$WORK/latest.json" -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H 'Accept: application/vnd.github+json' -H "$AGENT" "$API" || echo 000)
  fi
  if [ "$api_status" = 200 ]; then
    read -r api_tag api_archive < <(python3 - "$WORK/latest.json" <<'EOF'
import json, sys
release = json.load(open(sys.argv[1]))
url = next((a["browser_download_url"] for a in release.get("assets", []) if a["name"] == "Buddy.zip"), "-")
print(release.get("tag_name", "-"), url)
EOF
)
    if [ "$api_tag" = "$tag" ] && [ "$api_archive" = "$archive" ]; then
      break
    fi
  fi
  echo "The API answered $api_status with $api_tag (attempt $attempt)"
  sleep 10
done
if [ "$api_status" != 200 ]; then
  echo "::error::The API answered $api_status (requests left without credentials: ${remaining:-?})"
  cat "$WORK/latest.json" || true
  exit 1
fi
if [ "$api_tag" != "$tag" ] || [ "$api_archive" != "$archive" ]; then
  echo "::error::The API says $api_tag with $api_archive; the release page says $tag with $archive"
  exit 1
fi
echo "API: $api_tag, $api_archive (requests left without credentials: ${remaining:-?})"

# The app in Buddy.zip, downloaded without credentials.
curl -sSfL -o "$WORK/Buddy.zip" -H "$AGENT" "$archive"
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
echo "OK: $tag is found through the release page and the API, downloads without credentials and contains Buddy $version ($identifier), signed by team $team and accepted by Gatekeeper."
