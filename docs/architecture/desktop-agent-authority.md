# Desktop Agent Mode authority boundary

**Status:** Accepted
**Date:** 2026-08-19

## Context

The Server prototype experimented with constructing a durable headless authority and SQLite store inside the macOS app. That cutover created a second owner for Desktop Agent Mode lifecycle and app-backed MCP state without a supported Desktop migration, recovery, or operational contract.

The established Desktop implementation already has complete owners for these responsibilities:

- `AgentModeViewModel` delegates run control to `AgentModeRunService`.
- The integrated Codex, Claude-compatible, ACP, and headless runners own provider launch and cancellation.
- `AgentRunTerminalCommitBarrier` settles terminal session-local lifecycle state.
- `AgentTabSession.runLifecycle` identifies the active Desktop run attempt.
- `AppGlobalMCPServiceComposition`, `MCPServerViewModel`, `ServerController`, `AgentManageMCPToolService`, and `AgentRunSessionStore` project live and persisted Desktop sessions to app-backed MCP.

The Server work is being reconstructed from current upstream in later boundary-focused changes. Prototype code is evidence, not a commit sequence or an authority over Desktop behavior.

## Decision

Desktop remains a non-durable, app-owned Agent Mode authority.

Desktop production code must not:

- construct `RepoPromptHeadlessAuthority`;
- open a Server or direct-headless SQLite authority store;
- route provider control through an authority snapshot/provider closure;
- project Server authority epochs into app-backed MCP wait identity; or
- write both Desktop session state and a Server authority store.

Provider start, steer, follow-up, interaction, permission, worktree, cancellation, and terminal settlement continue through their existing integrated Desktop owners. App-backed MCP continues resolving live Desktop sessions first and persisted Desktop sessions second. The public direct-headless MCP behavior is unchanged by this decision.

## Prototype store preservation

The removed prototype used:

```text
~/Library/Application Support/RepoPrompt CE/AgentAuthority/repoprompt.sqlite
```

If that file exists, Desktop emits one process-start diagnostic stating that the unused store was preserved. Desktop does not open, migrate, import, move, truncate, or delete the file, and does not create the directory when it is absent. There is no automatic Desktop-to-Server state adoption path.

This preserves potential recovery evidence without making an unsupported prototype store authoritative for either product.

## Contract freeze

The restoration baseline freezes:

- the canonical 27-tool MCP fixture;
- workflow raw IDs, command names, MCP/install order, built-in canonical IDs, metadata, and rendered prompt hashes;
- Desktop provider and model raw values/order plus stored-value round trips; and
- Desktop settings schema identity, defaults, and stored Agent Models raw-value round trips.

A package move or Server extraction must have zero semantic diff at these boundaries. An intentional MCP fixture change requires a human-readable compatibility diff and the repository's designated Desktop/MCP approvals.

## Consequences

- Desktop preserves the established integrated runner and app-backed MCP behavior.
- Existing Desktop workspace, compose-tab, selection, prompt, provider/model, and settings state is not migrated.
- The prototype SQLite file may remain orphaned on disk by design.
- Later Server work must establish its own compile-isolated host, namespace ownership, persistence, recovery, and operational contracts without importing those choices into Desktop.
- A future Desktop durability proposal requires a separate migration and product decision; it is not an incidental consequence of Server extraction.

## Validation boundary

The owning validation is the smallest coordinated Desktop/MCP batch covering:

- Desktop app and public MCP product builds;
- representative integrated-runner lifecycle and terminal-barrier behavior;
- app-backed MCP registration/wait identity;
- prototype-store non-creation and sentinel immutability;
- canonical MCP fixture parity; and
- workflow, provider/model, and settings snapshots.

Visible app launch or shutdown is not required for this boundary.
