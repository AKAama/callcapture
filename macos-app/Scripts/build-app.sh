#!/usr/bin/env bash
# Build the CallCapture executable, assemble a self-contained .app bundle
# (Swift binary + bundled PyInstaller worker), and ad-hoc-sign it with the
# entitlements needed for mic / system-audio capture.
#
# `swift build` only writes to .build/<config>/CallCapture and never touches a
# bundle, so running ONLY `swift build` after a source change is a trap: the
# change is in the SwiftPM binary, not in the running .app. This script always
# (re)assembles the bundle via assemble-app.sh — wiping and recreating
# .build/CallCapture.app from the fresh binary and the frozen worker — then
# signs it. Always invoke this script after a change to Swift sources that
# needs to land in the running app. The worker is built once with PyInstaller
# if it is not already present under python-worker/dist.
#
# Usage:
#   ./Scripts/build-app.sh                # debug build (default)
#   ./Scripts/build-app.sh release        # release build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-debug}"

cd "$APP_DIR"

echo "===> swift build ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release --product CallCapture
    SRC_BIN=".build/release/CallCapture"
else
    swift build --product CallCapture
    SRC_BIN=".build/arm64-apple-macosx/debug/CallCapture"
fi

WORKER_DIST="$APP_DIR/../python-worker/dist/call-capture-worker"
if [[ ! -x "$WORKER_DIST/call-capture-worker" ]]; then
    echo "===> building worker (PyInstaller)"
    ( cd "$APP_DIR/../python-worker" \
        && source .venv/bin/activate 2>/dev/null || true \
        && pyinstaller --clean --noconfirm packaging/call-capture-worker.spec )
fi

echo "===> assembling .app"
"$SCRIPT_DIR/assemble-app.sh" "$CONFIG" "$WORKER_DIST"

echo "===> signing (ad-hoc)"
"$SCRIPT_DIR/sign-app.sh" "$APP_DIR/.build/CallCapture.app"

echo
echo "Built and signed $APP_DIR/.build/CallCapture.app"
