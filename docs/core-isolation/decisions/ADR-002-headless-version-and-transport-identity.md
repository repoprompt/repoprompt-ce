# ADR-002: Headless version and transport identity

- **Status:** Accepted
- **Date:** 2026-06-21
- **Decision owners:** Headless and release owners
- **Reviewed reference:** `21b5603f5a333454aee899dd39ff38d860a5b716`

## Context

The reviewed reference hard-coded marketing version `1.0.10` and build `11`.
Those values describe the historical feature snapshot, not the current release base
(`v1.0.21`). Replaying them would create a stale packaged identity. Transport,
filesystem, executable, and secret identities are nevertheless intentional and
must not collapse into the app proxy. The reviewed snapshot also used the
unversioned state root `~/Library/Application Support/RepoPrompt CE/Headless`;
the execution plan requires a distinct versioned root, so this ADR deliberately
supersedes that historical path.

## Decision

Freeze these stable identities:

- Swift product/target/binary: `repoprompt-headless` /
  `RepoPromptHeadless` / `repoprompt-headless`;
- server display name: `RepoPrompt Headless`;
- MCP protocol version: `2024-11-05` until a separately reviewed protocol
  upgrade;
- release command: `rpce-headless`;
- debug command: `rpce-headless-debug`;
- state root: `~/Library/Application Support/RepoPrompt CE/Headless/v1`;
- staged tools root: `~/Library/Application Support/RepoPrompt CE/HeadlessTools`;
- secure-storage service namespace:
  `com.pvncher.repoprompt.ce.headless.keychain`;
- direct NDJSON stdio only; no app bootstrap socket, bundle helper, window
  routing, or `repoprompt-mcp` fallback.

The headless marketing version and build number must be generated from the current
release metadata by the Phase 8 packaging path. They must not be copied from the
historical snapshot and must match the packaged artifact's provenance. Tests may
use injected values but cannot freeze `1.0.10 (build 11)` as the reconstructed
product version. A state-directory override names the complete version-specific
root; implementations must not silently append or remove `v1`.

## Consequences

Phase 8 must add one provenance/version oracle covering binary `--version`,
`initialize.serverInfo.version`, package manifest metadata, and staged artifact
identity. The historical version values remain archaeology only. Every other
wire/state/security value is frozen in
[headless-v1.md](../contracts/headless-v1.md).
