# Releasing CallCapture

Releases are fully automated. Cutting a GitHub Release triggers
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which:

1. Builds the Python worker with PyInstaller and runs its smoke test.
2. Builds the Swift app (release config) and assembles `CallCapture.app`.
3. Signs the app with the **Developer ID Application** certificate.
4. **Notarizes** the app with Apple, staples the ticket, and produces a
   distributable `CallCapture-<version>.zip`.
5. **Uploads** the zip as an asset on the GitHub Release.
6. **Bumps the Homebrew cask** in
   [`bodharma/homebrew-callcapture`](https://github.com/bodharma/homebrew-callcapture)
   — updating the `version` and `sha256` and pushing the change.

If the signing secrets are absent, the workflow falls back to an **ad-hoc
signed, unsigned (not notarized) zip** and skips notarization and the cask bump.
This keeps `workflow_dispatch` dry-runs useful even without the certificates.

The distribution format is a **notarized ZIP** (no DMG), installed via a
Homebrew cask in a dedicated tap.

---

## One-time maintainer setup

### 1. Developer ID Application certificate

1. In the [Apple Developer portal](https://developer.apple.com/account/resources/certificates/list),
   create a **Developer ID Application** certificate.
2. Download and import it into your login keychain, then export it as a
   password-protected `.p12` (Keychain Access → right-click the certificate →
   *Export* → `Personal Information Exchange (.p12)`).
3. Note the certificate's common name — it becomes `MACOS_SIGN_IDENTITY`, e.g.
   `Developer ID Application: Your Name (R72GTBB9MG)`.

### 2. App Store Connect API key (for notarization)

1. In [App Store Connect → Users and Access → Integrations → App Store Connect
   API](https://appstoreconnect.apple.com/access/integrations/api), create a key
   with the **Developer** role.
2. Download the `AuthKey_XXXXXXXXXX.p8` file (you can only download it once).
3. Record the **Key ID** and the **Issuer ID** shown on that page.

### 3. Fine-grained PAT for the Homebrew tap

Create a [fine-grained personal access token](https://github.com/settings/tokens?type=beta)
scoped to **only** the `bodharma/homebrew-callcapture` repository with
**Contents: Read and write** permission. This token lets the release workflow
push the cask bump.

---

## GitHub repository secrets

Add these under **Settings → Secrets and variables → Actions → Repository
secrets** on `bodharma/callcapture`.

| Secret | What it is / how to produce it |
|--------|--------------------------------|
| `MACOS_CERT_P12_BASE64` | Base64 of the exported certificate: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | The signing identity, e.g. `Developer ID Application: Your Name (R72GTBB9MG)` |
| `AC_API_KEY_BASE64` | Base64 of the App Store Connect key: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `AC_API_KEY_ID` | The App Store Connect API **Key ID** |
| `AC_API_ISSUER_ID` | The App Store Connect API **Issuer ID** |
| `APPLE_TEAM_ID` | Your Apple Developer **Team ID** (the `R72GTBB9MG`-style suffix in the identity) |
| `HOMEBREW_TAP_TOKEN` | The fine-grained PAT with `contents:write` on `bodharma/homebrew-callcapture` |

> When all 8 secrets are present the workflow signs + notarizes and bumps the
> cask. If `MACOS_CERT_P12_BASE64` is missing, it emits an unsigned zip and
> skips notarization/cask bump.

---

## Cutting a release

```bash
gh release create v0.2.0 --title "v0.2.0" --notes "Release notes here…"
```

Publishing the release fires the `release: published` event and the workflow
runs automatically. When it finishes, the notarized
`CallCapture-0.2.0.zip` is attached to the release and the cask in
`bodharma/homebrew-callcapture` is updated.

> The workflow strips a leading `v` from the tag, so tag `v0.2.0` produces
> version `0.2.0` in the zip name and the cask.

## Dry-run (no upload)

Once the workflow is on the **default branch** (`main`), you can trigger a
manual build that produces the zip as a workflow artifact instead of uploading
it to a release:

```bash
gh workflow run Release -f version=0.0.0-dryrun
```

`workflow_dispatch` can only be triggered from the default branch, so this is
not available from a feature branch.

---

## Verifying a build

After downloading the zip and unpacking `CallCapture.app`:

```bash
# Gatekeeper assessment — expect: "accepted, source=Notarized Developer ID"
spctl -a -vvv -t install CallCapture.app

# Confirm the notarization ticket is stapled to the bundle
xcrun stapler validate CallCapture.app
```

End-to-end via Homebrew:

```bash
brew install --cask bodharma/callcapture/callcapture
```
