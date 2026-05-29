# Signed, Self-Contained `.app` on Releases — Design

**Date:** 2026-05-29
**Status:** Approved (design), pending implementation plan
**Scope:** Produce a notarized, download-and-run macOS `.app` (with the Python worker bundled) and attach it as a DMG to GitHub Releases via CI.

---

## 1. Goal

A user should be able to download a DMG from the GitHub Releases page, drag
CallCapture to Applications, and use it — no source checkout, no `python3`, no
`pip install`, no Gatekeeper bypass.

To get there we must solve three things the project does not currently have:

1. **Bundle the Python worker** into the `.app` so transcription works without a
   developer environment (today the app looks for `python-worker/` next to the
   bundle and a system `python3`).
2. **Sign + notarize** with a Developer ID so Gatekeeper accepts a double-click.
3. **Automate** build → sign → notarize → DMG → release-upload in CI.

---

## 2. Scope decisions

- **Notarized Developer ID** distribution (Gatekeeper-clean), not ad-hoc.
- **Self-contained worker** via PyInstaller (no user Python).
- **DMG** release asset.
- **Local Whisper (`pywhispercpp`) is deferred from the binary for v1.** Its
  native whisper.cpp libraries complicate notarization. The shipped app supports
  **remote engines (AssemblyAI / Deepgram) + full analysis** (sentiment,
  insights, acoustic emotion). `local_whisper` already degrades to a stub via a
  lazy `try/except ImportError`, so selecting it in the packaged app simply
  yields the stub; local Whisper remains a from-source feature. Revisit later.

---

## 3. Architecture

```
release published (tag v*)  ─►  GitHub Actions  (runs-on: macos-15)
  1. PyInstaller        → dist/callcapture-worker            (standalone, no system Python)
  2. swift build -c release --product CallCapture            → release binary
  3. Scripts/assemble-app.sh → CallCapture.app
        Contents/MacOS/CallCapture                           (Swift)
        Contents/Resources/worker/callcapture-worker         (+ PyInstaller payload)
        Contents/Info.plist
  4. codesign inner→out (Developer ID, hardened runtime, entitlements, --timestamp)
  5. hdiutil/create-dmg → CallCapture-<version>.dmg
  6. notarytool submit --wait  →  stapler staple
  7. gh release upload <tag> CallCapture-<version>.dmg
```

---

## 4. Components

### 4.1 Worker packaging (PyInstaller)

- `python-worker/packaging/worker_entry.py` — thin entry: `from app.cli import main; main()`.
- `python-worker/packaging/callcapture-worker.spec` — PyInstaller spec producing
  a **one-folder** build (`dist/callcapture-worker/`) named `callcapture-worker`.
  One-folder is preferred over one-file: faster startup, and every nested `.so`
  is a real file we can codesign individually.
- Bundled dependencies (all pip wheels, PyInstaller-friendly):
  `pydantic, click, numpy, openai, anthropic, httpx, onnxruntime, audonnx,
  audeer, audiofile`.
- `pyproject.toml` gains a `packaging` optional-dependency group adding
  `pyinstaller`.
- **Hidden imports / lazy modules:** `audonnx`/`onnxruntime` are imported lazily;
  add them to the spec's `hiddenimports` so PyInstaller includes them. The
  acoustic-emotion ONNX model itself is still downloaded at runtime (unchanged,
  ~1 GB, opt-in) — only the runtime libraries are bundled.
- **Excluded:** `pywhispercpp` (and its whisper.cpp native libs) — see §2.

The packaged worker must expose the identical CLI contract: `callcapture-worker
transcribe` reading a `JobRequest` JSON on stdin and emitting `ProgressUpdate`
(stderr) + `JobResult` (stdout), plus the existing ping handling.

### 4.2 Swift bridge change

`PythonBridge` resolution gains a **bundled-worker mode**, checked first:

1. **Bundled:** if `Bundle.main/Contents/Resources/worker/callcapture-worker`
   exists and is executable → run it directly (`<worker> transcribe`), no
   `python3`. This is the path for distributed apps.
2. **Dev:** existing `CALLCAPTURE_WORKER_DIR` / sibling `python-worker` + system
   `python3 -m app.cli` path (unchanged).

Extract the resolution into a small, unit-tested helper
(`WorkerLauncher` / a static func) returning either `(executable, baseArgs)` for
the bundled binary or `(python3, ["-m","app.cli"])` for dev. Job execution code
then appends `command` + streams stdin/stdout the same way for both.

### 4.3 Bundle assembly script

`macos-app/Scripts/assemble-app.sh`:
- Inputs: build config (release), path to the PyInstaller `dist/callcapture-worker`.
- Creates `CallCapture.app/Contents/{MacOS,Resources,Info.plist}`.
- Copies the Swift release binary → `MacOS/CallCapture`.
- Copies the PyInstaller output → `Resources/worker/`.
- Leaves signing to a separate step (so local ad-hoc and CI Developer ID share
  the same assembly).

This replaces the current "assembled out-of-band" gap that `build-app.sh` warns
about. `build-app.sh` is updated to call `assemble-app.sh` (still ad-hoc signing
for local dev).

### 4.4 Signing + notarization

- **Order:** sign inner→out — every `.so`/`.dylib` and the `callcapture-worker`
  binary first, then the outer `CallCapture.app`. Avoid `--deep` (deprecated and
  unreliable for this); iterate nested Mach-O explicitly in the signing script.
- **Flags:** `--force --options runtime --timestamp --entitlements <file>
  --sign "$MACOS_SIGN_IDENTITY"`.
- **Entitlements** (`Scripts/entitlements.plist`) add, for the embedded Python
  interpreter under hardened runtime:
  - `com.apple.security.cs.disable-library-validation` (load bundled,
    differently-signed Python C extensions)
  - keep `com.apple.security.device.audio-input`
  - add `com.apple.security.cs.allow-jit` only if a runtime check shows Python
    needs it (default: omit; add if notarization/run reveals a need).
- **Notarization:** `xcrun notarytool submit CallCapture-<ver>.dmg --wait` using
  an **App Store Connect API key** (`.p8` + key id + issuer id) — no app-specific
  password. Then `xcrun stapler staple` the DMG.

### 4.5 DMG

- Built with `hdiutil` (or `create-dmg` if available) containing
  `CallCapture.app` + an `/Applications` symlink for drag-install.
- Named `CallCapture-<version>.dmg` (version from the release tag).

### 4.6 Release CI (`.github/workflows/release.yml`)

- **Triggers:** `release: { types: [published] }` and `workflow_dispatch`
  (manual, for dry-runs).
- **Runner:** `macos-15` (Xcode 16 / Swift 6, required by FluidAudio — same as
  the existing CI fix).
- **Secret-gated signing:** a guard step checks whether signing secrets are
  present. If **absent** (forks, PRs, contributors): build the `.app` + DMG
  **unsigned/ad-hoc** and **skip** import-cert/notarize/staple — the workflow
  still succeeds and produces a testable artifact. If **present**: full Developer
  ID + notarize + staple.
- Steps: setup-python → PyInstaller build → setup Swift/Xcode → swift build →
  assemble-app → [import cert to temp keychain] → codesign → make DMG →
  [notarize + staple] → `gh release upload`.
- Keychain hygiene: create a temporary keychain, import the `.p12`, and delete it
  in an `always()` cleanup step.

---

## 5. Required secrets (user-provided, manual prerequisites)

Cannot be automated; the user must create these once:

1. **Developer ID Application** certificate (Apple Developer portal) → export `.p12`.
2. **App Store Connect API key** (Users and Access → Keys) → `.p8`, Key ID, Issuer ID.
3. GitHub repository **secrets**:
   - `MACOS_CERT_P12_BASE64` — base64 of the `.p12`
   - `MACOS_CERT_PASSWORD` — the `.p12` export password
   - `MACOS_SIGN_IDENTITY` — e.g. `Developer ID Application: <Name> (<TEAMID>)`
   - `AC_API_KEY_BASE64` — base64 of the `.p8`
   - `AC_API_KEY_ID`
   - `AC_API_ISSUER_ID`
   - `APPLE_TEAM_ID` — e.g. `R72GTBB9MG`

The implementation plan will include a short `docs/RELEASING.md` documenting how
to obtain each and cut a release.

---

## 6. Implementation phasing

- **Phase 1 — self-contained app (no Apple credentials needed):**
  PyInstaller spec + worker entry, `PythonBridge` bundled-worker mode + helper
  test, `assemble-app.sh`, `build-app.sh` update. **Exit criteria:** an ad-hoc
  signed `CallCapture.app` built locally transcribes a sample via a **remote**
  engine with **no** `python-worker/` source and **no** dev `python3` on PATH.
- **Phase 2 — notarized release pipeline:**
  Entitlements update, inner→out signing script, DMG packaging, notarization,
  `release.yml`, `docs/RELEASING.md`. **Exit criteria:** a tagged release yields
  a notarized, stapled DMG attached to the release that opens via double-click on
  a clean Mac (`spctl -a -vvv` accepts it).

Phase 1 proves the hard part (the bundled worker actually runs) before wiring
Apple credentials.

---

## 7. Testing

**Python / packaging:**
- PyInstaller build succeeds in CI; smoke test the artifact:
  `callcapture-worker --version` and a ping JSON on stdin return cleanly.
- A remote-engine job through the packaged worker (mocked HTTP) returns a valid
  `JobResult` — guards the CLI contract parity.

**Swift:**
- `WorkerLauncher` resolution unit test: bundled path chosen when the worker
  exists; dev path otherwise.
- `assemble-app.sh` smoke test: produces the expected bundle layout.

**Release pipeline:**
- `workflow_dispatch` unsigned dry-run produces a DMG artifact (no secrets).
- Signed/notarized path verified manually once secrets exist:
  `spctl -a -vvv -t install CallCapture.app` → "accepted, source=Notarized
  Developer ID"; `stapler validate` on the DMG.

---

## 8. Risks / notes

- **Hardened-runtime + embedded Python:** the most likely failure is a missing
  entitlement or an unsigned nested `.so` failing notarization. Mitigation:
  one-folder PyInstaller (sign every nested Mach-O), `disable-library-validation`,
  and reading the notary log on rejection.
- **Worker size:** bundling onnxruntime + numpy adds tens of MB; the DMG will be
  noticeably larger than the 9.3 MB Swift-only bundle. Acceptable.
- **First-launch quarantine on the DMG contents** is resolved by stapling.
- **No local Whisper in the binary** (v1) — documented in README so users know
  the packaged app uses remote engines; local Whisper needs a source build.

---

## 9. Out of scope

- Bundling `pywhispercpp` / local Whisper (deferred).
- Mac App Store distribution / sandboxing.
- Auto-update (Sparkle).
- Universal vs Apple-Silicon-only: build **arm64** only for v1 (matches project
  guidance); Intel/universal can come later.
