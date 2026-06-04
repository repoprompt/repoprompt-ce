# Releasing RepoPrompt CE

RepoPrompt CE has two release lanes:

- Contributors can build an ad-hoc release-candidate archive with no secrets.
- Maintainers can publish a Developer ID signed, notarized, stapled GitHub
  Release with Sparkle EdDSA-signed update archive metadata through the
  protected `release` environment.

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

Write-access collaborators may request a signed, notarized test build through
the manual **Signed Test Build** workflow, but that request does not grant
access to Apple signing credentials. The build can stage without secrets; the
Developer ID signing job waits on the protected `release` environment.

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

The artifact is written under `dist/`. It exercises release-mode compilation,
app bundling, legal-file packaging, and archive creation. It is intentionally
ad-hoc signed and is not suitable for distribution.

The direct fallback commands are `make release-preflight` and
`make release-artifact`. The GitHub **Release Candidate** workflow runs the same
path on `main` and on manual dispatch, then uploads the archive as a workflow
artifact.

Contributors should not upload this artifact to GitHub Releases. It is useful
for packaging inspection only; it is not notarized or suitable for public
distribution. For runnable release-mode local testing, use the self-signed local
production installer below.

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

The installer creates or reuses a dedicated user-local self-signed code-signing
identity named `RepoPrompt CE Local Self-Signed Code Signing`, installs its
trust policy for code signing in the user's default login keychain, builds the
release configuration, deep-signs the complete bundle, verifies the signature,
and installs `RepoPrompt CE.app` under `/Applications`. macOS may ask the user
to confirm the local certificate trust change when the identity is first
created.

This path is intentionally separate from public distribution. The resulting app
is self-signed, not notarized, must not be uploaded to GitHub Releases, and
should not be copied to another Mac. Official releases continue to require the
CE Developer ID identity, provisioning profile, hardened runtime entitlements,
notarization, and stapling.

## Maintainer setup

Create a protected GitHub Actions environment named `release`. Require
maintainer approval before jobs can access its secrets, and restrict deployment
branches to protected `main`. Do not run production publication until both
controls are enabled. Enable the environment setting that prevents self-review
so the person requesting a signed build cannot approve their own run.

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

## Signed test build

Use **Signed Test Build** when a write-access collaborator needs a real
Developer ID signed and notarized build before the code is ready for a public
release tag.

Dispatch the workflow from protected `main` and enter an exact upstream branch,
exact upstream tag, or full 40-character commit SHA in `source_ref`. Short
branch/tag names and explicit `refs/heads/<branch>` or `refs/tags/<tag>` inputs
are accepted. Raw SHAs are allowed only when the resolved commit is already
reachable from a branch or tag in the canonical upstream repository. Do not use
fork or pull-request refs for this lane; have the collaborator push an
inspectable branch to the upstream repository first. The workflow rejects fork
shorthand, `refs/pull/*` inputs, remote refs, short SHAs, revspecs such as
`main~1` or `main^`, ambiguous branch/tag names, and unreachable SHA-only
commits before staging.

The unprotected job checks out trusted release tooling from `main`, checks out
the requested source ref separately, verifies that the literal requested ref
resolves exactly to the checked-out source commit and that the commit is
reachable from canonical upstream branch or tag refs, strips GitHub tokens
before SwiftPM-driven commands, builds an ad-hoc release-mode app, and uploads a
short-lived staged artifact. The protected `sign` job uses the `release`
environment, so it pauses for required reviewer approval before importing the
Developer ID certificate, provisioning profile, and notarization key. After
approval, trusted tooling revalidates the same requested ref against the
approved-source checkout before importing signing material. If the branch or tag
was deleted, force-pushed, or no longer reaches the validated commit, signing
fails. The signing path then verifies the staged payload against a data-only
checkout of the requested commit, replaces the staged Sparkle framework with the
trusted closed-world copy, signs, notarizes, staples, and uploads ZIP, DMG,
checksum, and provenance workflow artifacts.

Signed test builds do not create GitHub Releases, do not publish updater
assets, and do not use the Sparkle private key. Each final artifact set includes
a `signed-test-provenance.json` file that records the requested ref, resolved
source commit, trusted tooling commit, workflow run URL, signing mode,
sign-time reachable upstream refs, and ZIP, DMG, checksum manifest, and staged
source archive hashes. A fresh secret-free smoke job downloads the signed ZIP,
validates the provenance hash bindings and embedded MCP helper layout, and runs
the helper `--version` smoke under a minimal environment.

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
an ad-hoc app bundle, and uploads that bundle as a short-lived workflow
artifact. The environment-scoped signing job starts on a fresh runner,
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
layout statically and does not execute packaged helper code. After draft
creation, a fresh runner without the protected `release` environment downloads
the signed ZIP, repeats static layout validation, and runs the helper
`--version` smoke under a minimal secret-free environment. The draft notes embed
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
the token is used only for the download step. The runner verifies the reviewed
digest and ZIP checksum, validates the helper layout statically, and runs the
helper `--version` smoke under a minimal secret-free environment. The protected
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
