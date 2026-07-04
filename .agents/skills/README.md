# Vendored Apple Xcode Agent Skills

`swiftui-specialist/` is an Apple-authored Agent Skill bundle, vendored
verbatim from Xcode's skill export for use by agents contributing to this
repository. The `agents/openai.yaml` file inside it is repo-added metadata
(explicit-invocation policy), not part of Apple's export.

- Source: Xcode 27.0 beta 2 (build 27A5209h)
- Export command: `xcrun agent skills export` (resolves to
  `xcrun mcpbridge run-agent skills export`)
- Exported: 2026-07-04
- Skill content is unmodified from the export.

## Deliberately deferred skills

Apple's export also ships `swiftui-whats-new-27`, which teaches SDK 27-only
SwiftUI APIs. It is deliberately not vendored while the repository toolchain
builds with Xcode 26.x, to avoid steering agents toward APIs that do not
compile here. Add it back (procedure below) when the repo moves to
Xcode/SDK 27. The remaining exported skills (uikit-app-modernization,
modernize-tests, device-interaction, audit-xcode-security-settings,
c-bounds-safety) were evaluated and excluded as not applicable to this
codebase; see the vendoring PR for rationale.

## License boundary

The Apple-authored skill content in `swiftui-specialist/` is NOT covered by
this repository's Apache-2.0 license. Apple ships these bundles in Xcode
and provides the export command for agent use, but has published no explicit
redistribution license for them. It is vendored here for contributor
convenience with maintainer acceptance; all rights to the content remain with
Apple. If Apple publishes license terms for these bundles, update this notice.

## Re-exporting on a new Xcode release

1. Install the new Xcode, accept its license, and complete first-launch
   (`xcodebuild -runFirstLaunch`).
2. `DEVELOPER_DIR=/Applications/<Xcode>.app/Contents/Developer xcrun agent skills export --output-dir /tmp/xcode-skills --replace-existing`
3. Replace the vendored directories wholesale; update the build number and
   date above.
4. Review the diff for renames and guidance changes (example: beta 1's
   `test-modernizer` shipped as `modernize-tests` in beta 2).

All other directories here (`rpce-*`) are RepoPrompt CE's own contributor
skills and are covered by the repository license.
