#!/usr/bin/env bash
# Build the CallCapture executable, assemble a self-contained .app bundle
# (Swift binary + bundled legacy PyInstaller worker), and ad-hoc-sign it with
# the entitlements needed for process-audio capture.
#
# `swift build` only writes to .build/<config>/CallCapture and never touches a
# bundle, so running ONLY `swift build` after a source change is a trap: the
# change is in the SwiftPM binary, not in the running .app. This script always
# (re)assembles the bundle via assemble-app.sh — wiping and recreating
# .build/CallCapture.app from the fresh binary and the frozen worker — then
# signs it. Always invoke this script after a change to Swift sources that
# needs to land in the running app. The frozen worker is rebuilt with
# PyInstaller when it is missing, when FORCE_WORKER_REBUILD is set, or when any
# worker source is newer than the built binary. A clean clone therefore needs
# python-worker/.venv with the project's `packaging` extra installed; see the
# source-build instructions in README.md.
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
    BIN_DIR="$(swift build -c release --show-bin-path)"
else
    swift build --product CallCapture
    BIN_DIR="$(swift build --show-bin-path)"
fi
SRC_BIN="$BIN_DIR/CallCapture"
[[ -x "$SRC_BIN" ]] || {
    echo "error: SwiftPM did not produce an executable CallCapture product at $SRC_BIN" >&2
    exit 1
}

WORKER_SRC="$APP_DIR/../python-worker"
WORKER_DIST="$WORKER_SRC/dist/call-capture-worker"
WORKER_BIN="$WORKER_DIST/call-capture-worker"
WORKER_PYTHON="$WORKER_SRC/.venv/bin/python"

# Rebuild the frozen worker when it is missing, when forced, or when any worker
# source is newer than the frozen binary. The previous "build only if missing"
# guard silently shipped a stale worker whenever app/ changed after the first
# freeze: the cost-tracking feature merged AFTER the worker was frozen, so the
# bundled worker emitted no cost fields and the app stored NULL session costs.
worker_needs_build=0
if [[ ! -x "$WORKER_BIN" ]]; then
    worker_needs_build=1
elif [[ -n "${FORCE_WORKER_REBUILD:-}" ]]; then
    worker_needs_build=1
elif [[ -n "$(find "$WORKER_SRC/app" "$WORKER_SRC/packaging" "$WORKER_SRC/pyproject.toml" -newer "$WORKER_BIN" 2>/dev/null | head -1)" ]]; then
    echo "===> worker source newer than frozen binary — rebuilding"
    worker_needs_build=1
fi
if [[ "$worker_needs_build" == "1" ]]; then
    echo "===> building worker (PyInstaller)"
    [[ -x "$WORKER_PYTHON" ]] || {
        echo "error: Python worker virtual environment is missing at $WORKER_SRC/.venv" >&2
        echo "       Run: cd python-worker && python3.11 -m venv .venv" >&2
        echo "       Then: .venv/bin/python -m pip install -e '.[packaging]'" >&2
        exit 1
    }
    (
        cd "$WORKER_SRC"
        "$WORKER_PYTHON" -m PyInstaller --clean --noconfirm packaging/call-capture-worker.spec
    )
fi

echo "===> assembling .app"
"$SCRIPT_DIR/assemble-app.sh" "$SRC_BIN" "$WORKER_DIST"

echo "===> signing (ad-hoc)"
"$SCRIPT_DIR/sign-app.sh" "$APP_DIR/.build/CallCapture.app"

echo
echo "Built and signed $APP_DIR/.build/CallCapture.app"
