## 1. Main surface and entry point

- [ ] 1.1 Add window-scoped main-surface selection state inside `.main`.
- [ ] 1.2 Preserve Agent Mode as the default `.main` surface.
- [ ] 1.3 Add an opt-in entry point for the Orchestrator Dashboard.
- [ ] 1.4 Preserve `AppLaunchConfiguration.forcedRootRoute == .main` behavior so deterministic UI tests still land on Agent Mode unless a forced-surface knob is added.

## 2. Dashboard snapshot projection

- [ ] 2.1 Define `OrchestratorDashboardSnapshot` as the single render contract for counts, groups, rows, Coordinator rail, pending summaries, MCP footer, and deep-link payloads.
- [ ] 2.2 Implement a lazy, window-scoped `@MainActor` dashboard view model.
- [ ] 2.3 Compose the snapshot from current-window Agent Mode live state, active-workspace session metadata, and `MCPServerViewModel.dashboard`, assuming `add-mcp-dashboard-consumer` has provided the named dashboard consumer.
- [ ] 2.4 Add diff-before-publish/fingerprint behavior so streaming transcript or token deltas do not republish unchanged dashboard rows.
- [ ] 2.5 Represent stale/persisted-only rows for active-workspace sessions without current-window live state.

## 3. Coordinator identity

- [ ] 3.1 Implement user-selected Coordinator state as per-window ephemeral state keyed by active workspace ID.
- [ ] 3.2 Implement Orchestrate workflow candidate detection only when launch/first-request workflow metadata is already available without per-row transcript churn.
- [ ] 3.3 Implement MCP-originated lineage-root-with-children candidate detection.
- [ ] 3.4 Implement zero-candidate inbox-only behavior with empty/choose-Coordinator rail state.
- [ ] 3.5 Implement multiple-candidate behavior by selecting the most recent candidate within the highest-ranked matching precedence tier unless a user-selected Coordinator exists.
- [ ] 3.6 Add tests for Coordinator identity precedence and ambiguity handling.

## 4. Session row projection

- [ ] 4.1 Project session identity, lineage, provider/model, run state, MCP origin, worktree bindings, and merge attention from structured metadata/live state.
- [ ] 4.2 Omit workflow labels in v1; leave workflow index/transcript lookup as follow-up unless needed for Coordinator detection without churn.
- [ ] 4.3 Omit objective labels in v1.
- [ ] 4.4 Optionally project workstream labels/chips from worktree/logical-root metadata when available and useful for the UI.
- [ ] 4.5 Ensure session titles or assistant prose are not parsed to infer labels.

## 5. Status grouping and sorting

- [ ] 5.1 Implement dashboard status groups: Needs you, Blocked, Working, Done, Idle.
- [ ] 5.2 Evaluate groups top-down: Needs you, Blocked, Working, Done, Idle.
- [ ] 5.3 Map Needs you from current-window live `.waitingForUser`, `.waitingForQuestion`, and `.waitingForApproval`; use MCP pending interactions only as prompt/detail enrichment.
- [ ] 5.4 Ensure persisted-only rows never contribute to live `Needs you` or `Working` counts in v1.
- [ ] 5.5 Map Blocked from `.failed` run state or conflicted worktree/merge attention.
- [ ] 5.6 Map Working from current-window live `.running`, Done from `.completed`/`.cancelled`, and Idle from `.idle` when no higher-priority group applies.
- [ ] 5.7 Implement deterministic within-group sorting from cheap metadata such as attention age, activity date, last modified date, or completion date.
- [ ] 5.8 Add snapshot adapter tests for grouping, counts, stale-row count exclusion, and sorting.

## 6. Pending interaction summaries

- [ ] 6.1 Define dashboard pending summaries with `AgentRunMCPSnapshot.Interaction.Kind`, `AgentRunMCPSnapshot.Interaction.Detail`, and nullable `AgentSessionDeepLinkRoute`.
- [ ] 6.2 Project prompt/detail summaries from live MCP-controlled `AgentRunMCPSnapshot.Interaction` values; leave broader non-MCP pending projection as a follow-up Agent Mode contract change.
- [ ] 6.3 Hide or disable decision navigation when `openAgentChatRoute` cannot be resolved.
- [ ] 6.4 Route users to Agent Mode for responses instead of executing dashboard-side actions.
- [ ] 6.5 Add tests for pending interaction rendering, missing routes, and non-prose inference.

## 7. Deep-link behavior

- [ ] 7.1 Build row and pending-summary route payloads from active workspace, resolvable tab, and optional session ID.
- [ ] 7.2 Use direct `WindowState.routeToAgentSession` for same-window navigation when possible.
- [ ] 7.3 Use existing `AgentSessionDeepLinkRoute` / router behavior for cross-window or URL-style navigation as needed.
- [ ] 7.4 Ensure persisted-only rows without route data do not create or restore sessions during rendering.
- [ ] 7.5 Add tests for resolvable, unresolvable, and persisted-only no-restore route states.

## 8. MCP compact projection

- [ ] 8.1 Consume the Orchestrator Dashboard MCP consumer provided by `add-mcp-dashboard-consumer`.
- [ ] 8.2 Subscribe to MCP dashboard updates while the dashboard is visible and unsubscribe when hidden.
- [ ] 8.3 Project connected/idle/off client count, recent tool calls, and active/in-flight count as server/window-scoped MCP awareness that may not map one-to-one to visible rows.
- [ ] 8.4 Add tests for MCP compact projection and MCP-off/empty states without retesting the shared consumer lifecycle owned by `add-mcp-dashboard-consumer`.

## 9. Dashboard UI shell

- [ ] 9.1 Build the Orchestrator Dashboard shell with top counts, optional Coordinator rail, grouped inbox, optional inspection drawer, MCP footer, and filter affordance.
- [ ] 9.2 Keep the main inbox calm by default: no full transcripts, full logs, diffs, file viewers, or streaming tool feeds.
- [ ] 9.3 Add progressive disclosure from count to row, optional sourced drawer summaries, and Agent Mode; keep full raw logs, transcripts, files, and diffs in Agent Mode for v1.
- [ ] 9.4 Add UI previews or smoke states for empty workspace, active, needs-user, blocked, MCP-off, MCP-empty, MCP-active, filtered, zero-Coordinator inbox-only, and multiple-Coordinator most-recent states.

## 10. Validation

- [ ] 10.1 Run the focused unit tests added for snapshot projection, Coordinator identity, pending interactions, MCP projection, and deep links.
- [ ] 10.2 Run the smallest relevant coordinated Swift validation lane for touched app/UI files.
- [ ] 10.3 Run `openspec validate add-orchestrator-dashboard`.
