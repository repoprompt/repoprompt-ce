## Why

Users can already run multiple isolated Agent Mode sessions, often across worktrees, but supervising them requires jumping between session rows, transcripts, MCP status, and notifications. RepoPrompt needs a calm mission-control surface that helps users see what needs attention, inspect progress, and jump into the existing Agent UI without replacing it.

## What Changes

- Add a new opt-in Orchestrator Dashboard surface inside the existing `.main` app experience.
- Render the dashboard from a single `OrchestratorDashboardSnapshot` projection composed from the active window's Agent Mode state and `MCPServerViewModel.dashboard`, consuming the MCP dashboard consumer added by `add-mcp-dashboard-consumer`.
- Scope v1 to active-workspace rows with current-window live-state enrichment and keep Agent Mode as the default surface.
- Show a Coordinator rail when a Coordinator can be selected or detected, plus a grouped agent inbox, inspection drawer, compact MCP footer/popover, and deep links back to Agent Mode.
- Surface structured waiting/user-attention states read-only, enrich live MCP-controlled sessions with normalized interaction details when available, and deep-link users to Agent Mode for response.
- Avoid heuristic labels and runtime rewrites: workflow is optional, objective is deferred, and workstream chips render only from structured data such as worktree binding metadata.

## Capabilities

### New Capabilities
- `orchestrator-dashboard`: Provides a read-only, active-workspace dashboard for supervising active-workspace agent sessions through a single dashboard projection, grouped inbox, optional Coordinator rail, MCP awareness, and Agent UI deep links.

### Modified Capabilities

None.

## Impact

- App shell: introduces in-`.main` surface selection while preserving existing `.main` / `.workspaceEntry` root gating and Agent Mode default behavior.
- Agent Mode: reads existing session metadata, live window state, pending interaction projection, worktree binding summaries, and deep-link routing without replacing Agent UI.
- MCP: depends on `add-mcp-dashboard-consumer` for the dashboard consumer identity, then projects existing MCP dashboard state rather than embedding the full MCP status surface.
- Tests: requires snapshot, grouping, Coordinator selection, MCP projection, deep-link, and surface-selection coverage.
