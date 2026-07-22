#!/usr/bin/env bash
# Verify the bundle scripts use SwiftPM's active build directory rather than an
# architecture-specific output path. This only compiles the Swift product; it
# does not assemble, sign, launch, or replace an app bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-build}"

case "$MODE" in
    build|--syntax-only) ;;
    *)
        echo "usage: $0 [--syntax-only]" >&2
        exit 2
        ;;
esac

if grep -En '\.build/(arm64|x86_64)-apple-macosx/(debug|release)/CallCapture' \
    "$SCRIPT_DIR/build-app.sh" "$SCRIPT_DIR/assemble-app.sh"; then
    echo "error: bundle scripts must not hard-code an architecture-specific SwiftPM product path" >&2
    exit 1
fi

grep -F -- '--show-bin-path' "$SCRIPT_DIR/build-app.sh" >/dev/null || {
    echo "error: build-app.sh must resolve the SwiftPM build directory dynamically" >&2
    exit 1
}

if [[ "$MODE" == "--syntax-only" ]]; then
    echo "swift-binary-path-static-smoke-pass"
    exit 0
fi

cd "$APP_DIR"
swift build --product CallCapture >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
BIN_PATH="$BIN_DIR/CallCapture"
[[ -x "$BIN_PATH" ]] || {
    echo "error: SwiftPM did not produce an executable CallCapture product at $BIN_PATH" >&2
    exit 1
}

echo "swift-binary-path-smoke-pass: $BIN_PATH"
