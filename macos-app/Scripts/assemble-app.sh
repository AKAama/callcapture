#!/usr/bin/env bash
# Assemble CallCapture.app from a built Swift binary and a PyInstaller worker.
# Signing is a SEPARATE step (sign-app.sh) so local ad-hoc and CI Developer ID
# share one assembly path.
#
# Usage:
#   Scripts/assemble-app.sh <swift_binary> <worker_dist_dir> [output_app]
#     swift_binary     executable produced by `swift build --show-bin-path`
#     worker_dist_dir  path to PyInstaller output (dir containing call-capture-worker)
#     output_app       defaults to .build/CallCapture.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="${1:?usage: assemble-app.sh <swift_binary> <worker_dist_dir> [output_app]}"
WORKER_DIST="${2:?usage: assemble-app.sh <swift_binary> <worker_dist_dir> [output_app]}"
APP_BUNDLE="${3:-$APP_DIR/.build/CallCapture.app}"

cd "$APP_DIR"

[[ -x "$SRC_BIN" ]] || { echo "error: Swift binary missing or not executable at $SRC_BIN (run swift build first)" >&2; exit 1; }
[[ -x "$WORKER_DIST/call-capture-worker" ]] || { echo "error: worker missing at $WORKER_DIST/call-capture-worker" >&2; exit 1; }

echo "===> creating bundle layout at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/worker"

echo "===> Info.plist"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "===> Swift binary"
cp "$SRC_BIN" "$APP_BUNDLE/Contents/MacOS/CallCapture"

echo "===> bundling worker"
cp -R "$WORKER_DIST/." "$APP_BUNDLE/Contents/Resources/worker/"

echo
echo "Assembled $APP_BUNDLE"
find "$APP_BUNDLE" -maxdepth 3 -type d
