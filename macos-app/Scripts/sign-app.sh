#!/usr/bin/env bash
# Ad-hoc-sign the built .app bundle with the entitlements needed for mic /
# system-audio capture. Run after every rebuild that touches the executable —
# changing the binary invalidates the signature, and TCC permission grants
# follow the code-signing hash.
#
# Usage:
#   ./Scripts/sign-app.sh                                 # signs .build/CallCapture.app
#   ./Scripts/sign-app.sh path/to/CallCapture.app         # signs an arbitrary bundle
#
# Notes:
# - The entitlements file lives at Scripts/entitlements.plist so it's
#   version-controlled and cannot disappear from the bundle output (an earlier
#   build shipped Contents/entitlements.plist as decoration; codesign was never
#   given --entitlements, so the signature carried only get-task-allow and the
#   IOProc silently received zero frames).
# - We use the ad-hoc identity (`--sign -`) plus `--options runtime` and
#   `--generate-entitlement-der` so the entitlements + Info.plist are properly
#   sealed. `--identifier com.callcapture.app` matches CFBundleIdentifier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="${1:-$APP_DIR/.build/CallCapture.app}"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle not found at $APP_BUNDLE" >&2
    echo "hint: run \`swift build\` first, then assemble the .app, then re-run this script." >&2
    exit 1
fi

# An entitlements.plist sitting inside the bundle as Contents/entitlements.plist
# would be treated by codesign as an unsigned subcomponent. Move it out so the
# sign succeeds.
if [[ -f "$APP_BUNDLE/Contents/entitlements.plist" ]]; then
    rm "$APP_BUNDLE/Contents/entitlements.plist"
fi

# Identity: ad-hoc by default; pass a Developer ID for distribution, e.g.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/sign-app.sh <app>
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# A secure (RFC 3161) timestamp requires a real signing identity; Apple's
# timestamp server rejects ad-hoc signatures. So only request --timestamp when
# signing with a real Developer ID. Ad-hoc keeps the (untrusted) local
# behaviour it had before. This keeps BOTH paths correct: ad-hoc signs locally,
# Developer ID gets the trusted timestamp notarization requires.
TIMESTAMP_FLAG=(--timestamp=none)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    TIMESTAMP_FLAG=(--timestamp)
fi

# Sign every nested Mach-O BEFORE the outer bundle. --deep is unreliable; iterate
# explicitly. Detect Mach-O by CONTENT, not extension: PyInstaller bundles
# extension-less binaries (e.g. Python.framework/Versions/3.11/Python) that a
# *.so/*.dylib filter misses — and the notary rejects any unsigned nested binary
# ("signature of the binary is invalid" / "does not include a secure timestamp").
WORKER_DIR="$APP_BUNDLE/Contents/Resources/worker"
if [[ -d "$WORKER_DIR" ]]; then
    echo "===> signing nested worker Mach-O"
    find "$WORKER_DIR" -type f -print0 \
        | while IFS= read -r -d '' f; do
            if file -b "$f" | grep -q "Mach-O"; then
                codesign --force --sign "$SIGN_IDENTITY" "${TIMESTAMP_FLAG[@]}" \
                    --options runtime "$f"
            fi
        done
fi

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.callcapture.app \
    --options runtime \
    "${TIMESTAMP_FLAG[@]}" \
    --generate-entitlement-der \
    "$APP_BUNDLE"

echo
echo "Signed $APP_BUNDLE"
codesign -dvvv --entitlements - "$APP_BUNDLE" 2>&1 \
    | grep -E 'Identifier|adhoc|Info.plist|Sealed|com.apple.security'
