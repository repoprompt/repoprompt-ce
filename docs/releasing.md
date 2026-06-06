# Releasing RepoPrompt CE

RepoPrompt CE has two release lanes:

- Contributors can build an ad-hoc release-candidate archive with no secrets.
- Maintainers can publish a Developer ID signed, notarized, stapled GitHub
  Release with Sparkle EdDSA-signed update archive metadata through the
  protected `release` environment.

Every public artifact in both lanes is universal and must contain matching
`arm64+x86_64` `RepoPrompt` and `repoprompt-mcp` executables. Public builds use
separate SwiftPM scratch directories per architecture, compare package resources
before selecting one equivalent copy, merge unsigned products, and validate all
packaged Mach-O architecture sets before and after signing and after ZIP
extraction. Debug packages and local self-signed production packages remain
host-native.

RepoPrompt CE starts a new public release line at `1.0.0 (1)`. Its separate
bundle identifier, Sparkle key pair, and appcast intentionally do not inherit
the closed app's version history.

## Release ownership

Ordinary contributors prepare release candidates. They do not need Apple
credentials, the Sparkle private key, or permission to create public tags and
GitHub Releases.

Trusted maintainers own public distribution. A maintainer reviews the release
PR, merges it, creates the immutable release tag, dispatches the protected
workflow, tests the resulting draft assets, and promotes the already-reviewed
draft without rebuilding it.

The intended process is:

1. A contributor updates `version.env`, runs `make release-sync-cli-version`,
   and opens a release PR with the synchronized MCP CLI version, release notes,
   and any relevant changelog entry.
2. CI runs ordinary validation plus the secret-free release-candidate lane.
3. Contributors and maintainers inspect the ad-hoc release-candidate artifact
   for packaging correctness. Runnable release-mode local testing uses the
   self-signed local production installer.
4. A maintainer merges the PR and creates a new immutable tag for that exact
   commit.
5. A maintainer dispatches **Publish Release**. CI imports the
   protected secrets, signs, notarizes, staples, and uploads the draft assets.
6. Maintainers test the draft ZIP and DMG without rebuilding them.
7. A maintainer dispatches **Promote Release** for the reviewed tag. CI verifies
   the existing draft, mirrors the public update assets, publishes both
   releases without rebuilding, explicitly marks that tag as GitHub's latest
   stable release, and runs anonymous post-publish checks.

## Contributor release candidate

Run:

```bash
make dev-release-preflight
make dev-release-artifact
```

The artifact is written under `dist/`. It exercises universal `arm64+x86_64`
release-mode compilation in isolated SwiftPM directories, resource-equivalence
checking, unsigned product merging, app bundling, legal-file packaging, and
archive extraction validation. It is intentionally ad-hoc signed and is not
suitable for distribution. The ZIP is accompanied by a deterministic external
`*-artifact-manifest.json` and `SHA256SUMS`; the manifest binds bundle versions,
architecture sets, executable/helper hashes, signing identifiers and teams,
designated requirements, certificate fingerprints when present, and the
canonical entitlement hash without recording secrets, host paths, or timestamps.

The direct fallback commands are `make release-preflight` and
`make release-artifact`. The GitHub **Release Candidate** workflow runs the same
path on `main` and on manual dispatch, then uploads the archive as a workflow
artifact.

Contributors should not upload this artifact to GitHub Releases. It is useful
for packaging inspection only; it is not notarized or suitable for public
distribution. For runnable release-mode local testing, use the self-signed local
production installer below.

## KeyboardShortcuts resource lookup workaround

RepoPrompt currently patches the pinned `KeyboardShortcuts` SwiftPM checkout
during app packaging so the package's localized resources are found inside the
packaged app bundle. Host-native builds patch the default checkout, while public
universal builds patch both isolated architecture checkouts:

```text
.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Utilities.swift
.build/public-release-swiftpm/{arm64,x86_64}/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Utilities.swift
```

The patch is applied **before** Swift compilation, not after the app is built or
signed:

1. `package_app.sh` patches the host-native checkout or delegates to the universal builder.
2. The universal builder patches each architecture's isolated checkout.
3. `swift build` compiles `RepoPrompt` with the patched dependency source.
4. SwiftPM resource bundles are copied into `RepoPrompt.app/Contents/Resources`.
5. The packaged resource layout is validated.
6. The app is signed.

This workaround exists because RepoPrompt's manual app packaging copies the
SwiftPM resource bundle to:

```text
RepoPrompt.app/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle
```

The package patch makes KeyboardShortcuts look there before falling back to its
normal `Bundle.module` lookup. Keep the patch, bundle copy, and validator in
sync; do not remove the workaround without validating that **Settings → Keyboard
Shortcuts** opens successfully in a packaged app build.

This is an intentional short-term release workaround, not the preferred
long-term dependency strategy. A cleaner long-term fix should make the adjusted
KeyboardShortcuts source part of normal dependency resolution by upstreaming the
resource lookup fix, depending on a pinned RepoPrompt fork, or vendoring a local
patched package.

## Install a local self-signed production build

Users who want a release-mode build without maintainer credentials can install
a local-only production app by double-clicking
[`Install RepoPrompt CE Local Production.command`](../Install%20RepoPrompt%20CE%20Local%20Production.command)
in Finder. The Finder launcher requires Python 3, confirms replacement of any
existing installed app, runs the coordinated developer daemon, and keeps the
terminal window open so certificate approval prompts and build results remain
visible.

The equivalent command-line path is:

```bash
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

The direct fallback command is:

```bash
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make install-local-production
```

The installer uses the exact identity name `RepoPrompt CE Local Self-Signed Code
Signing`, but continuity is anchored to the selected certificate's SHA-256
fingerprint rather than to that display name. It inventories every valid
private-key-backed exact-name identity. On first use it mints and registers one
identity only when no valid candidate exists, adopts the sole candidate when
exactly one exists, and refuses ambiguous duplicates. When duplicates exist,
select one explicitly:

```bash
LOCAL_SIGNING_IDENTITY_SHA256=<64-hex-fingerprint> \
  CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

The versioned registry is stored at
`~/Library/Application Support/RepoPrompt CE/local-signing-identity-v1.json`
with owner-only directory and file permissions. It records the exact
certificate fingerprint and local secure-storage service generation. After a
fingerprint is registered, a missing, expired, or private-keyless identity is a
hard failure; the installer never silently adopts or mints a replacement.
Packaging embeds the registered fingerprint and service generation in signed
bundle metadata, verifies the packaged leaf certificate, and prints both the
fingerprint and extracted designated requirement before replacing the installed
app. Repeated installs with the same registry therefore retain the same
designated requirement and Keychain service.

Rotation is deliberately explicit. To mint and register a new identity:

```bash
ROTATE_LOCAL_SIGNING_IDENTITY=1 \
  CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

To rotate to another existing exact-name identity, combine rotation with
`LOCAL_SIGNING_IDENTITY_SHA256`. Each local Keychain service name is scoped by
both the registered certificate fingerprint and generation. First registration
uses a high-entropy generation
so deleting and recreating the registry cannot predictably reconnect to an old
service; rotation increments the recorded generation instead of
overwriting the prior service, and registry loss cannot route a different
certificate into an earlier identity's service. Secrets in the prior
local generation are not copied and are inaccessible to the newly signed app;
the prior certificate and service remain available for rollback or manual
re-entry. If app replacement or the atomic registry update fails, the installer
restores the prior app and leaves the prior registry authoritative.

This path is intentionally separate from public distribution. The resulting app
is host-native, self-signed, not notarized, must not be uploaded to GitHub
Releases, and should not be copied to another Mac. Official releases continue to require the
CE Developer ID identity, provisioning profile, hardened runtime entitlements,
notarization, and stapling.

## Maintainer setup

Create a protected GitHub Actions environment named `release`. Require
maintainer approval before jobs can access its secrets, and restrict deployment
branches to protected `main`. Do not run production publication until both
controls are enabled. Enable the environment setting that prevents self-review
so the person initiating a protected release deployment cannot approve their own run.

Add an immutable release-tag ruleset for `v*` tags. Allow maintainers to create
new release tags, but prevent updates and deletion after creation. The release
scripts re-resolve the remote tag before draft upload and again before
promotion; the ruleset makes that repository policy explicit.

Enable GitHub **Release immutability** for both `repoprompt/repoprompt-ce` and
`repoprompt/repoprompt-ce-updates` before the first stable publish. The tag
ruleset protects tag creation history; release immutability additionally locks
published release assets and their associated tag.

Add these environment secrets:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as PKCS#12. |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used for the PKCS#12 export. |
| `CI_KEYCHAIN_PASSWORD` | Random password for the ephemeral CI keychain. |
| `REPOPROMPT_CE_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `com.pvncher.repoprompt.ce`. |
| `NOTARYTOOL_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key accepted by `notarytool`. |
| `NOTARYTOOL_KEY_ID` | App Store Connect API key ID. |
| `NOTARYTOOL_ISSUER_ID` | App Store Connect API issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Modern Sparkle EdDSA private-key seed for the CE update channel. It must decode from base64 to exactly 32 bytes. |
| `PUBLIC_UPDATE_REPOSITORY_TOKEN` | Fine-grained GitHub token scoped only to `repoprompt/repoprompt-ce-updates` with repository contents read/write permission. |

The optional `SIGN_IDENTITY` environment variable defaults to:

```text
Developer ID Application: Eric Provencher (648A27MST5)
```

The provisioning profile must authorize:

```text
648A27MST5.com.pvncher.repoprompt.ce
```

The release script validates that identifier before signing.

`PUBLIC_UPDATE_REPOSITORY_TOKEN` is intentionally separate from the workflow's
source-repository `github.token`. Keep its repository scope narrow: the
promotion workflow needs to create and publish GitHub Releases in the public
artifact-only update repository, but it does not need broader organization
permissions.

App Store Connect organization API access must be enabled before generating the
notarization `.p8` key. If **Users and Access → Integrations → App Store Connect
API** shows **Request Access**, complete that approval step before creating the
three `NOTARYTOOL_*` secrets. A team key with the least-privilege `Developer`
role is sufficient for the documented `notarytool` flow. After storing the
secrets, remove the one-time `.p8` download from the local machine.

## Build a draft release

1. Update `version.env`, run `make release-sync-cli-version`, and commit the
   synchronized release state.
2. Create and push a tag pointing at that commit.
3. Dispatch **Publish Release** from protected `main` with the existing tag.
4. Review and test the draft GitHub Release assets before promotion.

The workflow's no-secret validation job first requires the requested tag to be
reachable from protected `main`. A separate unprotected staging job uses
release tooling pinned to the exact validated `main` SHA and checks out the
approved tag commit as release source with read-only permissions and without
persisted checkout credentials. After remote-tag attestation it scrubs GitHub
tokens before invoking SwiftPM-controlled commands. It resolves dependencies without lockfile
drift, builds the approved source, verifies the trusted Sparkle payload, stages
a universal ad-hoc app bundle plus its deterministic artifact manifest, and
uploads that payload as a short-lived workflow artifact. The environment-scoped signing job starts on a fresh runner,
downloads and verifies the staged artifact, then imports the Developer ID
certificate and notarization key. Before secrets are imported, trusted tooling
extracts the untrusted staging archive with path-confinement checks and verifies
its path shape, metadata, and packaged legal files against a data-only checkout
of the approved commit. Trusted tooling rechecks the immutable remote tag SHA,
replaces the staged Sparkle framework with the closed-world verified
trusted-control-plane copy, renders hardened runtime entitlements from trusted
policy, signs the staged bundle, notarizes and staples the app and DMG, creates a Sparkle appcast with the trusted
`generate_appcast` binary, and uploads ZIP, DMG, appcast, and checksum assets to
a draft GitHub Release. Privileged signing validates the embedded MCP helper
layout statically and does not execute packaged helper code. After draft creation, a fresh runner without the protected `release`
environment downloads the signed ZIP and artifact manifest, repeats layout and
universal-architecture validation, verifies manifest binding, runs the exact
contained helper's early `--version` smoke, and completes the isolated packaged
app bootstrap/`windows` roundtrip. Protected signing jobs never execute packaged
app or helper code. The draft notes embed
the approved release-commit SHA.
Draft-only creation is intentional: **Promote Release** is the sole stable
publication path. The appcast enclosure already points at the immutable,
tag-specific public updater ZIP URL that promotion will populate.

The current app enables Sparkle's required update-archive verification through
`SUPublicEDKey`. It does not currently opt into the stronger optional
`SURequireSignedFeed` mode, so do not describe the XML feed itself as
cryptographically required.

## GitHub-hosted Sparkle feed

The appcast URL committed in the app is:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml
```

The deliberately public, artifact-only
[`repoprompt/repoprompt-ce-updates`](https://github.com/repoprompt/repoprompt-ce-updates)
repository keeps the Sparkle feed and update ZIP anonymously downloadable while
the source repository remains private during release validation. The
organization currently disables GitHub Pages creation, so the feed uses public
GitHub Release assets rather than Pages. Draft releases stay invisible to
installed clients while maintainers review them.

Each appcast enclosure must use an immutable tag-specific ZIP URL:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/download/<tag>/RepoPrompt-<version>-<build>.zip
```

Do not point update archive enclosures at `latest/download`. The moving
`latest/download/appcast.xml` URL is only for locating the current feed.

GitHub Releases in the artifact-only repository are a good initial host while
stable releases are linear and a one-item feed is sufficient. Prefer a
project-controlled static host later if CE needs cumulative feed history,
binary deltas, beta channels, backports, or feed promotion independent of
GitHub's latest-release selection.

## Private-repository updater smoke

After the protected workflow produces a Developer ID signed, notarized draft
ZIP, download that ZIP locally and run:

```bash
CONFIRM_PUBLIC_UPDATE_TEST=1 \
  ./Scripts/publish_public_update_test.sh /path/to/RepoPrompt-<version>-<build>.zip
```

This maintainer-only helper refuses ad-hoc archives. It verifies the Developer
ID signature, expected Apple team, stapled notarization ticket, bundle
identifier, marketing version, and build number before publishing the ZIP,
generated appcast, and checksums as a public updater-smoke release in
`repoprompt-ce-updates`.

The helper reads the CE Sparkle private key from the local Sparkle Keychain
account `repoprompt-ce`. It refuses to overwrite an existing public test tag
and publishes that tag with `--latest=false`, so a private-source smoke run
cannot replace the stable feed selected by `latest/download/appcast.xml`.

## Promote and verify

After reviewing the source draft ZIP and DMG, compute the SHA-256 digest of the
reviewed source-draft `SHA256SUMS` file:

```bash
shasum -a 256 SHA256SUMS
```

Dispatch the environment-scoped **Promote Release** workflow from protected
`main` with the same tag and that reviewed digest. Before the protected
promotion job starts, a fresh runner downloads the reviewed ZIP and checksum
manifest with a source-repository token scoped only to contents access. GitHub
requires contents write permission for that token to read draft release assets;
the token is used only for the download step. The runner verifies the reviewed digest, ZIP checksum, artifact manifest, and
universal architecture policy, validates the helper layout statically, runs the
exact contained helper's early `--version` smoke, and completes the isolated
packaged app bootstrap/`windows` roundtrip. The protected
job then runs:

```bash
./Scripts/promote_release.sh promote
```

The script refuses a prerelease, extra or missing assets, checksum drift,
invalid Developer ID signing or notarization, ZIP/DMG content mismatch,
packaged legal-tree drift, bundle metadata drift, multi-item appcasts, an
appcast that does not target the immutable public updater URL, a protected
private key that does not match the committed app public key, a signature
mismatch against the committed public key, a non-canonical or metadata-mismatched
release tag, a moved remote tag, a missing release-commit attestation, a private
source repository, a reviewed-checksum digest mismatch, or a build number that
does not advance the current stable channel. Rollback protection treats an
explicit GitHub `404` as the empty first-release state and fails closed on other
API or network errors.

Protected promotion validates the ZIP and mounted DMG helper layouts statically;
it does not execute packaged helper code while source and updater tokens or the
Sparkle private key are available. After verification, it creates or resumes an
updater draft with the reviewed ZIP, appcast, and checksums, publishes the
updater release, publishes the source release, explicitly marks both as latest,
and immediately verifies every source and updater asset anonymously. The workflow serializes stable-channel
promotion so two CI promotions cannot race. Rerunning the same tag safely
resumes expected partial states only when the existing assets match exactly.

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml
https://github.com/repoprompt/repoprompt-ce-updates/releases/download/<tag>/<zip>
https://github.com/repoprompt/repoprompt-ce/releases/download/<tag>/<dmg>
```

The promotion gate confirms:

- `/releases/latest` resolves to the intended tag.
- `appcast.xml` returns HTTP `200` after redirects.
- The feed reports the expected marketing version and monotonically increasing
  `CFBundleVersion`.
- The enclosure uses the intended tag-specific ZIP URL.
- The ZIP EdDSA signature verifies against the public key embedded in the
  packaged app.
- ZIP and DMG SHA-256 values match `SHA256SUMS`.
- The mounted DMG app matches the verified ZIP app, including packaged legal
  resources.
- The reviewed external artifact manifest regenerates exactly from both ZIP and
  DMG app contents and is mirrored unchanged to the public updater release.

## Recovery

Never overwrite assets on a published release, reuse a public tag, or move an
existing release tag.

For an incomplete source draft, inspect its assets and either delete the
incomplete draft before rerunning the protected build or resume only after
checksum comparison. If promotion stops after creating or publishing an
updater release, rerun **Promote Release** with the same tag. It resumes only
when the existing updater assets match the reviewed source assets exactly. For
a public regression, withdraw the bad release if policy allows it and publish a
new hotfix tag with a higher `BUILD_NUMBER`; explicitly promote the hotfix as
latest.

## References

- [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Sparkle customization keys](https://sparkle-project.org/documentation/customization/)
- [GitHub: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub REST API: Get the latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
- [GitHub: Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
