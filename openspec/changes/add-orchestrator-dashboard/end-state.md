# Orchestrator End State: Control Plane Plan

Status: planning
Scope owner: Erauner team
Related changes: `add-mcp-dashboard-consumer`, `add-orchestrator-dashboard`

## Goal

Define the full Orchestrator system beyond the read-only dashboard v1 so the first slice is built with seams that can support later supervision, action, and Coordinator-directive flows.

The end state is not just a dashboard. It is a control plane for a fleet of Agent Mode sessions, with Agent Mode remaining the canonical deep-work surface and the Orchestrator surface supervising, routing, and eventually directing work.

## North Star

The Orchestrator surface should let a user:

- see active and historical agent sessions in the active workspace;
- understand what needs attention, what is blocked, what is working, and what is done;
- inspect sourced activity/provenance without parsing assistant prose for meaning;
- resolve structured pending interactions from the control plane when safe;
- converse with an addressable Coordinator agent that can spawn or steer child agents;
- jump into Agent Mode whenever detailed transcript, files, diffs, or provider-specific controls are needed.

This is a control plane over Agent Mode, not a replacement for Agent Mode.

## Four Capability Layers

### Layer 1 — Observation

The read-only projection already covered by `add-mcp-dashboard-consumer` and `add-orchestrator-dashboard`.

User capability:

- View grouped sessions.
- See live attention/working state for current-window sessions.
- See stale/persisted-only rows without false live urgency.
- See compact MCP state.
- Deep-link into Agent Mode for action.

Primary contract:

- `OrchestratorDashboardSnapshot` as the single dashboard render projection, composed from active-window Agent Mode state, active-workspace session metadata, and `MCPServerViewModel.dashboard`.

### Layer 2 — Action in place

The first write path.

User capability:

- Approve, decline, retry, respond, or otherwise resolve structured pending interactions directly from the Orchestrator surface when the target session is reachable and the action can be safely normalized.

Why it is separate from Layer 1:

- Layer 1 reads and routes. Layer 2 writes into live Agent Mode interaction state.
- Existing response methods are window/session-local and not universally exposed as a dashboard-facing API.
- Cross-window action routing is unresolved: a session may appear in the dashboard as persisted/stale while its live interaction belongs to another window.

Primary future change:

```text
add-dashboard-actions
```

Depends on:

- Layer 1 snapshot and row identity.
- A resolved cross-window policy.
- A dashboard-facing pending-action contract over Agent Mode interaction state.

### Layer 3 — Conversational Coordinator

The control-plane signature interaction.

User capability:

- Read a user↔Coordinator thread in the Orchestrator surface.
- Send directives such as “investigate the failing checks,” “split this into two workstreams,” or “stop the stale child and summarize.”
- Let the Coordinator spawn, steer, or summarize child agents according to explicit runtime rules.

Why it is separate from Layer 2:

- Layer 2 responds to existing pending interactions.
- Layer 3 originates new intent and routes it to an addressable Coordinator agent.
- This requires a durable Coordinator identity, directive transport, and agent/runtime behavior that knows how to handle directives.

Primary future change:

```text
add-coordinator-directives
```

Depends on:

- Layer 1 Coordinator identity and row/session identity.
- Layer 2 write-path primitives or an equivalent directive transport.
- A product decision on whether directives can target only current-window Coordinators or can route to an owning window/session service.

### Layer 4 — Activity and provenance

The missing data subsystem behind the rich mock affordances.

User capability:

- See workflow chips, PR/check links, tool-call rollups, attached artifacts, and sourced activity history.
- Inspect “what happened” without loading full transcripts or parsing prose.

Why it is separate from Layer 1:

- Layer 1 reads current state and cheap summaries.
- Activity/provenance needs an event stream or indexed record of transitions, tool calls, workflow launch metadata, PR/check associations, artifact refs, and possibly ownership changes.

Primary future change:

```text
add-agent-activity-stream
```

Depends on:

- Agreement on event identity, retention, and source-of-truth boundaries.
- A clear separation between sourced activity records and derived UI labels.

## Dependency Spine

```text
Layer 1: Observation
   │
   ├──► Layer 4a: Activity/Event adapter
   │       └─► unlocks workflow chips, PR/check chips, drawer activity, tool-call rollup
   │
   ├──► Layer 2: Action in place
   │       └─► unlocks Approve/Decline/Retry/Respond from dashboard
   │
   └──► Layer 3: Conversational Coordinator
           └─► depends on action/write-path or equivalent directive transport
```

The two keystones are:

1. **Activity/Event adapter** — unlocks most rich visual/provenance affordances.
2. **Dashboard write path** — unlocks inline actions and is the prerequisite discipline for Coordinator directives.

Do not build the conversational Coordinator before the dashboard has a deliberate write-path story. Otherwise a “directive box” becomes an ad hoc runtime channel.

## Future OpenSpec Changes

### `add-agent-activity-stream`

Scope:

- Define a per-session activity/provenance stream or index.
- Include workflow launch metadata, run transitions, tool calls, artifact refs, PR/check associations, and durable source pointers.
- Make activity cheap enough for dashboard summaries without transcript loads.

Unlocks:

- Workflow chips.
- PR/check chips.
- Full-log or activity drawer.
- Tool-call rollups.
- More precise “what changed” explanations.

Non-goals:

- General observability platform.
- Raw provider log replacement.
- Prose parsing for semantic state.

### `add-dashboard-actions`

Scope:

- Define a dashboard-facing action contract for resolving structured pending interactions.
- Normalize supported actions without embedding Agent Mode UI internals in the dashboard.
- Decide how unsupported/unreachable actions degrade to deep-link-only behavior.

Unlocks:

- Approve / decline / cancel.
- Respond to question/user input.
- Retry or resume when backed by structured state.

Required decisions:

- Current-window-only actions vs route-to-owning-window actions.
- Whether action targets are represented by session ID + interaction ID, or by an owning-window/session handle.
- How action failure is surfaced when the target session changes before the response lands.

### `add-coordinator-directives`

Scope:

- Define an addressable Coordinator model and directive transport.
- Define how the Orchestrator surface sends a user directive to the Coordinator session.
- Define what the Coordinator runtime is allowed to do with directives: spawn, steer, cancel, summarize, or request clarification.

Unlocks:

- User↔Coordinator transcript in the dashboard.
- “Direct the Coordinator…” input.
- Coordinator-managed workstream steering.

Required decisions:

- Is the Coordinator an ordinary Agent Mode session with additional metadata, or a distinct orchestration runtime role?
- Are directives just user messages, structured commands, or a new control-plane envelope?
- Does the dashboard act only on current-window Coordinator sessions, or can it route directives cross-window?

## Cross-Window Decision

This is the hardest end-state fork.

V1 deliberately avoids it:

- Active-workspace rows may render from persisted metadata.
- Live state enrichment is current-window scoped.
- Persisted-only rows do not contribute to live `Needs you` / `Working` counts.
- Actions deep-link to Agent Mode.

Later layers cannot avoid it.

### Option A — Current-window control plane

The dashboard can observe active-workspace metadata, but it can only act on sessions live in the current window. Other-window sessions remain stale/read-only and route the user to the owning context when possible.

Pros:

- Fits current architecture.
- Keeps writes local to the `AgentModeViewModel` that owns the session.
- Avoids shared mutable session-control services.

Cons:

- Cross-window fleet control remains partial.
- Inline actions may disappear or degrade for sessions visible in the inbox.
- Conversational Coordinator is only fully useful when the Coordinator lives in the current window.

### Option B — Route actions to owning windows

The dashboard can send actions/directives to the window that owns the live session.

Pros:

- Preserves multi-window UX while enabling central control.
- Avoids making one dashboard window restore or steal sessions just to act.

Cons:

- Requires reliable live ownership tracking.
- Requires cross-window action delivery, failure handling, and user feedback.
- Requires stricter identity and lifetime semantics for pending interactions.

### Option C — Shared session-control service

Agent session control moves behind a shared service so any window can act on any live or restorable session.

Pros:

- Strongest fleet-control model.
- Natural home for Coordinator directives and activity stream.

Cons:

- Largest architectural change.
- Risks turning the dashboard effort into an Agent Mode runtime rewrite.
- Needs migration away from window-local assumptions.

Recommended stance for now:

- Keep v1 current-window write-free.
- Plan Layer 2 against Option A first, while preserving row/window identity so Option B remains possible.
- Do not pursue Option C without a separate architecture review.

## V1 Forward-Compatibility Hooks

These are cheap to preserve now and expensive to retrofit later.

### Stable row identity

Every dashboard row should retain:

- session ID when available;
- tab ID when available;
- active workspace ID from context;
- optional window/ownership identity if known;
- stale/live classification.

Why:

- Layer 2 needs stable action targets.
- Layer 3 needs an addressable Coordinator target.
- Layer 4 needs to attach activity/provenance to the same identity.

### Stable pending interaction identity

`DashboardPendingInteractionSummary` should keep the underlying `AgentRunMCPSnapshot.Interaction.id` even though v1 only renders/deep-links.

Why:

- Layer 2 needs to target the exact pending interaction.
- Without a stable interaction ID, inline responses risk racing against changed state.

### Nullable route payloads remain explicit

Rows and pending summaries should continue to carry optional route payloads rather than deriving navigation late in leaf views.

Why:

- Route availability is product state, not just button wiring.
- Layer 2 needs the same “can act here?” distinction.

### Live-state source remains explicit

The snapshot owner should record whether a row was enriched from current-window live `TabSession` state or from persisted metadata only.

Why:

- Prevents false live `Needs you` / `Working` counts.
- Gives Layer 2 a clean guard for current-window-only actions.

### Activity-stream placeholder

Do not invent workflow/PR/tool-call chips from titles or prose. If v1 has no activity source, omit the chips and leave an explicit extension point in the projection for future sourced activity.

Why:

- Layer 4 should add a real source, not retrofit around heuristic labels.

### Coordinator identity remains explicit

Do not silently treat every parent-with-children as a Coordinator. Preserve the v1 precedence and keep user-selected Coordinator identity separate from auto-detected candidates.

Why:

- Layer 3 directives require an addressable Coordinator, not a generic thread parent.

## What Stays Out Even in the End State

- Not a replacement for Agent Mode as the deep-work transcript/files/diff surface.
- Not a general observability/logging platform.
- Not a PR management system.
- Not a semantic parser over assistant prose.
- Not a hidden orchestration runtime bolted onto dashboard UI.
- Not a cross-window control plane until that architecture is explicitly chosen.

## Recommended Roadmap

1. Land Layer 1 observation contracts:
   - `add-mcp-dashboard-consumer`
   - `add-orchestrator-dashboard`

2. Implement the read-only dashboard with forward-compatible identity hooks:
   - row/session/tab/workspace identity;
   - stable pending interaction IDs;
   - live vs persisted-only classification;
   - optional route payloads.

3. Plan and spec `add-agent-activity-stream`:
   - smallest useful activity slice should likely be workflow launch metadata plus run/tool-call summary events.

4. Plan and spec `add-dashboard-actions`:
   - start current-window-only unless cross-window ownership is solved first;
   - degrade unsupported/unreachable sessions to deep-link-only.

5. Plan and spec `add-coordinator-directives`:
   - only after action/write-path semantics are deliberate;
   - decide whether directives are messages, commands, or a new control envelope.

## Implementation Guidance for V1

The current audit against code confirmed two important seams:

- Use `AgentModeViewModel.authoritativeLiveSession(for:)` as the current-window liveness check. Do not infer live `Needs you` / `Working` from persisted `lastRunStateRaw`.
- Use active workspace context for route `workspaceID`; `AgentSessionMeta` is not a self-contained route payload.

The same audit confirmed the largest deferred source:

- There is no session-level workflow field today. Workflow is item/transcript-level, so workflow labels and Orchestrate workflow auto-detection require a future index/load decision.

## Open Questions

- For Layer 2, is current-window-only action good enough, or must actions route to owning windows?
- What is the minimal activity/event stream that unlocks useful chips without becoming a logging platform?
- Should the Coordinator be modeled as an ordinary Agent Mode session with metadata, or as a distinct runtime role?
- Are Coordinator directives plain user messages, structured commands, or a new control-plane envelope?
- What retention policy applies to activity/provenance records?
- Which activity/event fields must be persisted versus rebuilt from existing session/transcript state?
