# Releasing RepoPrompt CE

RepoPrompt CE has three release/update lanes:

- Contributors can build an ad-hoc release-candidate archive with no secrets.
- Maintainers can publish rolling Tip Builds from latest passing `main` through
  a separate Sparkle update feed for testers who opt in inside the app.
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

The packaged `repoprompt-mcp` exposes one final backend selector:
`--backend app|headless|auto`. **`app` remains the release default.** Explicit
`auto` performs one bounded, connect-only probe of the well-known app socket
before reading the MCP `initialize` request. A successful probe selects the app
proxy; an unavailable socket selects the direct headless runtime. That choice is
immutable for the process lifetime—release validation must reject any
implementation that falls back or switches backends after initialization.
Interactive and one-shot exec modes remain app-backed and reject headless/auto.

A future default cutover to `auto` requires separately reviewed live and release
evidence. Release-candidate validation must exercise all three explicit MCP
selections: an app-backed smoke against a running packaged app, a headless smoke
with no app dependency, and an `auto` smoke in each availability state. It must
also prove immutable selection across app-socket availability changes and
app/headless contract parity for every advertised tool. These checks complement
the package architecture/signature verification; they do not permit a release
job to launch or replace a developer's visible app implicitly. Until that
evidence is accepted, release scripts, package metadata, installers, provider
emitters, and documentation must preserve `app` as the default.

RepoPrompt CE starts a new public release line at `1.0.0 (1)`. Its separate
bundle identifier, Sparkle key pair, and appcast intentionally do not inherit
the closed app's version history.

## Bundled Codex artifact

Debug and release packaging include the complete official OpenAI Codex 0.149.0
standalone package. The authority is the repository-owned
[`Vendor/Codex/manifest.json`](../Vendor/Codex/manifest.json), which pins the
official [`rust-v0.149.0` release](https://github.com/openai/codex/releases/tag/rust-v0.149.0),
the official [`codex-package_SHA256SUMS`](https://github.com/openai/codex/releases/download/rust-v0.149.0/codex-package_SHA256SUMS),
both macOS package assets, their complete extracted layouts, file hashes,
architectures, and primary executable signing identities. The upstream release
publishes SHA-256 sums but does not document a public GPG, minisign, or SLSA
verification procedure, so acquisition requires both the fixed HTTPS release
URLs and agreement between the official checksum file and the independently
pinned repository manifest.

Packaging is the only automatic acquisition boundary; the app never downloads
Codex at runtime. To acquire or inspect the cache explicitly:

```bash
make codex-acquire                         # verifies both macOS packages
make codex-acquire CODEX_ARCH=host         # current host only
make codex-status                          # offline verification of both caches
```

The verified cache lives under `.build/codex-runtime/<manifest-version>/<target>/`
by default and can be relocated with `REPOPROMPT_CODEX_CACHE_ROOT`. Ordinary
host-native debug and non-public packaging defaults to the host target and embeds
one package under that target name. Setting `REPOPROMPT_CODEX_ARCH=all` explicitly
for one of those host-native lanes embeds both target packages. Universal
release-candidate and public release lanes always select `all`, acquire and embed
both official macOS packages, and reject an explicit single-target selection.

Each intact thin package is copied to the stable target-specific layout
`Contents/Resources/BundledRuntimes/Codex/<target>/`. Ordinary host-native output
contains only its selected target directory, while explicit
`REPOPROMPT_CODEX_ARCH=all` output and universal release-candidate/public artifacts
contain both `aarch64-apple-darwin/` and `x86_64-apple-darwin/`. Runtime selection
fails closed unless the package matching the running app architecture is present.
Each target subtree preserves `codex-package.json`, `bin/codex`,
`bin/codex-code-mode-host`, `codex-resources/`, `codex-path/`, and all additional
package resources; the binaries inside remain thin and must match the directory's
target architecture. The two primary macOS executables are
Developer ID signed by `OpenAI OpCo, LLC` (team `2DC432GLL2`) with hardened
runtime and timestamps. RepoPrompt's signing scripts do **not** thin, mutate, or
re-sign anything in this subtree. The outer app signature seals the resource
tree, after which the artifact verifier rechecks every byte, architecture, and
upstream signature. Privileged staged signing and post-notarization validation
run the verifier implementation from trusted control-plane tooling while reading
artifact identity from `REPOPROMPT_APPROVED_SOURCE_ROOT/Vendor/Codex/manifest.json`;
the intentionally minimal staged payload does not carry a second manifest copy.
This mixed-authority layout passes macOS strict deep code
signature verification without changing the upstream binary hashes. Actual
notarization remains enforced by the protected release workflow; if Apple ever
rejects this policy, stop rather than silently re-signing the upstream payload.

The bundled package is RepoPrompt's default Codex runtime authority; runtime
selection never falls through to the user's shell `PATH`. Advanced users may set
one explicit absolute external override with `REPOPROMPT_CODEX_EXECUTABLE`.
RepoPrompt rejects overrides older than 0.149.0, matching the bundled runtime and
the documented app-server contract floor. Bundled and external runtimes both use
RepoPrompt-owned `CODEX_HOME` and `CODEX_SQLITE_HOME` directories under
`~/Library/Application Support/RepoPrompt CE/Codex/{Debug,Release}/`, leaving
`~/.codex` and official Codex App state untouched.

Within that isolated `config.toml`, RepoPrompt owns the
`[mcp_servers.RepoPromptCE]` launch/policy keys, the managed global tool-output
limit, and exactly `[features.code_mode].enabled` plus
`[features.code_mode].direct_only_tool_namespaces`. It preserves other TOML,
applies repeated updates idempotently, and stops with an actionable conflict
instead of guessing when the code-mode policy is ambiguous, uses dotted or inline
definitions that would redefine the owned table/keys, or uses
`non_prefixed_mcp_tool_names`.

The standalone package also contains the upstream Zsh executable at
`codex-resources/zsh/bin/zsh`. Its exact Zsh 5.9 licence is included as
[`ThirdPartyLicenses/codex/ZSH-LICENCE`](../ThirdPartyLicenses/codex/ZSH-LICENCE)
and is covered by the packaged legal inventory checksum contract.

To diagnose acquisition independently of a build, run:

```bash
python3 Scripts/codex_runtime_artifact.py acquire --arch all
python3 Scripts/codex_runtime_artifact.py verify \
  --arch aarch64-apple-darwin \
  --package .build/codex-runtime/0.149.0/aarch64-apple-darwin
python3 Scripts/codex_runtime_artifact.py stage-bundle \
  --arch all \
  --cache-root .build/codex-runtime \
  --bundle /tmp/RepoPrompt-Codex-bundle
python3 Scripts/codex_runtime_artifact.py verify-bundle \
  --arch all \
  --bundle /tmp/RepoPrompt-Codex-bundle
```

Rotate the pin only by reviewing a new official release and its checksum asset,
updating every archive and exact-tree hash in the manifest, capturing the new
license/notice files, and rerunning the offline artifact tests plus a protected
release candidate. Never derive a new pin from an unverified local installation.

### Guarded Codex update candidates

`Scripts/codex_update_candidate.py` prepares evidence for a possible rotation; it
does not edit or replace `Vendor/Codex/manifest.json`. Select exactly one explicit
stable version/tag, or opt in explicitly to GitHub's latest stable release:

```bash
make codex-update-candidate CODEX_CANDIDATE_VERSION=0.150.0
make codex-update-candidate CODEX_CANDIDATE_TAG=rust-v0.150.0
make codex-update-candidate CODEX_CANDIDATE_LATEST=1
```

Official mode accepts no baseline or verification-tool override: it uses the
repository manifest, `/usr/bin/lipo`, `/usr/bin/codesign`, and live official
`openai/codex` metadata/assets. `--release-json`, `--asset-dir`, or any non-default
baseline/tool requires `--fixture-mode`; that mode rejects `--latest-stable` and
marks the report, manifest filename, metadata, marker file, and provenance as a
**NON-PROMOTABLE TEST FIXTURE**. Fixture provenance records the baseline path and
digest, explicit selection mode, input sources, and effective tools so fixture
evidence cannot make an official-online claim.

The tool rejects draft and prerelease releases, requires exactly one checksum
asset and both exact macOS package assets, bounds downloads to the release-declared
size, bounds archive members and total expansion, and verifies the archives
against the upstream checksums. It then
uses the same artifact verifier as packaging to reject extracted-layout, Mach-O
inventory/architecture, normalized-payload, and OpenAI signing-identity drift.
The official output directory contains a proposed `candidate-manifest.json`,
`candidate-provenance.json`, sanitized `release-metadata.json`, the upstream
checksum file, self-checksums, and a deterministic `candidate-report.md`. The live
0.149.0 pin remains authoritative
until a maintainer reviews and deliberately applies a complete rotation change.

The known-good rollback for the 0.149.0 rotation is verified Codex 0.147.0
(`rust-v0.147.0`; arm64 package archive SHA-256
`17b2984eb22b607e3d0c25728252fc90f510e476bad39a6d9f45cdb1aa685432`, x86_64
package archive SHA-256 `d91e59133daf923bc45d76e3da4af8ae9ef62a0231da18488da0cd573b6e9d63`).
After a reviewed rotation, roll back by reverting the complete rotation change and
rebuilding from the restored manifest rather than mixing old and new authority files.

The manual **Codex Runtime Update Candidate** workflow runs only from `main`, has
`contents: read`, uploads those evidence files, and cannot commit, open a pull
request, promote Tip, or publish a release. Local and workflow runs share the same
repository-owned tool. A report is not approval: it leaves the external override
floor as an explicit policy decision and requires schema-gate review (including
`memory_mode`, MCP direct-only behavior, and `thread/start`/`thread/resume`),
license/NOTICE review, focused validation, rollback confirmation, maintainer
approval, and soak before any stable rotation.

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


## Tip Builds

Tip Builds are signed and notarized builds from the latest successful protected
`main` commit. They are official tester builds, not stable releases. Users opt in
from **Settings → Software Updates → Update Channel → Tip Builds**. The default
channel remains **Stable**. Returning from Tip Builds to Stable may not downgrade
immediately; users may need to wait for a newer stable build or reinstall the
stable app manually.

The app uses separate Sparkle feeds:

```text
Stable: https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml
Tip:    https://github.com/repoprompt/repoprompt-ce-tip-updates/releases/latest/download/appcast.xml
```

The Tip channel uses the same CE Sparkle EdDSA key and the same application/feed contract as
stable, but publishes only to the separate tip update repository. It is currently the controlled
`P → T → S` identity-transition rehearsal:

| Role | Application identity | Artifact | Feed contents |
| --- | --- | --- | --- |
| P / `preparer` | Legacy | ZIP, `legacy-preparer` phase | P only |
| T / `transition` | Successor | Notarized successor-Installer-signed PKG | T and retained P |
| S / `successor` | Successor | Notarized ZIP/DMG | S, retained T, and retained P |

`tip-rollout.json` is the checked-in authority for the current role, expected identity, migration
phase, predecessor manifest digests, and any schema-2 reset authority. Every role uses the same Tip
feed URL and `appcast.xml` asset, with retained top-level entries in that appcast; there are no
transition/successor sibling feeds and no Sparkle-key change. Tip workflows must never write to
`repoprompt-ce-updates` or use `v*` tags, and must not feed into `Promote Release`. Stable promotion
remains the only path that updates the stable appcast.

`Publish Tip` runs automatically after successful CI on protected `main`. Every checked-in rollout
role follows the complete build, sign, notarize, smoke, and publish path; a role changes the artifact
and identity policy but never suppresses the release or produces a successful no-publication run.
Manual dispatch remains a recovery path and takes no operator-supplied release inputs. It derives the
rollout role and identity policy from the checked-in declaration on protected `main`.

There is deliberately no commit input. For a manual dispatch, GitHub's selected `main` ref and
`github.sha` are the immutable candidate. Setup fetches protected `origin/main` and requires the
candidate commit, workflow-definition commit, and checked-out release tooling to be that exact live
commit. A stale browser tab therefore cannot publish an older main commit merely because somebody
pasted a convincing SHA into a text box. Before the secret-free build, the protected role-aware
credential preflight runs the same authenticated protected-main verifier used at publication
mutation boundaries. Source reads use the workflow's source-repository token; the separate Tip
updater token is reserved for updater-repository reads and writes. The signing preflight uses an
isolated ephemeral keychain without changing the runner user's keychain search list.

After P is reviewed, advance `tip-rollout.json` with its exact `identity-rollout.json` digest before
merging T; advance it again with T and P digests before merging S. Each published role uses an
immutable `tip-<shortsha>` tag and the tip-only repository's latest release. Do not mark it as a
prerelease, because GitHub excludes prereleases from `releases/latest`.

Current checkpoint: Stable 1.4.0 is the official Stable epoch at build `36`. The authenticated live Tip
is transition tag `tip-57b572038048`, build `35.15.39`, with rollout-manifest SHA-256
`c8d28103b5e95370fc0de7df19c34797552e99803228794754bfbfe292e3e421`; it retains preparer
`tip-2f94412e6ab5` at build `35.15.18`, whose rollout-manifest SHA-256 is
`3c69703fa7582105633b36e8874fe2a28e1832aabb776351e68dbf3367e122db`. That retained P is below
Stable 36, so it cannot safely authorize a transition. The checked-in Tip declaration is schema 2
and carries the sole explicit `resetAuthority` for this exact live transition, retained P, and Stable
epoch. `stable_rollout.py` rejects the T -> P regression unless every recorded tag, manifest digest,
retained-P fact, and Stable epoch fact matches the authenticated public files; no missing, mismatched,
or tampered reset data can act as a procedural bypass. The replacement P must also be newer than both
live Tip `35.15.39` and Stable `36` (the next Tip encoding begins at `36.0.x`). After P is published,
clear the reset authority and advance the declaration with P's exact manifest digest before merging T.
Protected-main review of the rollout declaration is the release authorization boundary: after CI passes,
Tip publication is automatic. Do not merge a T or S declaration until the isolated runtime proof is
approved, including lost-journal recovery and a fresh-successor-install policy.

Tip `CFBundleVersion` values sort between adjacent stable builds. The workflow reads the published
stable appcast and combines that stable build with the source commit count. For example, commit
sequence `795` on stable build `28` becomes Tip build `28.7.95`: it is newer than stable `28`, while
stable `29` still supersedes it. The source commit count must remain at or below `9999`; replace this
encoding before the repository reaches that limit.

During T and S, that normal Stable supersession must be deliberately paused: setup and the final
publisher require the greatest Stable build to remain strictly below the retained P build. Advancing
Stable to the next integer first would make an unprepared Stable client appear new enough to satisfy
T's `sparkle:minimumUpdateVersion`, bypassing the credential preparer.

Automatic and manual runs use separate rolling concurrency lanes. Each lane keeps at most one
queued run and does not cancel in-flight release work; publication remains serialized across both
lanes by `main-tip-publish`. A retry therefore resumes or audits one exact draft instead of abandoning
a different tag halfway through publication.

Remote mutation is confined to that protected publication job. Immediately before draft creation
and again immediately before making a draft public, it rechecks live protected `main`, downloads the
public Tip manifest/appcast, proves that the candidate either rolls the current role or advances one
step through `P → T → S` with exact retained history, and audits every retained enclosure against
GitHub's published size and SHA-256. Rolling P retains no predecessor, rolling T retains the exact
authenticated P, and rolling S retains the exact authenticated T and P. Existing drafts are resumed
only when their metadata and uploaded bytes exactly match;
missing assets are added without overwriting anything. After publication, every public asset is
downloaded anonymously and compared byte-for-byte with the signed local inventory, and the release
must be the repository's latest. The update-repository token is not available to setup, staging, or
smoke jobs.

Configure protected GitHub Actions environments named `release` and `tip-release`, with maintainer
approval and protected-branch restrictions. Before the rehearsal, store this one-time identity
inventory in both environments:

| Material | Legacy/preparer selection | Transition/successor selection |
| --- | --- | --- |
| Application P12/password | `DEVELOPER_ID_APPLICATION_P12_BASE64` / `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | `SUCCESSOR_DEVELOPER_ID_APPLICATION_P12_BASE64` / `SUCCESSOR_DEVELOPER_ID_APPLICATION_P12_PASSWORD` |
| Provisioning profile | `REPOPROMPT_CE_PROVISIONING_PROFILE_BASE64` | `SUCCESSOR_REPOPROMPT_CE_PROVISIONING_PROFILE_BASE64` |
| Notarytool private key/key ID/issuer | `NOTARYTOOL_PRIVATE_KEY_BASE64` / `NOTARYTOOL_KEY_ID` / `NOTARYTOOL_ISSUER_ID` | `SUCCESSOR_NOTARYTOOL_PRIVATE_KEY_BASE64` / `SUCCESSOR_NOTARYTOOL_KEY_ID` / `SUCCESSOR_NOTARYTOOL_ISSUER_ID` |
| Transition Installer P12/password | not used | `SUCCESSOR_DEVELOPER_ID_INSTALLER_P12_BASE64` / `SUCCESSOR_DEVELOPER_ID_INSTALLER_P12_PASSWORD` |

Also retain `CI_KEYCHAIN_PASSWORD`, `SPARKLE_PRIVATE_KEY`, the Sentry credentials/configuration,
and the environment-specific update-repository token. The workflows derive application and Installer
identity labels from `Scripts/apple_identity_policy.json` through `stable_rollout.py
packaging-context`; do not configure `SIGN_IDENTITY`, `SUCCESSOR_SIGN_IDENTITY`, or an installer-name
alias as a second authority. The Tip publishing script fails closed if `TIP_UPDATE_REPOSITORY`
points at the source or stable update repository. Tip artifacts also include a small
`*-metadata.json` asset recording the source commit, immutable tag, marketing version, and build
number.

For application enclosures, the signing job retains the explicit application contract: it submits a
temporary ZIP to notarize the signed app, staples and validates that app, then separately submits,
staples, and validates the DMG. For a transition package, it signs and validates the embedded app
without creating that temporary notarization ZIP. The job then exposes separate timed **Build
package**, **Submit package notarization**, **Staple package**, and **Validate package** steps; the
final Installer-signed PKG is the only Apple submission in package mode. Every submission prints its
Apple submission ID. A failed or non-accepted submission with an ID automatically retrieves its
`notarytool log` before the step fails.

Tip builds use the same Sentry-linked binary and symbolication policy as stable
releases. The secret-free stage enables Sentry linking and carries release dSYMs
inside the staged archive without a DSN or auth token. Only the protected
`tip-release` signing job receives `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, and the
Sentry org/project variables: it injects the DSN through
`sign_staged_release.sh`, uploads the staged dSYMs before signed assets leave
the job, and requires the final artifact manifest to record
`telemetry_enabled: true`. The workflow materializes Sentry auth in an
owner-only temporary token file and removes it through the job's always-run
cleanup step.

## Contributor release candidate

Run:

```bash
make dev-release-preflight
make dev-release-artifact
```

The artifact is written under `dist/`. It exercises universal `arm64+x86_64`
release-mode compilation in isolated SwiftPM directories, resource-equivalence
checking, unsigned product merging, app bundling, legal-file packaging, and
archive extraction validation. Coordinated `release artifact` jobs allow up to
four hours for this dual-architecture path; `package release`, `release package`,
and `release local-install` retain the normal two-hour release timeout. The
artifact is intentionally ad-hoc signed and is not suitable for distribution.
The ZIP is accompanied by a deterministic external
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
visible. Local production packaging requires a full Xcode installation. The
installer preserves an explicit compatible `DEVELOPER_DIR`; otherwise it uses
the selected full Xcode or discovers a compatible Xcode app for that process
without changing the system-wide `xcode-select` setting.

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
| `TIP_UPDATE_REPOSITORY_TOKEN` | Fine-grained GitHub token scoped only to `repoprompt/repoprompt-ce-tip-updates` with repository contents read/write permission. Do not reuse the stable update token. |
| `SENTRY_DSN` | Sentry DSN injected into official signed builds for release routing. It is not a credential, but keep it in the protected release environment so unofficial artifacts do not route telemetry to the official project. |
| `SENTRY_AUTH_TOKEN` | Sentry Organization Token used for draft-time debug-symbol/release metadata and verified-promotion deploy recording. Create it with the fixed `org:ci` scope; Organization Token scopes are immutable, and release tooling does not inspect or change them. |

Add these non-secret GitHub environment variables for Sentry symbol upload in
both the `release` and `tip-release` environments. The workflows map them to
the release scripts' `REPOPROMPT_SENTRY_*` names and explicitly set
`REPOPROMPT_ENABLE_SENTRY=1` for official staging and signing.

| Variable | Contents |
| --- | --- |
| `SENTRY_ORG` | Sentry organization slug. |
| `SENTRY_PROJECT` | Sentry project slug. |

Official stable promotion intentionally requires `SENTRY_AUTH_TOKEN` and the Sentry org/project/environment configuration so it can record the verified production deploy only after public verification.

## Sentry telemetry and debug symbols

Official telemetry-enabled release staging links the Sentry SDK when
`REPOPROMPT_ENABLE_SENTRY=1`. The protected release environment provides
`SENTRY_DSN`, and `Scripts/sign_staged_release.sh` injects it into `Info.plist`
as `RepoPromptSentryDSN`. A DSN is not an auth secret, but it is not committed,
logged, or recorded in artifact manifests so only official signed artifacts route
telemetry to the official project. Manifests record only the non-secret
`telemetry_enabled` boolean.

When Sentry is enabled, stable and Tip staging generate dSYMs under
`.build/sentry-symbols/release` and carry them inside their staged release ZIPs.
Both lanes use the shared deterministic symbol policy to require, copy, and
upload those staged symbols with `upload_sentry_debug_symbols.sh`.
`release.sh publish-staged` additionally requires `SENTRY_AUTH_TOKEN` (or
`REPOPROMPT_SENTRY_AUTH_TOKEN_FILE`), `REPOPROMPT_SENTRY_ORG`, and
`REPOPROMPT_SENTRY_PROJECT` for official Sentry-enabled releases. Before code
signing or notarization, it performs a read-only release API preflight. Release
lookup, creation, commit association, and finalization use Sentry's release API,
which accepts Organization Tokens with `org:ci`; only debug-symbol upload uses
`sentry-cli`. After the GitHub draft exists, the script finalizes the Sentry
release to mark its commit metadata and symbols ready. Finalization does not
mean that the release is deployed to production.
The upload helper runs:

```bash
sentry-cli debug-files upload
```

That uploads only dSYMs/debug files for official release crash symbolication; it
intentionally does not enable source-context upload, so local source files and
source paths are not uploaded to Sentry.

Local/debug symbol upload is opt-in and is mainly for testing the integration:

```bash
REPOPROMPT_ENABLE_SENTRY=1 \
REPOPROMPT_SENTRY_DSN="https://examplePublicKey@o0.ingest.sentry.io/0" \
REPOPROMPT_UPLOAD_SENTRY_SYMBOLS=1 \
REPOPROMPT_SENTRY_ORG="repoprompt" \
REPOPROMPT_SENTRY_PROJECT="repoprompt" \
REPOPROMPT_SENTRY_AUTH_TOKEN_FILE="$HOME/.config/repoprompt/sentry-token" \
./Scripts/package_app.sh debug
```

Prefer `REPOPROMPT_SENTRY_AUTH_TOKEN_FILE` for coordinated `make dev-build` /
conductor runs. The daemon intentionally does not pass through `SENTRY_AUTH_TOKEN`
because it stores job environment snapshots for status and retry identity.

DEBUG telemetry-enabled builds support a shell-only crash probe for validating
Sentry event detail:

```bash
"$HOME/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt" \
  --repoprompt-sentry-test-crash
```

Relaunch the app once without the argument so the SDK can flush the cached native
crash report.

Official workflows do not take an application or Installer identity label from a GitHub Actions
string variable. They derive the expected labels from `Scripts/apple_identity_policy.json` through
`stable_rollout.py packaging-context`, then validate the imported identity in the ephemeral keychain
before signing. The selected provisioning profile must match the role-selected bundle/team pair; the
release tooling validates that identifier before signing.

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
and immediately verifies every source and updater asset anonymously. Before the
first publication mutation, promotion also performs a read-only Sentry deploy
API preflight using a mode-`0600` ephemeral curl configuration. After anonymous
publication verification succeeds, it repeats the deploy list and creates the
exact production/tag deploy only when it is absent. The deploy release-name path
segment is percent-encoded, and the deploy-creating POST is never automatically
retried. The workflow serializes stable-channel
promotion so two CI promotions cannot race. Rerunning the same tag safely
resumes expected partial states only when the existing assets match exactly;
list-before-create makes the Sentry marker idempotent across those serialized
runs. HTTP `403` is reported as an auth/scope gate failure, while malformed API
JSON fails closed separately.

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

## Post-promote Homebrew tap checks

RepoPrompt CE is also distributed through the
[`repoprompt/homebrew-repoprompt-ce`](https://github.com/repoprompt/homebrew-repoprompt-ce)
tap. After **Promote Release** succeeds, verify the tap before announcing
Homebrew availability for that version.

1. Confirm the updater release for the promoted tag contains the expected
   `RepoPrompt-<version>-<build>.zip`, `appcast.xml`, and `SHA256SUMS` assets.
2. Confirm `Casks/repoprompt-ce.rb` in the tap points at the tag-specific
   updater ZIP, not a `latest/download` URL.
3. Confirm the cask version encodes both `MARKETING_VERSION` and `BUILD_NUMBER`
   as `<version>,<build>`.
4. Confirm the cask `sha256` matches the promoted ZIP entry in the updater
   release's `SHA256SUMS`.
5. Run an install smoke:

   ```bash
   brew tap repoprompt/repoprompt-ce
   brew install --cask repoprompt-ce
   ```

6. Confirm Homebrew installed `/Applications/RepoPrompt CE.app`.

If the tap lags the promoted release, update only the tap repository. The
source repository's protected `release` environment and release workflows do
not need Homebrew signing, notarization, or Sparkle secrets.

## Recovery

Never overwrite assets on a published release, reuse a public tag, or move an
existing release tag.

For an incomplete source draft, inspect its assets and either delete the
incomplete draft before rerunning the protected build or resume only after
checksum comparison. If promotion stops after creating or publishing an
updater release, rerun **Promote Release** with the same tag. It resumes only
when the existing updater assets match the reviewed source assets exactly. If
both releases are already public but Sentry deploy creation failed, the same
rerun re-verifies public assets and records the missing deploy; an existing
exact environment/tag deploy is left unchanged. Tooling does not delete or
rewrite premature deploy markers created by older release tooling. For
a public regression, withdraw the bad release if policy allows it and publish a
new hotfix tag with a higher `BUILD_NUMBER`; explicitly promote the hotfix as
latest.

## References

- [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Sparkle customization keys](https://sparkle-project.org/documentation/customization/)
- [GitHub: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub REST API: Get the latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
- [GitHub: Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
