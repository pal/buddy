#!/usr/bin/env bash
# CI: imports a Developer ID Application certificate into a temporary keychain.
# Needs MACOS_CERTIFICATE_P12 (base64 of the .p12) and MACOS_CERTIFICATE_PASSWORD.
set -euo pipefail
KEYCHAIN="${RUNNER_TEMP:-/tmp}/buddy-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
CERT="${RUNNER_TEMP:-/tmp}/buddy-certificate.p12"
echo "$MACOS_CERTIFICATE_P12" | base64 --decode > "$CERT"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$CERT"
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
  echo "No 'Developer ID Application' identity in the certificate"
  security find-identity -v -p codesigning "$KEYCHAIN"
  exit 1
fi
echo "Signing identity: $IDENTITY"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
fi
