# Signed, Self-Contained `.app` Releases — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a notarized, self-contained `CallCapture.app` (Python worker bundled) as a DMG attached to every GitHub Release.

**Architecture:** PyInstaller packages the Python worker into a standalone `call-capture-worker` binary placed in `CallCapture.app/Contents/Resources/worker/` (the bridge already resolves this path). A bundle-assembly script builds the `.app`; a signing script signs inner→out with Developer ID + hardened runtime; CI builds → signs → makes a DMG → notarizes → staples → uploads to the release. Local Whisper (`pywhispercpp`) is excluded for v1; packaged builds use remote engines + analysis.

**Tech Stack:** PyInstaller, Swift/SwiftPM, `codesign`, `notarytool`, `hdiutil`, GitHub Actions (`macos-15`).

**Spec:** `docs/superpowers/specs/2026-05-29-signed-app-releases-design.md`

---

## File Structure

**Create:**
- `python-worker/packaging/worker_entry.py` — PyInstaller entry (calls `app.cli.main`)
- `python-worker/packaging/call-capture-worker.spec` — PyInstaller build spec
- `python-worker/packaging/smoke_test.sh` — verifies the built binary's CLI contract
- `macos-app/Scripts/assemble-app.sh` — assemble `.app` (Swift bin + bundled worker)
- `macos-app/Scripts/make-dmg.sh` — package `.app` into a DMG
- `macos-app/Scripts/notarize.sh` — notarize + staple a DMG
- `macos-app/Tests/CallCaptureTests/WorkerSearchPathTests.swift` — bridge search-path test
- `.github/workflows/release.yml` — release pipeline
- `docs/RELEASING.md` — how to cut a release + required secrets

**Modify:**
- `python-worker/pyproject.toml` — add `packaging` extra (`pyinstaller`)
- `macos-app/Scripts/sign-app.sh` — accept a signing identity (Developer ID) + sign inner→out
- `macos-app/Scripts/entitlements.plist` — add `disable-library-validation`
- `macos-app/Scripts/build-app.sh` — call `assemble-app.sh`
- `README.md` — note packaged app = remote engines; link Releases

**Bridge note (no change needed):** `PythonBridge.searchPaths()` already returns
`"<Resources>/worker/call-capture-worker"`. The PyInstaller output MUST be named
`call-capture-worker` to match. Task 6 adds a regression test for this contract.

---

# PHASE 1 — Self-contained app (no Apple credentials required)

**Phase exit criteria:** an ad-hoc-signed `CallCapture.app` built locally
transcribes a sample via a **remote** engine with no `python-worker/` source
present and no dev `python3` on PATH.

---

## Task 1: PyInstaller packaging dependency

**Files:**
- Modify: `python-worker/pyproject.toml`

- [ ] **Step 1: Add a `packaging` optional-dependency group**

In `python-worker/pyproject.toml`, under `[project.optional-dependencies]` (which already has `dev`), add:

```toml
packaging = [
    "pyinstaller>=6.6",
]
```

- [ ] **Step 2: Install it**

Run:
```bash
cd python-worker && source .venv/bin/activate && pip install -e ".[dev,packaging]"
```
Expected: PyInstaller installs without error; `pyinstaller --version` prints `6.x`.

- [ ] **Step 3: Commit**

```bash
git add python-worker/pyproject.toml
git commit -m "build(worker): add pyinstaller packaging extra"
```

---

## Task 2: PyInstaller entry point and spec

**Files:**
- Create: `python-worker/packaging/worker_entry.py`
- Create: `python-worker/packaging/call-capture-worker.spec`

- [ ] **Step 1: Write the entry point**

Create `python-worker/packaging/worker_entry.py`:

```python
"""PyInstaller entry point for the packaged worker.

Delegates to the existing Click CLI so the frozen binary exposes the same
commands (`transcribe`, `postprocess`, `export`, `prepare_emotion`) and the
same stdin/stdout JSON contract as `python -m app.cli`.
"""
from app.cli import main

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the PyInstaller spec**

Create `python-worker/packaging/call-capture-worker.spec`:

```python
# -*- mode: python ; coding: utf-8 -*-
# Build:  cd python-worker && pyinstaller packaging/call-capture-worker.spec
# Output: dist/call-capture-worker/call-capture-worker
#
# The binary name MUST stay "call-capture-worker" — PythonBridge.searchPaths()
# looks for Contents/Resources/worker/call-capture-worker.
from PyInstaller.utils.hooks import copy_metadata

# Lazy imports PyInstaller cannot detect by static analysis. openai, httpx and
# anthropic are imported inside functions; audonnx/onnxruntime are imported only
# when the emotion model runs. pywhispercpp is intentionally EXCLUDED (v1 ships
# remote engines only; local Whisper degrades to a stub).
hiddenimports = [
    "openai",
    "httpx",
    "anthropic",
    "onnxruntime",
    "audonnx",
    "audeer",
    "audiofile",
    "numpy",
]

# Packages that read their version via importlib.metadata at runtime.
datas = copy_metadata("openai") + copy_metadata("pydantic")

a = Analysis(
    ["worker_entry.py"],
    pathex=[".."],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=["pywhispercpp"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="call-capture-worker",
    debug=False,
    strip=False,
    upx=False,
    console=True,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="call-capture-worker",
)
```

- [ ] **Step 3: Build the binary**

Run:
```bash
cd python-worker && source .venv/bin/activate
pyinstaller --clean --noconfirm packaging/call-capture-worker.spec
```
Expected: build succeeds; `dist/call-capture-worker/call-capture-worker` exists and is executable.

- [ ] **Step 4: Commit**

```bash
git add python-worker/packaging/worker_entry.py python-worker/packaging/call-capture-worker.spec
git commit -m "build(worker): pyinstaller spec for standalone call-capture-worker"
```

---

## Task 3: Worker binary smoke test

**Files:**
- Create: `python-worker/packaging/smoke_test.sh`

- [ ] **Step 1: Write the smoke test**

Create `python-worker/packaging/smoke_test.sh`:

```bash
#!/usr/bin/env bash
# Verify the frozen worker honors the CLI contract: --version works, and a
# ping on stdin returns without crashing. Run after a PyInstaller build.
#
# Usage: packaging/smoke_test.sh [path-to-binary]
set -euo pipefail

BIN="${1:-dist/call-capture-worker/call-capture-worker}"

if [[ ! -x "$BIN" ]]; then
    echo "error: worker binary not found/executable at $BIN" >&2
    exit 1
fi

echo "===> --version"
"$BIN" --version

echo "===> ping (transcribe with a ping payload)"
echo '{"ping": true}' | "$BIN" transcribe

echo "===> invalid JSON returns a structured error (non-crash)"
# An empty/garbage request must produce a JobResult error on stdout, not a crash.
set +e
echo 'not-json' | "$BIN" transcribe
rc=$?
set -e
# Click's standalone_mode is disabled; a parse failure exits non-zero with a
# JSON error line already printed. Accept any clean (non-signal) exit.
if [[ $rc -ge 128 ]]; then
    echo "error: worker crashed (signal) on bad input (rc=$rc)" >&2
    exit 1
fi

echo "SMOKE OK"
```

- [ ] **Step 2: Make it executable and run it**

Run:
```bash
cd python-worker && chmod +x packaging/smoke_test.sh
./packaging/smoke_test.sh
```
Expected: prints the version, handles the ping, survives bad input, ends with `SMOKE OK`. If a `ModuleNotFoundError` appears, add the missing module to `hiddenimports` in the spec, rebuild (Task 2 Step 3), and re-run.

- [ ] **Step 3: Commit**

```bash
git add python-worker/packaging/smoke_test.sh
git commit -m "test(worker): smoke test for the frozen worker CLI contract"
```

---

## Task 4: Bundle assembly script

**Files:**
- Create: `macos-app/Scripts/assemble-app.sh`

- [ ] **Step 1: Write the assembly script**

Create `macos-app/Scripts/assemble-app.sh`:

```bash
#!/usr/bin/env bash
# Assemble CallCapture.app from a built Swift binary and a PyInstaller worker.
# Signing is a SEPARATE step (sign-app.sh) so local ad-hoc and CI Developer ID
# share one assembly path.
#
# Usage:
#   Scripts/assemble-app.sh <config> <worker_dist_dir> [output_app]
#     config           debug | release
#     worker_dist_dir  path to PyInstaller output (dir containing call-capture-worker)
#     output_app       defaults to .build/CallCapture.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${1:-release}"
WORKER_DIST="${2:?usage: assemble-app.sh <config> <worker_dist_dir> [output_app]}"
APP_BUNDLE="${3:-$APP_DIR/.build/CallCapture.app}"

cd "$APP_DIR"

if [[ "$CONFIG" == "release" ]]; then
    SRC_BIN=".build/release/CallCapture"
else
    SRC_BIN=".build/arm64-apple-macosx/debug/CallCapture"
fi
[[ -f "$SRC_BIN" ]] || { echo "error: Swift binary missing at $SRC_BIN (run swift build first)" >&2; exit 1; }
[[ -x "$WORKER_DIST/call-capture-worker" ]] || { echo "error: worker missing at $WORKER_DIST/call-capture-worker" >&2; exit 1; }

echo "===> creating bundle layout at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/worker"

echo "===> Info.plist"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    cp "$APP_DIR/.build/CallCapture.app.template/Contents/Info.plist" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
    { echo "error: no Info.plist source found (expected Scripts/Info.plist)" >&2; exit 1; }

echo "===> Swift binary"
cp "$SRC_BIN" "$APP_BUNDLE/Contents/MacOS/CallCapture"

echo "===> bundling worker"
cp -R "$WORKER_DIST/." "$APP_BUNDLE/Contents/Resources/worker/"

echo
echo "Assembled $APP_BUNDLE"
find "$APP_BUNDLE" -maxdepth 3 -type d
```

- [ ] **Step 2: Provide the Info.plist source**

The existing tracked `CallCapture.app/Contents/Info.plist` is the source of truth. Copy it next to the scripts so assembly never depends on a prebuilt bundle:

Run:
```bash
cd macos-app && cp ../CallCapture.app/Contents/Info.plist Scripts/Info.plist
```
Expected: `Scripts/Info.plist` exists. (If the repo-root `CallCapture.app` is absent in a clean checkout, the engineer copies from any prior bundle; the file is now version-controlled here.)

- [ ] **Step 3: Make executable**

Run: `chmod +x macos-app/Scripts/assemble-app.sh`

- [ ] **Step 4: End-to-end assemble (release) and verify layout**

Run:
```bash
cd macos-app && swift build -c release --product CallCapture
./Scripts/assemble-app.sh release ../python-worker/dist/call-capture-worker
test -x .build/CallCapture.app/Contents/Resources/worker/call-capture-worker && echo "WORKER PRESENT"
test -f .build/CallCapture.app/Contents/MacOS/CallCapture && echo "BINARY PRESENT"
```
Expected: prints `WORKER PRESENT` and `BINARY PRESENT`.

- [ ] **Step 5: Commit**

```bash
git add macos-app/Scripts/assemble-app.sh macos-app/Scripts/Info.plist
git commit -m "build(app): assemble-app.sh bundles Swift binary + PyInstaller worker"
```

---

## Task 5: Wire build-app.sh to the new assembly

**Files:**
- Modify: `macos-app/Scripts/build-app.sh`

- [ ] **Step 1: Replace the manual bundle-refresh with assemble + sign**

In `macos-app/Scripts/build-app.sh`, replace the block from `APP_BUNDLE=".build/CallCapture.app"` through the `cp "$SRC_BIN" "$DEST_BIN"` line with a call that builds the worker (if a venv is present) and assembles. Specifically, after the `swift build` block, replace the bundle-refresh + sign section with:

```bash
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
```

- [ ] **Step 2: Run it**

Run: `cd macos-app && ./Scripts/build-app.sh release`
Expected: builds worker (or reuses dist), assembles `.app`, ad-hoc signs; ends with "Built and signed".

- [ ] **Step 3: Verify the packaged app runs the bundled worker (the key Phase-1 proof)**

Run (forces non-dev mode by hiding the source tree and any venv python):
```bash
APP=macos-app/.build/CallCapture.app/Contents/Resources/worker/call-capture-worker
"$APP" --version
echo "BUNDLED WORKER RUNS STANDALONE"
```
Expected: version prints with no `python-worker/` source and no venv activated — proving the binary is self-contained.

- [ ] **Step 4: Commit**

```bash
git add macos-app/Scripts/build-app.sh
git commit -m "build(app): build-app.sh builds worker and assembles self-contained bundle"
```

---

## Task 6: Bridge search-path regression test

**Files:**
- Create: `macos-app/Tests/CallCaptureTests/WorkerSearchPathTests.swift`

- [ ] **Step 1: Write the failing test**

Create `macos-app/Tests/CallCaptureTests/WorkerSearchPathTests.swift`:

```swift
import XCTest
@testable import CallCapture

@available(macOS 14.2, *)
final class WorkerSearchPathTests: XCTestCase {
    func testSearchPathsIncludeBundledWorkerName() {
        let paths = PythonBridge.searchPaths()
        // The PyInstaller output is named "call-capture-worker"; the bundle
        // path must reference exactly that name or the packaged app can't
        // find its worker.
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("/worker/call-capture-worker") },
            "expected a Resources/worker/call-capture-worker path, got \(paths)"
        )
    }

    func testSearchPathsIncludeResourcesLocation() {
        let paths = PythonBridge.searchPaths()
        XCTAssertTrue(
            paths.contains { $0.contains("/worker/call-capture-worker") },
            "search paths should target the bundled worker location"
        )
    }
}
```

- [ ] **Step 2: Run it to verify it passes (the production code already matches)**

Run: `cd macos-app && swift test --filter WorkerSearchPathTests`
Expected: PASS. (`searchPaths()` already returns `call-capture-worker`. If it FAILS because the name differs, fix `PythonBridge.searchPaths()` to use `call-capture-worker`, then re-run.)

- [ ] **Step 3: Commit**

```bash
git add macos-app/Tests/CallCaptureTests/WorkerSearchPathTests.swift
git commit -m "test(app): lock the bundled worker binary name contract"
```

---

# PHASE 2 — Notarized release pipeline

**Phase exit criteria:** a tagged release yields a notarized, stapled DMG
attached to the release that opens via double-click on a clean Mac
(`spctl -a -vvv -t install` reports "accepted, source=Notarized Developer ID").

---

## Task 7: Hardened-runtime entitlements

**Files:**
- Modify: `macos-app/Scripts/entitlements.plist`

- [ ] **Step 1: Add the library-validation exception**

Replace `macos-app/Scripts/entitlements.plist` contents with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <!-- The bundled PyInstaller worker loads Python C-extension dylibs that are
         not signed by our Team ID; under hardened runtime this is required. -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Verify the bundle still signs + runs ad-hoc with the new entitlements**

Run:
```bash
cd macos-app && ./Scripts/sign-app.sh .build/CallCapture.app
codesign -d --entitlements - .build/CallCapture.app 2>&1 | grep -i library-validation && echo "ENTITLEMENT PRESENT"
```
Expected: prints the entitlement and `ENTITLEMENT PRESENT`.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Scripts/entitlements.plist
git commit -m "build(app): allow library validation bypass for bundled python worker"
```

---

## Task 8: Developer ID signing (inner→out)

**Files:**
- Modify: `macos-app/Scripts/sign-app.sh`

- [ ] **Step 1: Generalize signing to accept an identity and sign nested code first**

Replace the `codesign ... --sign -` block in `macos-app/Scripts/sign-app.sh` with identity-aware, inner→out signing. Insert before the existing single `codesign` call:

```bash
# Identity: ad-hoc by default; pass a Developer ID for distribution, e.g.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" Scripts/sign-app.sh <app>
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Sign every nested Mach-O (the worker binary + its bundled .so/.dylib) BEFORE
# the outer bundle. --deep is unreliable; iterate explicitly.
WORKER_DIR="$APP_BUNDLE/Contents/Resources/worker"
if [[ -d "$WORKER_DIR" ]]; then
    echo "===> signing nested worker Mach-O"
    # .so / .dylib first
    find "$WORKER_DIR" \( -name "*.so" -o -name "*.dylib" \) -print0 \
        | while IFS= read -r -d '' lib; do
            codesign --force --sign "$SIGN_IDENTITY" --timestamp \
                --options runtime "$lib"
        done
    # then the worker executable itself
    codesign --force --sign "$SIGN_IDENTITY" --timestamp \
        --options runtime "$WORKER_DIR/call-capture-worker"
fi
```

Then change the existing final `codesign` call to use `"$SIGN_IDENTITY"` instead of the literal `-`, and add `--timestamp`:

```bash
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.callcapture.app \
    --options runtime \
    --timestamp \
    --generate-entitlement-der \
    "$APP_BUNDLE"
```

(`--timestamp` is required for notarization; it is harmless for ad-hoc local builds, which simply skip the secure timestamp.)

- [ ] **Step 2: Verify ad-hoc path still works (default identity)**

Run:
```bash
cd macos-app && ./Scripts/sign-app.sh .build/CallCapture.app
codesign --verify --deep --strict --verbose=2 .build/CallCapture.app && echo "VERIFY OK"
```
Expected: `VERIFY OK` (ad-hoc identity, nested worker signed).

- [ ] **Step 3: Commit**

```bash
git add macos-app/Scripts/sign-app.sh
git commit -m "build(app): sign nested worker Mach-O inner->out, support Developer ID identity"
```

---

## Task 9: DMG packaging

**Files:**
- Create: `macos-app/Scripts/make-dmg.sh`

- [ ] **Step 1: Write the DMG script**

Create `macos-app/Scripts/make-dmg.sh`:

```bash
#!/usr/bin/env bash
# Package a signed CallCapture.app into a drag-to-Applications DMG.
#
# Usage: Scripts/make-dmg.sh <app_path> <version> [out_dmg]
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <app_path> <version> [out_dmg]}"
VERSION="${2:?version required, e.g. 0.2.0}"
OUT_DMG="${3:-CallCapture-$VERSION.dmg}"

[[ -d "$APP_PATH" ]] || { echo "error: app not found at $APP_PATH" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/CallCapture.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUT_DMG"
hdiutil create \
    -volname "CallCapture $VERSION" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$OUT_DMG"

echo "Created $OUT_DMG"
```

- [ ] **Step 2: Make executable and build a DMG from the local ad-hoc app**

Run:
```bash
cd macos-app && chmod +x Scripts/make-dmg.sh
./Scripts/make-dmg.sh .build/CallCapture.app 0.0.0-local /tmp/CallCapture-local.dmg
test -f /tmp/CallCapture-local.dmg && echo "DMG CREATED"
```
Expected: `DMG CREATED`.

- [ ] **Step 3: Commit**

```bash
git add macos-app/Scripts/make-dmg.sh
git commit -m "build(app): make-dmg.sh packages the app into a drag-install DMG"
```

---

## Task 10: Notarization script

**Files:**
- Create: `macos-app/Scripts/notarize.sh`

- [ ] **Step 1: Write the notarize script**

Create `macos-app/Scripts/notarize.sh`:

```bash
#!/usr/bin/env bash
# Submit a DMG to Apple notarization and staple the ticket.
# Uses an App Store Connect API key (no app-specific password).
#
# Required env:
#   AC_API_KEY_PATH   path to the .p8 key file
#   AC_API_KEY_ID     App Store Connect key id
#   AC_API_ISSUER_ID  App Store Connect issuer id
#
# Usage: Scripts/notarize.sh <dmg_path>
set -euo pipefail

DMG="${1:?usage: notarize.sh <dmg_path>}"
: "${AC_API_KEY_PATH:?AC_API_KEY_PATH required}"
: "${AC_API_KEY_ID:?AC_API_KEY_ID required}"
: "${AC_API_ISSUER_ID:?AC_API_ISSUER_ID required}"

echo "===> submitting $DMG to notarytool (waits for result)"
xcrun notarytool submit "$DMG" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait

echo "===> stapling"
xcrun stapler staple "$DMG"

echo "===> verifying"
xcrun stapler validate "$DMG"
echo "NOTARIZED + STAPLED"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x macos-app/Scripts/notarize.sh`
(No local verification — requires Apple credentials. Verified in CI / by the maintainer.)

- [ ] **Step 3: Commit**

```bash
git add macos-app/Scripts/notarize.sh
git commit -m "build(app): notarize.sh submits + staples a DMG via notarytool"
```

---

## Task 11: Release CI workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      version:
        description: "Version for a manual dry-run (no upload)"
        required: false
        default: "0.0.0-dryrun"

permissions:
  contents: write

jobs:
  build-dmg:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Resolve version
        id: ver
        run: |
          if [ "${{ github.event_name }}" = "release" ]; then
            echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
          else
            echo "version=${{ github.event.inputs.version }}" >> "$GITHUB_OUTPUT"
          fi

      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Build worker (PyInstaller)
        working-directory: python-worker
        run: |
          python -m pip install --upgrade pip
          pip install -e ".[packaging]"
          pip install pydantic click numpy openai anthropic httpx onnxruntime audonnx audeer audiofile
          pyinstaller --clean --noconfirm packaging/call-capture-worker.spec
          chmod +x packaging/smoke_test.sh
          ./packaging/smoke_test.sh

      - name: Build Swift (release)
        working-directory: macos-app
        run: |
          sudo xcode-select -s /Applications/Xcode_16.app || true
          swift build -c release --product CallCapture

      - name: Assemble .app
        working-directory: macos-app
        run: ./Scripts/assemble-app.sh release ../python-worker/dist/call-capture-worker

      - name: Check for signing secrets
        id: secrets
        run: |
          if [ -n "${{ secrets.MACOS_CERT_P12_BASE64 }}" ]; then
            echo "signing=true" >> "$GITHUB_OUTPUT"
          else
            echo "signing=false" >> "$GITHUB_OUTPUT"
            echo "::warning::Signing secrets absent — producing an UNSIGNED DMG (not notarized)."
          fi

      - name: Import Developer ID certificate
        if: steps.secrets.outputs.signing == 'true'
        env:
          CERT_B64: ${{ secrets.MACOS_CERT_P12_BASE64 }}
          CERT_PWD: ${{ secrets.MACOS_CERT_PASSWORD }}
        run: |
          KEYCHAIN="$RUNNER_TEMP/build.keychain"
          KP="$(uuidgen)"
          security create-keychain -p "$KP" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$KP" "$KEYCHAIN"
          echo "$CERT_B64" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$CERT_PWD" \
            -T /usr/bin/codesign
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KP" "$KEYCHAIN"
          echo "KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"

      - name: Sign (Developer ID)
        if: steps.secrets.outputs.signing == 'true'
        working-directory: macos-app
        env:
          SIGN_IDENTITY: ${{ secrets.MACOS_SIGN_IDENTITY }}
        run: ./Scripts/sign-app.sh .build/CallCapture.app

      - name: Sign (ad-hoc fallback)
        if: steps.secrets.outputs.signing == 'false'
        working-directory: macos-app
        run: ./Scripts/sign-app.sh .build/CallCapture.app

      - name: Make DMG
        working-directory: macos-app
        run: ./Scripts/make-dmg.sh .build/CallCapture.app "${{ steps.ver.outputs.version }}" "CallCapture-${{ steps.ver.outputs.version }}.dmg"

      - name: Notarize + staple
        if: steps.secrets.outputs.signing == 'true'
        working-directory: macos-app
        env:
          AC_API_KEY_ID: ${{ secrets.AC_API_KEY_ID }}
          AC_API_ISSUER_ID: ${{ secrets.AC_API_ISSUER_ID }}
        run: |
          echo "${{ secrets.AC_API_KEY_BASE64 }}" | base64 --decode > "$RUNNER_TEMP/ac_key.p8"
          AC_API_KEY_PATH="$RUNNER_TEMP/ac_key.p8" \
            ./Scripts/notarize.sh "CallCapture-${{ steps.ver.outputs.version }}.dmg"

      - name: Upload DMG to release
        if: github.event_name == 'release'
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release upload "${{ github.ref_name }}" "macos-app/CallCapture-${{ steps.ver.outputs.version }}.dmg" --clobber

      - name: Upload DMG as workflow artifact (dry-run)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/upload-artifact@v4
        with:
          name: CallCapture-dmg
          path: macos-app/CallCapture-*.dmg

      - name: Cleanup keychain
        if: always() && steps.secrets.outputs.signing == 'true'
        run: security delete-keychain "$KEYCHAIN" || true
```

- [ ] **Step 2: Validate workflow syntax**

Run: `gh workflow view "Release" 2>/dev/null || python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "YAML OK"`
Expected: `YAML OK` (the workflow may not be registered until pushed; the YAML parse is the gate here).

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/release.yml
git commit -m "ci: release workflow builds, signs, notarizes, and uploads a DMG"
git push origin main
```

- [ ] **Step 4: Dry-run the unsigned path**

Run: `gh workflow run Release -f version=0.0.0-dryrun`
Then watch: `gh run watch "$(gh run list --workflow=Release --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status`
Expected: green; a `CallCapture-dmg` artifact is produced (unsigned, since secrets may be absent). If red, read `--log-failed`, fix, repush, re-run.

---

## Task 12: Release docs + README

**Files:**
- Create: `docs/RELEASING.md`
- Modify: `README.md`

- [ ] **Step 1: Write the releasing guide**

Create `docs/RELEASING.md`:

```markdown
# Releasing

Releases are built and notarized by `.github/workflows/release.yml` when a
GitHub Release is **published**. The workflow builds the self-contained
`CallCapture.app`, signs it with Developer ID, notarizes a DMG, and uploads the
DMG to the release.

## One-time setup (maintainer)

1. **Developer ID Application certificate** — in the Apple Developer portal,
   create a "Developer ID Application" certificate, then export it from Keychain
   Access as a `.p12` (set an export password).
2. **App Store Connect API key** — App Store Connect → Users and Access → Keys →
   generate a key with the "Developer" role. Download the `.p8` and note the
   Key ID and Issuer ID.
3. **Add repository secrets** (Settings → Secrets and variables → Actions):
   - `MACOS_CERT_P12_BASE64` — `base64 -i cert.p12 | pbcopy`
   - `MACOS_CERT_PASSWORD` — the `.p12` export password
   - `MACOS_SIGN_IDENTITY` — e.g. `Developer ID Application: Your Name (R72GTBB9MG)`
   - `AC_API_KEY_BASE64` — `base64 -i AuthKey_XXXX.p8 | pbcopy`
   - `AC_API_KEY_ID`
   - `AC_API_ISSUER_ID`
   - `APPLE_TEAM_ID` — e.g. `R72GTBB9MG`

## Cutting a release

```bash
# 1. Tag and create the GitHub release
gh release create v0.2.0 --title "v0.2.0" --notes "..."
# 2. The Release workflow runs automatically and attaches CallCapture-0.2.0.dmg
```

## Dry-run without publishing

```bash
gh workflow run Release -f version=0.0.0-dryrun
# Downloads as a workflow artifact; unsigned if secrets are absent.
```

## Verifying a signed build

```bash
spctl -a -vvv -t install CallCapture.app    # -> accepted, source=Notarized Developer ID
xcrun stapler validate CallCapture-0.2.0.dmg
```
```

- [ ] **Step 2: Note packaged-app limitations in README**

In `README.md`, under the "Requirements" or "Quick start" area, add:

```markdown
### Download

Grab the latest signed DMG from [Releases](https://github.com/bodharma/callcapture/releases),
open it, and drag CallCapture to Applications.

> The packaged app uses **cloud transcription** (AssemblyAI / Deepgram) plus full
> on-device analysis (diarization, sentiment, emotion, insights). **On-device
> Whisper** transcription is available in source builds only for now — see
> [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
```

- [ ] **Step 3: Commit and push**

```bash
git add docs/RELEASING.md README.md
git commit -m "docs: releasing guide and packaged-app notes"
git push origin main
```

---

## Self-Review (completed)

- **Spec coverage:** worker packaging (T1–T3), bridge contract (T6), bundle
  assembly (T4–T5), entitlements (T7), inner→out Developer ID signing (T8), DMG
  (T9), notarization (T10), secret-gated release CI (T11), secrets docs +
  README (T12). All §4–§7 spec items mapped.
- **Placeholders:** none — every script and workflow is complete.
- **Name consistency:** the worker binary is `call-capture-worker` everywhere
  (spec/`searchPaths()`/spec file/assembly/signing), matching the existing
  `PythonBridge.searchPaths()` contract locked by T6.
- **Phasing:** Phase 1 (T1–T6) yields a working self-contained app with no Apple
  credentials; Phase 2 (T7–T12) adds notarized DMG releases.

## Notes for the implementer

- If the T3 smoke test surfaces a `ModuleNotFoundError`, add the module to
  `hiddenimports` in `call-capture-worker.spec` and rebuild — this is expected
  iteration for PyInstaller, not a failure.
- The repo-root `CallCapture.app` is a leftover dev bundle; `Scripts/Info.plist`
  (added in T4) becomes the version-controlled Info.plist source so assembly no
  longer depends on it.
- Notarization steps (T10/T11 notarize) can only be fully verified once the
  maintainer adds the Apple secrets; until then CI produces an unsigned DMG via
  the secret gate.
```

---

# REVISION 2026-05-29: DMG → Homebrew cask + notarized zip

Distribution pivoted from DMG to a **Homebrew cask in an own tap** with a
**notarized zip** artifact (see the updated spec for rationale). Tasks 1–8 stand.
**Tasks 9–12 above are SUPERSEDED** by the following. Full script/workflow text
is carried in the implementer dispatches; summarized here for the record:

- **Task 9′ — `Scripts/make-zip.sh`** (replaces make-dmg): `ditto -c -k --keepParent CallCapture.app CallCapture-<ver>.zip`. Verify locally → "ZIP CREATED".
- **Task 10′ — `Scripts/notarize.sh`** (zip flow): takes `<app> <version>`; `ditto` → `notarytool submit submit.zip --wait` → `stapler staple` the **.app** → re-zip the stapled app. Fast-fails on missing `AC_API_*` env.
- **Task 11′ — `.github/workflows/release.yml`**: PyInstaller worker → swift release → assemble → secret-gated Developer-ID sign → notarize+staple+zip (signed) / plain zip (unsigned fallback) → `gh release upload <zip>` → **bump cask** in `bodharma/homebrew-callcapture` using `HOMEBREW_TAP_TOKEN` (signed path only). `workflow_dispatch` dry-run emits an unsigned zip artifact.
- **Task 12′ — tap repo + cask + docs**: create public `bodharma/homebrew-callcapture` with `Casks/callcapture.rb` (version/sha placeholders the CI bump fills; `url` → release zip; `app "CallCapture.app"`; `depends_on macos: ">= :sonoma"`). Add `docs/RELEASING.md` (8 secrets incl. `HOMEBREW_TAP_TOKEN`, how to obtain cert/key/PAT, release flow, verify cmds) and a README **Install (Homebrew)** section (`brew tap bodharma/callcapture && brew install --cask callcapture`).

Exit criteria: tagged release → notarized stapled zip on the release + cask bumped; `brew install --cask bodharma/callcapture/callcapture` installs an app that opens via double-click (`spctl -a -vvv -t install CallCapture.app` accepted).
