# Releasing MacSize

Releases are versioned automatically by semantic-release from Conventional Commit PR titles
(see [Cutting a release](#cutting-a-release)) and built by GitHub Actions
(`.github/workflows/release.yml`) on the resulting `v*` tag. Each release is:

- a universal (arm64 + x86_64) `MacSize.app`, Developer ID-signed with the hardened runtime
  and a secure timestamp, notarized and stapled, shipped as a `.zip` (Sparkle's update
  archive) and a signed, notarized `.dmg`;
- the `macsize` CLI as a universal, signed, notarized binary in a `.tar.gz`;
- an EdDSA-signed Sparkle `appcast.xml`, which installed apps check daily;
- `latest.json`, the manifest the CLI's update checker reads.

Everything owner-specific (bundle ID, Team ID, keys) lives in the repository's `release`
environment, never in the source. Builds from source have no feed URL, so they never
auto-update.

## Release assets

For tag `vX.Y.Z`:

| Asset | Purpose |
| --- | --- |
| `MacSize-X.Y.Z.zip` | Sparkle update archive; also a direct download |
| `MacSize-X.Y.Z.dmg` | Drag-to-Applications installer |
| `macsize-X.Y.Z-macos-universal.tar.gz` | CLI; contains a single file, `macsize` |
| `appcast.xml` | Sparkle feed, read from `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` |
| `latest.json` | CLI update manifest, read from `…/releases/latest/download/latest.json` |
| `SHA256SUMS.txt` | Checksums of the above |

`latest.json` has this shape:

```json
{"version":"X.Y.Z","build":"N","published_at":"2026-01-01T00:00:00Z",
 "cli":{"url":".../macsize-X.Y.Z-macos-universal.tar.gz","sha256":"<hex>","ed_signature":"<base64>"},
 "app":{"url":".../MacSize-X.Y.Z.zip","dmg_url":".../MacSize-X.Y.Z.dmg"}}
```

`ed_signature` is Sparkle's EdDSA signature over the raw tarball bytes (`sign_update`),
made with the same key as the appcast, so it verifies against `SUPublicEDKey` /
`BuildInfo.updatePublicEDKey`.

## One-time setup

You need a paid Apple Developer Program membership, admin access to the GitHub repository,
the GitHub CLI (`brew install gh`, then `gh auth login`), and Xcode or the Command Line Tools.

### 1. Create a Developer ID Application certificate

1. Open Xcode > Settings > Accounts, select your team, click **Manage Certificates…**, then
   **+ > Developer ID Application**. (Or create it at
   [developer.apple.com > Certificates](https://developer.apple.com/account/resources/certificates/list)
   with a CSR from Keychain Access, and double-click the downloaded `.cer`.)
2. Check it's in your login keychain with its private key:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   The 10-character value in parentheses is your Team ID.

### 2. Create an App Store Connect API key for notarization

1. Go to [App Store Connect > Users and Access > Integrations > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   (Team Keys). Request access first if asked.
2. Generate a key with the **Developer** role. Download `AuthKey_<KEYID>.p8`. Apple lets you
   download it only once.
3. Note the **Issuer ID** shown above the key list.

### 3. Pick a bundle identifier

Use a reverse-DNS ID you control, such as `io.github.<owner>.macsize`. Don't change it after
the first release: Sparkle and macOS treat a different ID as a different app.

### 4. Run the setup script

From a checkout of the repository:

```sh
scripts/setup-release-secrets.sh --bundle-id io.github.<owner>.macsize \
  --p8 ~/Downloads/AuthKey_ABC123XYZ.p8
```

Add `--repo OWNER/REPO` if the checkout's default remote isn't the target, and try
`--dry-run` first to see what it will do. The script:

- creates the `release` environment if it's missing, restricted to tags matching `v*`;
- lets you pick a Developer ID Application identity, exports **only that** certificate and
  private key (macOS asks you to allow the keychain export) into a `.p12` with a random
  password, and uploads both; it derives `APPLE_TEAM_ID` from the identity;
- uploads the `.p8` key, its Key ID (from the filename) and the Issuer ID (it prompts for it),
  then offers to move the `.p8` to the Trash;
- runs Sparkle's `generate_keys`, which creates an EdDSA key pair in your login keychain (or
  reuses the existing one), and uploads the private key and the public key;
- sets `BUNDLE_ID`.

Secret values are never printed or typed: they go from the keychain or file straight into
`gh secret set` on stdin. Temporary files are created in a private `mktemp` directory and
overwritten before deletion.

Re-run with `--skip-cert`, `--skip-notary` or `--skip-sparkle` to redo only part of it, for
example after renewing the certificate.

**Back up the Sparkle private key.** It's stored in your login keychain as
"Private key for signing Sparkle updates" (account `ed25519`). Export a copy with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>` to somewhere safe, such as a
password manager. If the key is lost, installed copies can never auto-update again; users
would need to download a new release manually.

### What gets configured

Environment `release`:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `MACOS_CERT_P12_BASE64` | Base64 `.p12` with the Developer ID certificate and its private key |
| Secret | `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| Secret | `NOTARY_API_KEY_P8_BASE64` | Base64 App Store Connect API key (`.p8`) |
| Secret | `NOTARY_API_KEY_ID` | Its Key ID |
| Secret | `NOTARY_API_ISSUER_ID` | Issuer ID |
| Secret | `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key (`generate_keys -x` output) |
| Variable | `APPLE_TEAM_ID` | Team ID, used to select and verify the signing identity |
| Variable | `BUNDLE_ID` | Bundle identifier for official builds |
| Variable | `SPARKLE_PUBLIC_ED_KEY` | Sparkle EdDSA public key, embedded as `SUPublicEDKey` |

Optionally, add required reviewers to the `release` environment (Settings > Environments) so
each release waits for approval.

## Cutting a release

### Automatic (recommended)

Releases are cut by [semantic-release](https://semantic-release.gitbook.io/) from
[Conventional Commits](https://www.conventionalcommits.org/). PRs are squash-merged, so the
**PR title** becomes the commit subject on `main`; the **PR title** check
(`.github/workflows/pr-title.yml`) makes sure it's conventional.

| PR title | Release |
| --- | --- |
| `fix: …`, `perf: …`, `revert: …` | patch (`0.1.9` → `0.1.10`) |
| `feat: …` | minor (`0.1.9` → `0.2.0`) |
| `feat!: …`, or a `BREAKING CHANGE:` footer | major (`0.1.9` → `1.0.0`) |
| `docs:`, `ci:`, `build:`, `chore:`, `refactor:`, `style:`, `test:` | none |

A scope is optional: `fix(cli): …`, `feat(app): …`.

On every push to `main`, the **Semantic release** workflow (`.github/workflows/semantic-release.yml`):

1. finds the commits since the latest `vX.Y.Z` tag and works out the next version (or stops if
   none of them warrants a release),
2. tags the merged commit `vX.Y.Z` and creates a **draft** GitHub release named
   "MacSize X.Y.Z" with notes generated from those commits, comments on the released
   PRs and issues, and
3. starts the **Release** workflow on that tag, which builds, signs and notarizes, uploads the
   assets to the draft and publishes it.

If the Release workflow fails, the draft stays unpublished, so the app and CLI are never
offered a release without assets. Fix the problem and re-run the failed workflow (or run
**Release** on the tag from the Actions tab); it publishes the existing draft.

Release notes live on the GitHub release. `CHANGELOG.md` keeps the history up to 0.1.9.

Preview what would be released from a checkout (needs Node 24):

```sh
npm ci
GITHUB_TOKEN="$(gh auth token)" npx semantic-release --dry-run --no-ci
```

Run it on `main`; on other branches semantic-release only reports that the branch isn't
configured to release.

The release job still runs on the tag, which is all the `release` environment (and its signing
secrets) allows, so branch and PR runs never see those secrets.

### Manual

1. Make sure `main` is green and contains what you want to ship.
2. Tag and push:

   ```sh
   git switch main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   A tag with a hyphen, such as `v1.3.0-beta.1`, is published as a **prerelease**. GitHub's
   `releases/latest` URLs skip prereleases, so neither the app nor the CLI is offered a
   prerelease; download it manually to test.
3. Watch the **Release** workflow in the Actions tab. It takes roughly 10–30 minutes, mostly
   waiting on notarization.

The version comes from the tag (`vX.Y.Z` becomes `X.Y.Z`) and the build number is the commit
count (`git rev-list --count HEAD`). Sparkle compares build numbers, so always tag a commit that
descends from the previous release.

The workflow stamps these values into `Sources/MacSizeCore/BuildInfo.swift` with
`scripts/stamp-version.sh` but never commits the result. Nothing in the repository needs a
version bump.

## Verifying a release

Download the assets and check them:

```sh
# App: signature, notarization ticket, Gatekeeper
codesign --verify --strict --deep --verbose=2 MacSize.app
codesign -dv --verbose=4 MacSize.app 2>&1 | grep -E 'TeamIdentifier|Runtime|Timestamp'
xcrun stapler validate MacSize.app
spctl --assess --type execute --verbose=2 MacSize.app     # "source=Notarized Developer ID"

# DMG
xcrun stapler validate MacSize-X.Y.Z.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 MacSize-X.Y.Z.dmg

# CLI
tar -xzf macsize-X.Y.Z-macos-universal.tar.gz
lipo -archs macsize                                      # x86_64 arm64
codesign -dv --verbose=4 macsize 2>&1 | grep TeamIdentifier
spctl --assess --type execute --verbose=2 macsize        # needs network (no stapled ticket)
shasum -a 256 macsize-X.Y.Z-macos-universal.tar.gz       # matches latest.json

# Feeds
curl -sL https://github.com/OWNER/REPO/releases/latest/download/appcast.xml | head -40
curl -sL https://github.com/OWNER/REPO/releases/latest/download/latest.json
```

To test an update end to end, install the previous release, launch it, and choose
**MacSize > Check for Updates…**. With automatic updates on (the default), it downloads the
new version in the background and installs it when you quit.

## Troubleshooting

**"Missing secret …" / "Missing variable …"** — the environment isn't fully configured. Re-run
`scripts/setup-release-secrets.sh`. Secrets must be in the `release` *environment*, not
repository-level secrets with different names.

**The workflow never starts or is rejected by the environment** — the environment's deployment
policy only allows tags matching `v*`. Check Settings > Environments > release.

**"No 'Developer ID Application' identity for team …"** — the `.p12` holds a different
certificate (for example "Apple Development"), or `APPLE_TEAM_ID` doesn't match. Re-run the
script with `--identity <SHA-1 or name>`.

**`errSecInternalComponent` or codesign hangs** — the keychain partition list wasn't set, or
the `.p12` is missing the private key. Re-export with the script.

**Notarization status `Invalid`** — the workflow prints `notarytool log`. Common causes: a
binary without the hardened runtime or secure timestamp, or an unsigned nested binary. Locally,
`codesign --verify --strict --deep --verbose=4 MacSize.app` usually finds it.

**Notarization `401`/`403`** — the API key was revoked, lacks the Developer role, or Key ID /
Issuer ID don't match the `.p8`. Create a new key and re-run the script with `--skip-cert
--skip-sparkle`.

**Certificate expired** — Developer ID certificates last five years. Create a new one and re-run
the script with `--skip-notary --skip-sparkle`. Existing releases keep working, because their
signatures carry secure timestamps.

**Sparkle says the update is improperly signed** — `SPARKLE_ED_PRIVATE_KEY` doesn't match the
`SUPublicEDKey` the installed app shipped with. Never rotate the key casually: restore the
original from your backup. The setup script reuses the key in your login keychain rather than
creating a new one.

**Appcast lost older entries** — each release starts from the previous release's
`appcast.xml` (downloaded with `gh release download`). If the latest release has no appcast
(for example, it was created by hand), the new appcast starts fresh. That's harmless: Sparkle
needs only the newest item.

**Testing the pipeline without publishing** — push a prerelease tag such as `v0.0.1-rc.1` to a
fork with its own `release` environment, then delete the release and tag.

## Local builds

```sh
scripts/build-app.sh                              # ad-hoc signed, host architecture, no updates
ARCHS="arm64 x86_64" scripts/build-app.sh         # universal
SIGN_IDENTITY="Developer ID Application: …" BUNDLE_ID=… scripts/build-app.sh
```

`build-app.sh` writes Sparkle's Info.plist keys only when both `SPARKLE_FEED_URL` and
`SPARKLE_PUBLIC_ED_KEY` are set, so local builds never auto-update. Ad-hoc builds skip the
hardened runtime, since library validation would refuse to load the ad-hoc-signed
`Sparkle.framework`.
