## Context

RepoPrompt CE already has the raw data needed for a dashboard, but the data is split across Agent Mode and MCP status surfaces:

- `AgentSession` persists session identity, provider/model metadata, `parentSessionID`, MCP origin, run state, worktree bindings, and active merge summaries.
- `AgentModeSidebarSessionBuilder` already demonstrates lineage-aware session grouping, status vocabulary, attention state, and calm row presentation.
- `AgentRunMCPSnapshot.Interaction` provides the existing MCP-facing normalized pending interaction shape for live MCP-controlled sessions.
- `MCPServerViewModel.dashboard` exposes MCP connection/tool-call state through an existing dashboard subscription lifecycle; the `add-mcp-dashboard-consumer` prerequisite adds the named Orchestrator Dashboard consumer for this lifecycle.
- `AgentSessionDeepLinkRoute` and `WindowState.routeToAgentSession` already provide the basis for opening existing Agent Mode sessions.

The dashboard should therefore be a read-only projection over existing state, not a new runtime, protocol, or Agent UI replacement.

## Goals / Non-Goals

**Goals:**

- Add an opt-in Orchestrator Dashboard surface inside `.main` while preserving Agent Mode as the default.
- Render all dashboard regions from one `OrchestratorDashboardSnapshot` projection.
- Compose that projection from two independent upstream categories: Agent Mode state, including current-window live state plus active-workspace session metadata; and `MCPServerViewModel.dashboard`.
- Scope v1 to active-workspace rows with current-window live-state enrichment.
- Show Coordinator context when selected or detected, keep the inbox useful without a Coordinator, group session rows by total run-state-aware rules, render read-only pending interaction prompts, compact MCP awareness, and deep links to Agent Mode.
- Use coarse observation and diff-before-publish behavior so streaming transcript/token deltas do not churn the dashboard.

**Non-Goals:**

- Replacing Agent Mode as the canonical deep-work surface.
- Rendering full transcripts, file viewers, diffs, or full logs in the dashboard v1.
- Adding dashboard-side approval/decline/retry/steering actions.
- Inventing a universal `PendingDecision` protocol.
- Parsing assistant prose or session titles to infer meaning.
- Cross-workspace or cross-window aggregation.
- Objective labels, title-derived workstream chips, PR/check metadata, external MCP error triage, or detailed active-scope visualization in v1.

## Decisions

### 1. Dashboard surface lives inside `.main`

`ContentViewModel.AppRootRoute` remains the binary workspace-entry gate (`.workspaceEntry` vs `.main`). The dashboard needs new window-scoped main-surface selection inside `.main`, and `ContentRootShellView.routedContent` should switch between existing Agent Mode and the dashboard within the `.main` branch. Once a real workspace is active, the user reaches the dashboard through a persistent peer surface switcher for Agent Mode ↔ Orchestrator Dashboard; the switcher does not appear in or bypass workspace-entry/onboarding.

Alternatives considered:

- **New `AppRootRoute` peer:** rejected because it would bypass existing workspace-entry gating and disturb current default behavior.
- **MCP status sheet expansion:** rejected because the dashboard supervises Agent sessions and uses MCP as one input, not the other way around.

### 2. Agent Mode remains default

The default `.main` surface remains Agent Mode in v1. Treat this as the configured landing surface, not a permanent hard-coded product truth, so a future control-plane release can choose the dashboard as the landing surface without replacing the routing seam. `AppLaunchConfiguration.forcedRootRoute == .main` should continue to land on Agent Mode unless a future forced-surface test knob is added. User surface selection is sticky per window while the window is alive; Coordinator selection remains keyed by active workspace.

### 3. One render projection, two upstreams

This change depends on `add-mcp-dashboard-consumer` for the named MCP dashboard consumer identity. The dashboard SHALL render from `OrchestratorDashboardSnapshot`. That snapshot is one UI consistency boundary, but it is composed from independent upstreams:

1. current-window Agent Mode live state overlaid on active-workspace session metadata;
2. `MCPServerViewModel.dashboard` with its existing dashboard consumer lifecycle.

This avoids each UI component re-deriving counts, groups, pending decisions, and deep links from different sources while preserving the existing MCP data path.

### 4. Snapshot owner is reactive but coarse

A lazily-created `@MainActor` dashboard view model should observe coarse signals only: run-state transitions, pending-interaction presence, lineage/session metadata changes, worktree/merge attention, and MCP dashboard changes. It should not republish on streaming assistant deltas, token deltas, or raw transcript churn. Existing sidebar/content-fingerprint patterns are the precedent.

### 5. Coordinator identity uses precedence

Coordinator identity is not a flat set of OR predicates. Selection precedence is:

1. user-selected Coordinator session, if present and valid;
2. auto-detected parent whose launch/first request workflow is `Orchestrate`;
3. auto-detected parent that is both a lineage root with children and `isMCPOriginated == true`;
4. no Coordinator selected/found.

Plain lineage-root-with-children is never enough to auto-detect a Coordinator. User-selected Coordinator state lives in the window-scoped dashboard view model, keyed by active workspace ID, and does not persist across app launches in v1.

### 6. Active workspace rows, current-window live enrichment

V1 projects active-workspace sessions. Live run-state enrichment is current-window scoped. Sessions without current-window live state render from persisted metadata only and are marked stale/persisted-only. Persisted-only rows never count toward live `Needs you` or `Working` groups in v1. Rows without a resolvable route hide or disable Agent UI navigation.

### 7. Labels are structured and conservative

Workflow labels are omitted in v1. A future workflow label pass can choose between an index addition and shared request-anchor/transcript metadata lookup; that same lookup should be shared with workflow-based Coordinator detection if enabled. With no session-level workflow source in v1, the Orchestrate workflow auto-detection tier is inert; effective automatic Coordinator detection reduces to MCP-originated lineage-root candidates unless the deferred workflow lookup lands. Objective labels are deferred. Workstream chips may optionally render from worktree binding/logical-root metadata when present and useful for the UI; otherwise omit them. Session-title parsing is out of scope.

### 8. Pending interactions are read-only and MCP-scoped in v1

V1 `Needs you` grouping is driven primarily by structured run state: `.waitingForUser`, `.waitingForQuestion`, and `.waitingForApproval`. The pending-scope decision for v1 is MCP-only prompt/detail enrichment: live MCP-controlled sessions may additionally provide normalized `AgentRunMCPSnapshot.Interaction` content, but MCP interaction presence is not the only attention gate. A broader non-MCP pending projection is a follow-up Agent Mode contract change, not part of this dashboard core. Dashboard pending summaries carry render data plus an optional route, not executable actions:

```swift
struct DashboardPendingInteractionSummary {
    let id: UUID
    let kind: AgentRunMCPSnapshot.Interaction.Kind
    let title: String?
    let prompt: String?
    let details: [AgentRunMCPSnapshot.Interaction.Detail]
    let openAgentChatRoute: AgentSessionDeepLinkRoute?
}
```

If `openAgentChatRoute` is nil, the dashboard hides or disables `Open agent chat` / `Decide`. Dashboard-side responses and Coordinator directive transport are follow-ups.

### 9. Deep links use existing Agent UI routing

When route data is resolvable, dashboard rows and pending summaries use `AgentSessionDeepLinkRoute` or direct same-window `WindowState.routeToAgentSession`. A route requires active workspace context, a resolvable tab, and an optional session ID when available. `AgentSessionMeta` is not a self-contained route payload because it does not carry `workspaceID`; v1 route construction uses the active workspace context for `workspaceID` and metadata for tab/session identifiers when present.

### 10. MCP awareness is compact

Consume the `MCPServerViewModel.DashboardConsumer.orchestratorDashboard` case added by `add-mcp-dashboard-consumer`. The dashboard subscribes while visible and shows compact connected/idle/off client count, recent tool calls, and active/in-flight call count. Agent rows are active-workspace scoped, but the MCP footer is server/window scoped; it may include clients or calls not tied to the visible row list. External error triage, detailed attribution, and active-scope visualization are follow-ups.

### 11. Status grouping is total and precedence-based

Status groups are evaluated top-down: `Needs you` > `Blocked` > `Working` > `Done` > `Idle`.

- `Needs you`: current-window live run state is `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`; MCP pending interaction data enriches prompt/details when available.
- `Blocked`: run state is `.failed` or cheap metadata reports conflicted worktree/merge attention.
- `Working`: current-window live run state is `.running`.
- `Done`: run state is `.completed` or `.cancelled`.
- `Idle`: run state is `.idle` or no higher-priority group applies.

Blocked's conflicted-merge signal should come from cheap metadata such as active worktree merge summaries. Within-group sorting should also use cheap metadata, e.g. attention age or activity/last-modified dates, not transcript loads. Persisted-only rows may still appear as `Blocked`, `Done`, or `Idle` from persisted metadata, but they must not contribute to live `Needs you` or `Working` counts.

### 12. Coordinator rail is optional; inbox stands alone

The v1 dashboard is inbox-centric. If no Coordinator is selected or detected, the dashboard still renders the grouped active-workspace inbox and shows an empty/choose-Coordinator state in the rail area. If multiple auto-detected Coordinator candidates exist, v1 picks the most recent candidate within the highest-ranked matching precedence tier until the user selects a different per-window, workspace-keyed Coordinator.

### 13. Drawer stays sourced; full logs stay in Agent Mode

The v1 drawer shows sourced summaries only: status, pending interaction, blocker, worktree/merge, route, and MCP/session metadata. Full transcript, raw log, file, and diff inspection remain in Agent Mode via `Open agent chat`. A dashboard-native full-log toggle is a follow-up unless backed by a sourced activity projection.

## Risks / Trade-offs

- **Coordinator ambiguity** → Use precedence rules, most-recent auto-candidate fallback, and per-window user override instead of guessing from plain lineage.
- **Multi-window stale rows** → Render stale/persisted-only state explicitly; keep live `Needs you` / `Working` counts current-window-only.
- **Reactive firehose** → Observe coarse signals and diff snapshots before publishing.
- **Workflow lookup cost** → Either add workflow to metadata/index or accept a shared transcript metadata read; do not repeatedly load transcripts per UI region.
- **Pending decision asymmetry** → Run-state waiting values still enter `Needs you`; MCP-controlled live interactions only enrich the prompt/detail payload.
- **Route gaps** → Store nullable routes on rows/summaries and hide navigation when route prerequisites are missing.

## Migration Plan

1. Add dashboard artifacts behind an opt-in in-`.main` surface while Agent Mode remains default.
2. Build read-only snapshot projection and tests before UI action wiring.
3. Add UI shell and deep links after snapshot behavior is stable.
4. Consume the MCP dashboard consumer added by `add-mcp-dashboard-consumer` after compact projection tests are in place.
5. Defer dashboard-side actions, Coordinator directive transport, objective labels, and cross-window/cross-workspace aggregation.

Rollback is simple for v1: remove or hide the dashboard entry point; Agent Mode remains the default and canonical surface.

## Open Questions

- Should a future workflow label pass add workflow metadata to the session index, or load request-anchor/transcript metadata on demand?
- Should a future dashboard support cross-window live ownership or route-to-owning-window behavior instead of stale/persisted-only rows?
- Should PR/check metadata wait until a separate activity/event adapter exists?
