#!/bin/bash
# Dev launcher for CallCapture
# Builds, bundles, and launches with Python worker in dev mode

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$REPO_DIR/macos-app"
BUNDLE="$APP_DIR/.build/CallCapture.app"

echo "Building and signing app bundle..."
"$APP_DIR/Scripts/build-app.sh"

echo "Launching CallCapture (dev mode)..."
export CALLCAPTURE_DEV_MODE=1
export CALLCAPTURE_WORKER_DIR="$REPO_DIR/python-worker"

# Kill existing instances if running. Match both the bundled binary and a
# raw `swift build` / `swift run` debug binary so no orphan keeps a menu bar
# icon alive after relaunch.
pkill -9 -f "CallCapture.app/Contents/MacOS/CallCapture" 2>/dev/null || true
pkill -9 -f "\.build/debug/CallCapture" 2>/dev/null || true
pkill -9 -x "CallCapture" 2>/dev/null || true
sleep 0.5

open "$BUNDLE" --env CALLCAPTURE_DEV_MODE=1 --env CALLCAPTURE_WORKER_DIR="$REPO_DIR/python-worker"
echo "App launched. Check menu bar for waveform icon."
