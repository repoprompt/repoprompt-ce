---
name: rpce-release
description: Build or publish RepoPrompt CE release artifacts using the repository release scripts and GitHub workflows.
---

# RepoPrompt CE Release

Use this skill when preparing a RepoPrompt CE release artifact or orienting a
maintainer through a production release.

## Contributor artifact

Run the secret-free lane:

```bash
make dev-release-preflight
make dev-release-artifact
```

For a local-only release-mode installation signed by the user's own dedicated
self-signed identity, install Python 3 and double-click
[`Install RepoPrompt CE Local Production.command`](../../../Install%20RepoPrompt%20CE%20Local%20Production.command)
in Finder, or use the coordinated CLI path:

```bash
CONFIRM_LOCAL_PRODUCTION_INSTALL=1 make dev-install-local-production
```

This app is not notarized and must not be distributed or uploaded to GitHub
Releases.

Report the files written under `dist/`. Clearly state that the archive is
ad-hoc signed, intended for packaging validation, and not distributable.

## Maintainer publish

Read [`docs/releasing.md`](../../../docs/releasing.md) before publishing.

Use the environment-scoped GitHub **Publish Release** workflow for production
draft creation. It requires an existing pushed tag and the `release`
environment secrets documented there. Review and test the resulting reviewed
draft assets, then use the environment-scoped **Promote Release** workflow for the same
tag. Promotion verifies and mirrors the existing reviewed assets, publishes
both releases without rebuilding, resumes matching partial states, enforces a
monotonically increasing stable build, and runs anonymous post-publish checks.
Dispatch both workflows from protected `main` only after the `release`
environment reviewer gate, `main` deployment restriction, and immutable `v*`
tag ruleset are enabled, and GitHub Release immutability is enabled for both
the source and updater repositories. Supply the SHA-256 digest of the reviewed
source-draft `SHA256SUMS` file when dispatching promotion. Do not paste private keys,
profiles, certificate exports, tokens, or passwords into logs or chat.

RepoPrompt CE starts its independent release history at `1.0.0 (1)`.
Increment `BUILD_NUMBER` monotonically for every later public update.
After changing `version.env`, run `make release-sync-cli-version` and commit the
synchronized MCP CLI version before creating the release tag.

For an explicit private-source updater smoke test, use the maintainer-only
`Scripts/publish_public_update_test.sh` helper documented in
[`docs/releasing.md`](../../../docs/releasing.md). It publishes only verified
Developer ID signed, notarized ZIPs to the public artifact-only update
repository.

Before a tag, commit, or push, run the repository-local
`$rpce-contribution-check` skill and follow its approval requirements.
