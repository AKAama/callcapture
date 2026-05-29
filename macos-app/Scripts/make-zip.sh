#!/usr/bin/env bash
# Zip a CallCapture.app for distribution / a Homebrew cask.
# Usage: Scripts/make-zip.sh <app_path> <version> [out_zip]
set -euo pipefail

APP_PATH="${1:?usage: make-zip.sh <app_path> <version> [out_zip]}"
VERSION="${2:?version required, e.g. 0.2.0}"
OUT_ZIP="${3:-CallCapture-$VERSION.zip}"

[[ -d "$APP_PATH" ]] || { echo "error: app not found at $APP_PATH" >&2; exit 1; }

rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$OUT_ZIP"
echo "Created $OUT_ZIP"
