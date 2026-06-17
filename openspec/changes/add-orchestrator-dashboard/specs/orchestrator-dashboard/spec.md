## ADDED Requirements

### Requirement: Dashboard surface
The system SHALL provide an opt-in Orchestrator Dashboard surface inside the existing `.main` app experience.

#### Scenario: Agent Mode remains default
- **WHEN** a user opens the app into the `.main` route
- **THEN** the system SHALL show the existing Agent Mode surface by default
- **AND** the dashboard SHALL be available only through an explicit dashboard entry point.

#### Scenario: Workspace entry remains unchanged
- **WHEN** the app is in workspace-entry routing
- **THEN** the dashboard SHALL NOT bypass existing workspace-entry gating.

#### Scenario: Forced main launch remains stable
- **WHEN** UI tests or launch configuration force `.main`
- **THEN** the system SHALL land on Agent Mode unless a dashboard-specific forced-surface option is explicitly added.

### Requirement: Dashboard snapshot projection
The system SHALL render the Orchestrator Dashboard from a single dashboard-facing `OrchestratorDashboardSnapshot` projection.

#### Scenario: Dashboard renders from one projection
- **WHEN** the dashboard renders top counts, groups, rows, pending prompts, Coordinator rail, MCP footer, and deep-link affordances
- **THEN** those UI regions SHALL derive their displayed state from the same `OrchestratorDashboardSnapshot`.

#### Scenario: Projection composes independent upstreams
- **WHEN** the snapshot is produced after `add-mcp-dashboard-consumer` is available
- **THEN** it SHALL compose active window Agent Mode session state/metadata and MCP dashboard state
- **AND** it SHALL NOT route MCP dashboard data through Agent Mode as a synthetic agent state.

#### Scenario: Snapshot avoids streaming churn
- **WHEN** assistant text, transcript tokens, or token counts stream without changing coarse dashboard state
- **THEN** the dashboard snapshot SHALL NOT republish changed rows solely because of those streaming deltas.

### Requirement: Active workspace rows and current-window live enrichment
The system SHALL scope v1 dashboard rows to the active workspace and live run-state enrichment to the current window.

#### Scenario: Dashboard opens in a workspace
- **WHEN** the dashboard opens
- **THEN** it SHALL consider sessions from the active workspace.

#### Scenario: Active workspace has no sessions
- **WHEN** the active workspace has no sessions to project
- **THEN** the dashboard SHALL show an empty state instead of empty groups or stale placeholder rows.

#### Scenario: Session live state belongs to another window
- **WHEN** a session is known from active-workspace persisted metadata but has no current-window live state
- **THEN** the dashboard SHALL render the row as stale/persisted-only in v1
- **AND** it SHALL NOT present stale persisted data as live status.

### Requirement: Coordinator selection
The system SHALL identify the dashboard Coordinator using explicit precedence.

#### Scenario: User-selected Coordinator exists
- **WHEN** the user has selected a valid Coordinator session for the active workspace in the current window
- **THEN** the dashboard SHALL use that session as Coordinator ahead of auto-detected candidates.

#### Scenario: Orchestrate workflow candidate exists
- **WHEN** no user-selected Coordinator exists and a parent session has launch or first-request workflow metadata of `Orchestrate`
- **THEN** the dashboard SHALL treat that parent session as a Coordinator candidate.

#### Scenario: MCP-originated lineage candidate exists
- **WHEN** no user-selected Coordinator or Orchestrate workflow candidate exists and a parent session is both a lineage root with child sessions and MCP-originated
- **THEN** the dashboard SHALL treat that parent session as a Coordinator candidate.

#### Scenario: Plain lineage parent exists
- **WHEN** a parent session has child sessions but is neither user-selected, Orchestrate-detected, nor MCP-originated
- **THEN** the dashboard SHALL NOT silently treat that parent as the Coordinator.

#### Scenario: No Coordinator is found
- **WHEN** no Coordinator can be selected or detected
- **THEN** the dashboard SHALL still render the grouped active-workspace inbox
- **AND** the Coordinator rail SHALL show an empty or choose-Coordinator state rather than blocking the dashboard.

#### Scenario: Multiple Coordinator candidates exist
- **WHEN** multiple auto-detected Coordinator candidates match
- **THEN** the dashboard SHALL use the most recent candidate within the highest-ranked matching precedence tier in v1
- **AND** a valid user-selected Coordinator SHALL override that automatic choice.

### Requirement: Session row projection
The system SHALL project dashboard session rows from structured session and live-state data.

#### Scenario: Session row renders
- **WHEN** a session appears in the dashboard inbox
- **THEN** the row SHALL derive identity, lineage, provider/model, worktree state, MCP origin, and run status from structured session metadata or live state.

#### Scenario: Workflow labels are deferred
- **WHEN** dashboard rows render in v1
- **THEN** the row SHALL omit workflow labels
- **AND** workflow index or transcript lookup policy SHALL remain a follow-up decision.

#### Scenario: Objective label has no source
- **WHEN** no structured objective source exists
- **THEN** the row SHALL omit objective labels.

#### Scenario: Workstream source exists
- **WHEN** bound worktree or logical-root metadata exists for a session and is useful for the UI
- **THEN** the dashboard MAY project that structural metadata as a workstream grouping label.

#### Scenario: Workstream source is absent
- **WHEN** no structured workstream source exists
- **THEN** the dashboard SHALL omit workstream chips
- **AND** it SHALL NOT parse session titles to invent workstream labels.

### Requirement: Status grouping and sorting
The system SHALL group dashboard rows by testable, structured status rules.

#### Scenario: Group precedence is evaluated
- **WHEN** a row has signals matching more than one group
- **THEN** the dashboard SHALL evaluate groups in this order: `Needs you`, `Blocked`, `Working`, `Done`, `Idle`.

#### Scenario: Session needs user attention
- **WHEN** a session has current-window live run state `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the dashboard SHALL group that row under `Needs you`
- **AND** live MCP-controlled pending interaction data MAY enrich the row prompt/details when available.

#### Scenario: Persisted-only row has active-looking stale run state
- **WHEN** a row is known only from persisted metadata and has no current-window live state
- **AND** its persisted run state is `.running`, `.waitingForUser`, `.waitingForQuestion`, or `.waitingForApproval`
- **THEN** the dashboard SHALL NOT count that row as live `Working` or `Needs you` in v1.

#### Scenario: Session is blocked
- **WHEN** a session has `.failed` run state or conflicted worktree/merge attention
- **THEN** the dashboard SHALL group that row under `Blocked`.

#### Scenario: Session is working
- **WHEN** a session has current-window live run state `.running`
- **THEN** the dashboard SHALL group that row under `Working`.

#### Scenario: Session is done
- **WHEN** a session run state is `.completed` or `.cancelled`
- **THEN** the dashboard SHALL group that row under `Done`.

#### Scenario: Session is idle
- **WHEN** a session run state is `.idle` and no higher-priority group applies
- **THEN** the dashboard SHALL group that row under `Idle`.

#### Scenario: Rows are sorted within groups
- **WHEN** rows are displayed within a status group
- **THEN** the dashboard SHALL sort them deterministically using cheap metadata such as attention age, activity date, last modified date, or completion date
- **AND** it SHALL NOT require per-row transcript loads solely to sort rows.

#### Scenario: High-priority groups are non-empty
- **WHEN** `Needs you`, `Blocked`, or `Working` groups contain rows
- **THEN** the dashboard SHALL expand those groups by default.

#### Scenario: Low-priority groups are non-empty
- **WHEN** `Done` or `Idle` groups contain rows
- **THEN** the dashboard SHALL collapse those groups by default with a `Show` affordance.

### Requirement: Pending interaction display
The system SHALL display pending interactions as read-only prompts that deep-link to Agent Mode.

#### Scenario: Pending interaction is available
- **WHEN** a live MCP-controlled session has an `AgentRunMCPSnapshot.Interaction`
- **THEN** the dashboard MAY render a pending interaction summary with kind, title, prompt, details, and optional Agent UI route
- **AND** non-MCP pending prompt/detail projection SHALL remain a follow-up Agent Mode contract change.

#### Scenario: Pending interaction has no route
- **WHEN** a pending interaction summary cannot resolve an Agent UI route
- **THEN** the dashboard SHALL hide or disable `Open agent chat` and decision navigation affordances for that summary.

#### Scenario: User needs to respond
- **WHEN** a user chooses to respond to a pending interaction from the dashboard
- **THEN** the dashboard SHALL route the user to the existing Agent Mode session
- **AND** the dashboard SHALL NOT execute approval, decline, retry, reassign, or directive actions in v1.

#### Scenario: Assistant prose mentions a decision
- **WHEN** assistant text contains words that appear to request a user decision
- **THEN** the dashboard SHALL NOT classify it as a pending interaction unless structured pending state exists.

### Requirement: Agent chat deep link
The system SHALL deep-link dashboard rows to the existing Agent Mode session when route data is resolvable.

#### Scenario: Route is resolvable
- **WHEN** a dashboard row has active workspace context, a resolvable tab, and optional session ID
- **THEN** the dashboard SHALL provide an `Open agent chat` affordance that opens the existing Agent Mode session.

#### Scenario: Route is not resolvable
- **WHEN** a dashboard row lacks required route data
- **THEN** the dashboard SHALL hide or disable `Open agent chat` for that row.

#### Scenario: Persisted-only row lacks a resolvable tab
- **WHEN** a persisted-only row has no active workspace/tab/session route
- **THEN** the dashboard SHALL show the row without `Open agent chat`
- **AND** it SHALL NOT attempt to create or restore a session as part of dashboard rendering.

### Requirement: Compact MCP awareness
The system SHALL provide compact MCP client/tool-call awareness without replacing existing MCP status surfaces.

#### Scenario: Dashboard is visible
- **WHEN** the Orchestrator Dashboard is visible
- **THEN** the system SHALL subscribe to MCP dashboard updates through the Orchestrator Dashboard consumer provided by `add-mcp-dashboard-consumer`.

#### Scenario: Dashboard is hidden
- **WHEN** the Orchestrator Dashboard is not visible
- **THEN** the system SHALL stop dashboard-specific MCP update consumption.

#### Scenario: MCP clients exist
- **WHEN** MCP clients are connected, idle, or active
- **THEN** the dashboard SHALL show compact client and in-flight/recent tool-call awareness
- **AND** it SHALL allow MCP footer totals to include server/window-scoped clients or calls not represented by the active-workspace row list.

#### Scenario: MCP is off or empty
- **WHEN** the MCP server is off or has no connected clients
- **THEN** the dashboard SHALL show a compact empty/off state rather than a full status dashboard.

### Requirement: Progressive disclosure
The system SHALL keep the dashboard calm by default and expose detail only through deliberate user action.

#### Scenario: Dashboard first renders
- **WHEN** the dashboard first renders
- **THEN** it SHALL show summarized counts, groups, rows, Coordinator context when available, and compact MCP awareness
- **AND** it SHALL NOT show full transcripts, full logs, diffs, file viewers, or continuously streaming tool feeds in the main inbox.

#### Scenario: User selects a row
- **WHEN** the user selects a dashboard row
- **THEN** the dashboard MAY show an inspection drawer with sourced status, pending interaction, blocker, worktree/merge, route, MCP, and session metadata summaries
- **AND** it SHALL NOT expose a dashboard-native full raw log, transcript, file viewer, or diff viewer in v1.

#### Scenario: User needs deep detail
- **WHEN** the user needs full transcript, raw log, detailed runtime state, file context, diff context, or action handling
- **THEN** the dashboard SHALL route the user to the existing Agent Mode surface.
