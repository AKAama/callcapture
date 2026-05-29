#!/usr/bin/env bash
# Notarize a CallCapture.app and emit a stapled, distributable zip.
# notarytool can't staple a zip, so: zip -> submit -> staple the .app -> re-zip.
# Uses an App Store Connect API key.
#
# Required env: AC_API_KEY_PATH, AC_API_KEY_ID, AC_API_ISSUER_ID
# Usage: Scripts/notarize.sh <app_path> <version> [out_zip]
set -euo pipefail

APP_PATH="${1:?usage: notarize.sh <app_path> <version> [out_zip]}"
VERSION="${2:?version required}"
OUT_ZIP="${3:-CallCapture-$VERSION.zip}"
: "${AC_API_KEY_PATH:?AC_API_KEY_PATH required}"
: "${AC_API_KEY_ID:?AC_API_KEY_ID required}"
: "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID required}"

[[ -d "$APP_PATH" ]] || { echo "error: app not found at $APP_PATH" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SUBMIT_ZIP="$TMP/submit.zip"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

echo "===> notarytool submit (waits for result)"
xcrun notarytool submit "$SUBMIT_ZIP" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait

echo "===> stapling the .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "===> re-zipping stapled app -> $OUT_ZIP"
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$OUT_ZIP"
echo "NOTARIZED + STAPLED: $OUT_ZIP"
