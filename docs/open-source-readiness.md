# Open-Source and Release Readiness Notes

Current as of 2026-06-02. This is a contributor/maintainer inventory for RepoPrompt CE's public-readiness work. It documents the current state and follow-ups; it is not legal advice or a substitute for legal review.

## Release metadata and signing

Release/debug packaging currently derives app identity from [`version.env`](../version.env):

- `APP_NAME=RepoPrompt`
- `DISPLAY_NAME="RepoPrompt CE"`
- `MARKETING_VERSION=1.0.0`
- `BUILD_NUMBER=1`
- `BUNDLE_ID=com.pvncher.repoprompt.ce`
- `SIGNING_TEAM_ID=648A27MST5`

RepoPrompt CE starts a new public release line at `1.0.0 (1)`. The separate CE
bundle identifier, Sparkle key pair, and appcast intentionally do not inherit
the closed app's version history. Treat these values as maintainer-owned
release metadata. Contributors should not change bundle IDs, signing team IDs,
Sparkle keys, or release channels unless a maintainer has explicitly provided
the replacement values. Forks that need a branded app should override locally
or carry their own release metadata patch.

`./Scripts/package_app.sh release` produces a signed release `.app` bundle. A signed release requires `SIGN_IDENTITY` and a `REPOPROMPT_PROVISIONING_PROFILE` for `648A27MST5.com.pvncher.repoprompt.ce`, renders the CE entitlements template, uses timestamped hardened-runtime signing, verifies the signed bundle identifier/team, uses Keychain-backed secure storage, copies the root `LICENSE` and `THIRD_PARTY_NOTICES.md` files into `Contents/Resources/Legal`, and recursively copies root [`ThirdPartyLicenses/`](../ThirdPartyLicenses/) into `Contents/Resources/Legal/ThirdPartyLicenses/` in the packaged app.

[`Scripts/release.sh`](../Scripts/release.sh) adds a secret-free ad-hoc release-candidate lane plus the maintainer publishing lane: resolved-lockfile drift checks, a secret-free approved-source staging job, a fresh protected signing runner, trusted-control-plane Developer ID signing and Sparkle metadata generation, notarization, stapling, ZIP and DMG generation, checksums, packaged legal-tree verification, remote-tag SHA attestation, and draft-only GitHub Release creation. [`Scripts/promote_release.sh`](../Scripts/promote_release.sh) verifies the reviewed draft, rechecks the immutable remote tag SHA and draft attestation, confirms that the modern Sparkle private-key seed matches the app bundle public key and independently verifies the appcast ZIP signature, rejects asset, reviewed-checksum, or stable-build drift, compares the mounted DMG app with the verified ZIP app, mirrors the public update assets, publishes both releases without rebuilding, resumes matching partial states, fails closed on stable-channel API errors other than an explicit first-release `404`, and runs anonymous post-publish checks. The contributor and maintainer process, GitHub workflows, required environment controls, and secrets are documented in [`docs/releasing.md`](releasing.md).

## Sparkle metadata

[`AppBundle/Info.plist.template`](../AppBundle/Info.plist.template) currently contains Sparkle fields:

- `SUFeedURL=https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml`
- `SUPublicEDKey=<public EdDSA key committed in the plist>`
- `SUBundleName=RepoPrompt CE.app`

These are documented as maintainer-owned release/update-channel values. Do not replace them with guessed fork values. The inherited Sparkle EdDSA key pair was rotated to a CE-specific pair on 2026-05-31: only the new public key is committed, the private key is stored in the GitHub `release` environment, and the app-side Sparkle integrity checks agree with the plist values.

The stable feed is hosted in the deliberately public, artifact-only
[`repoprompt/repoprompt-ce-updates`](https://github.com/repoprompt/repoprompt-ce-updates)
repository. This keeps the appcast and signed updater ZIP anonymously
downloadable while the source repository remains private during validation.
The organization currently disables GitHub Pages creation, so the feed uses
public GitHub Release assets in that repository rather than Pages.

Release validation semantically couples Sparkle installer-launcher configuration
to the app's entitlement sandbox state. RepoPrompt CE is currently
non-sandboxed, so `SUEnableInstallerLauncherService` and other Sparkle
sandbox-service keys must remain absent or `false` unless maintainers migrate
the app to sandboxed entitlements in the same release configuration change. A
future sandbox migration should update the Info.plist template and all release
entitlement profiles together so static validation can prove the update channel
configuration is coherent.

Known update-channel limitation: v1.0.0 shipped with
`SUEnableInstallerLauncherService=true` even though the CE app was
non-sandboxed. An installed v1.0.0 app may detect v1.0.2 or later but fail while
connecting to Sparkle's installer. Because the already-running v1.0.0 updater
configuration controls that attempted self-update, later source fixes cannot
repair v1.0.0 before replacement; manual installation of the latest release is
the official workaround. Continue to verify future candidates with static
release validation and, when available, a dedicated self-update smoke from a
known-good previous release.

## Dependency pins

The root [`Package.swift`](../Package.swift) uses exact versions or fixed revisions. The CE fork dependencies previously expressed as branch references are now pinned to the resolved revisions:

| Dependency | Current manifest form | Current `Package.resolved` state | Readiness note |
| --- | --- | --- | --- |
| `https://github.com/provencher/swift-sdk.git` | `revision` | `cb6a62f7c266ed535792b3e9e6e05dc3f0dac8e4` | Pinned. |
| `https://github.com/jamesrochabrun/SwiftAnthropic` | `revision` | `b7d030cd7453f314c780f5492385f73d704cbd5d` | Pinned. |
| `https://github.com/provencher/SwiftOpenAI` | `revision` | `1211782eb337e7968124448a20d9260df1952012` | Pinned. |

Fixed-revision tree-sitter grammar packages are immutable from SwiftPM's perspective, but they still require license attribution like other dependencies. The seven migrated C, Dart, Go, Java, JavaScript, Python, and Rust grammars use source-preserving exact revision pins, and the curated [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) bundle maps those pins plus the other directly linked Tree-sitter grammar products, `SwiftTreeSitter`, its embedded runtime, and the runtime's ICU subset notice. `Package.resolved` should stay committed so local and CI resolutions match unless maintainers intentionally update dependency versions.

Clean coordinated SwiftPM root graphs compile the exact-pinned upstream JavaScript and Python parser objects but omit their external-scanner objects. CE therefore carries the narrow internal [`Sources/TreeSitterScannerSupport`](../Sources/TreeSitterScannerSupport/) compatibility target: byte-for-byte exact-snapshot copies of only those two upstream scanner implementations and their required helper headers. The package URLs, revisions, and upstream products remain unchanged. [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) records the copied-file checksums. Remove the support target, guardrails, checksums, and documentation exception together only after validated upstream revisions or SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

The in-repo provider package at [`Packages/RepoPromptAgentProviders`](../Packages/RepoPromptAgentProviders) is intentional: it is a path dependency used by the root app while provider code is staged for a future external package split.

## Third-party license/notice inventory

Contributor-visible license expectations before public distribution:

| Component | Location | Current notice source | Follow-up |
| --- | --- | --- | --- |
| Sparkle | `Vendor/Sparkle/Sparkle.xcframework` | Sparkle 2.9.2 license, release asset provenance, downloaded-archive SHA-256, and a closed-world typed manifest for the installed framework and trusted tools are copied under `Vendor/Sparkle`; the license is also copied under `ThirdPartyLicenses/sparkle`. | Included in packaged legal files. |
| UniversalCharsetDetection / uchardet | `Vendor/UniversalCharsetDetection` | License and author notices are copied under `ThirdPartyLicenses/universal-charset-detection`. | Included in packaged legal files. |
| PCRE2 | `Sources/CSwiftPCRE2/src` | License header is copied to `ThirdPartyLicenses/pcre2/LICENSE.txt`. | Included in packaged legal files. |
| SLJIT | `Sources/CSwiftPCRE2/deps/sljit` | License is copied to `ThirdPartyLicenses/sljit/LICENSE`. | Included in packaged legal files. |
| wildmatch / OpenBSD-derived fnmatch material | `Sources/RepoPromptC/src/wildmatch/wildmatch.c`, `Sources/RepoPromptC/include/wildmatch.h` | Both checked-in files contain BSD-style notice blocks; `wildmatch.h` includes its existing advertising acknowledgement condition. | Source headers remain preserved. Their full checked-in notice text is reproduced in root `THIRD_PARTY_NOTICES.md` and bundled under `Contents/Resources/Legal` during app packaging. |
| Tree-sitter grammar packages, `SwiftTreeSitter`, embedded runtime, and runtime ICU subset | `Package.swift`, `Package.resolved`, [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) | The curated Tree-sitter README maps exact package/runtime pins to full copied license files, including the embedded ICU subset notice. | Included under `Contents/Resources/Legal/ThirdPartyLicenses/tree-sitter/` during app packaging. |
| Resolved SwiftPM dependency graph | `Package.resolved`, [`ThirdPartyLicenses/swiftpm/`](../ThirdPartyLicenses/swiftpm/) | The machine-checkable inventory maps every remote resolved package to copied upstream license and notice files or to the separately curated Tree-sitter bundle. Checksums protect every copied file. | Included under `Contents/Resources/Legal/ThirdPartyLicenses/swiftpm/` during app packaging. |

The root [`LICENSE`](../LICENSE) provides the Apache License, Version 2.0 for
original RepoPrompt CE code. The root
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) records bundled
attribution material and points to copied legal files. The
[`Scripts/swiftpm_notice_guardrails.sh`](../Scripts/swiftpm_notice_guardrails.sh)
guardrail keeps the resolved SwiftPM inventory aligned with `Package.resolved`
and verifies the copied notice checksums, including the complete curated
Tree-sitter bundle.

## Public release readiness status

Completed setup through 2026-06-01:

- Registered the explicit Apple Developer App ID `com.pvncher.repoprompt.ce`.
- Created and validated the `RepoPromptCEDeveloperID` Developer ID provisioning profile for `648A27MST5.com.pvncher.repoprompt.ce`.
- Enabled App Store Connect API access, created a least-privilege `Developer` team key for notarization, and verified its credentials with a read-only `notarytool history` request.
- Created the GitHub `release` environment, stored its Developer ID PKCS#12, export password, ephemeral CI keychain password, CE provisioning profile, CE Sparkle private key, and `NOTARYTOOL_*` secrets, and set the `SIGN_IDENTITY` environment variable.
- Enabled required-reviewer protection for the `release` environment and restricted deployment branches to protected `main`.
- Added an immutable `v*` release-tag ruleset that permits new tags while preventing updates and deletion after creation.
- Enabled GitHub Release immutability for both `repoprompt/repoprompt-ce` and `repoprompt/repoprompt-ce-updates`.
- Added the fine-grained `PUBLIC_UPDATE_REPOSITORY_TOKEN` secret scoped only to `repoprompt/repoprompt-ce-updates` with repository contents read/write permission.
- Published the source repository, reran CI, and exercised the protected **Publish Release** draft and **Promote Release** flow through public publication.
- Kept the opted-in contributor cohort in the tracked `.github/APPROVED_CONTRIBUTORS` file so changes remain public and reviewable. The issue and pull-request gates read that default-branch file directly.
- Curated copied license and notice files for every remote dependency in the resolved root SwiftPM graph and added machine guardrails for inventory drift and copied-file checksums.
- Added the environment-scoped **Promote Release** workflow. It uses trusted tooling pinned to a validated `main` SHA, requires the requested tag to be reachable from protected `main`, verifies reviewed source-draft assets and ZIP/DMG contents, validates packaged legal files and the protected CE Sparkle private key, mirrors update assets into `repoprompt-ce-updates`, enforces monotonically increasing stable builds, resumes matching partial states, publishes without rebuilding, explicitly selects the latest release, and runs anonymous post-publish checks.

The previously tracked external GitHub configuration gates are complete and are
no longer public-release blockers. Continue to verify an installed app update
through the public channel for each release candidate before relying on a new
stable update.

## Contributor validation touchpoints

Docs-only or metadata-documentation changes should at minimum run:

```bash
make guardrails
```

When changes touch dependencies or provider-package code, add:

```bash
swift package resolve
cd Packages/RepoPromptAgentProviders && swift test
```

When changes touch packaging, MCP runtime, debug CLI behavior, Agent Mode runtime behavior, or a running-app feature, run the live CE MCP smoke flow documented in the root [`README.md`](../README.md) after the smallest relevant build/test command.
