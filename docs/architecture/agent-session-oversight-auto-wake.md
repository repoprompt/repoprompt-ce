# Agent session oversight: presentation, lifecycle, and Auto-wake

Cross-session oversight lets one Agent session (the **observer**, also called the **overseer**) watch others (the **targets**)
through a user-granted, directional, revocable link. When a target's lifecycle status changes or the
target purposefully requests attention, RepoPrompt may start an automatic follow-up turn on the
observer — an **Auto-wake** — so the model learns about it without its user having to ask.

This document covers the parts that are easy to break because their invariants are enforced in one
file and depended on in another. For the tool contract a model sees, read the `agent_session_link`
definition in `MCPDomainCanonicalToolDefinitions.swift`; for the guidance the model is taught, read
`AgentSessionLinkPrompts.swift`.

## Four owners, deliberately disjoint

Nothing here has a single god object. Confusing these four is the most common way to introduce a
defect in this subsystem.

| Owner | Responsibility | Where |
| --- | --- | --- |
| Link authority | Grants, capabilities (including default management), generations, cursors, revocation. Process-memory. | `DomainAgentSessionLinkAuthority` |
| Passive reducer | The canonical observer-local queue: first-to-final coalescing of target status edges plus separate, non-lossy attention occurrences. Owns no authority and performs no delivery. | `AgentSessionLinkPassiveStatusNotices` |
| Claim / receipt | The immutable rendered batch a provider was actually sent, including exact attention occurrence identities, and what that provider's acceptance therefore acknowledges. | `AgentSessionLinkPromptContext` |
| Wake coordinator | Temporary admission policy: may this lane start an automatic turn *right now*? | `AgentModeViewModel+SessionLinkAutoWake` |

The lane board is derived data in the existing passive observation pipeline, not a fifth owner. The target view model combines its own run outcome, stamped failure reason, send-readiness blockers, and a current child-session census into the observation snapshot; the runtime bridge publishes that snapshot through link authority, and `poll`/`wait` render it. A board change can advance the existing `wait(until: "change")` cursor, but it creates no new status or attention edge for the passive reducer, changes no Auto-wake admission rule, and persists no board state.

## Delegation scopes (amendment)

A **delegation scope** is durable, user-granted authority for one overseer session to act on many
sessions without per-item prompts (the agent-only `session_admin` tool). It sits **beside** links,
not in place of them: links remain the per-pair transport for cursors, passive notices, and
Auto-wake; a scope is the authority to act across its members.

| Invariant | With scopes |
| --- | --- |
| Grants are created only by explicit user action | Still true for scopes: a scope is created only by the user's approval card (`request_scope`) or by attenuation of a scope the user granted. Links may additionally be created **inside** a user-granted scope by its grantee. |
| Management never chains (A→B→C gives A nothing over C) | Still true for links. Authority over C comes only from C being a member of A's scope, never from chaining links. |
| Restricted grants are never upgraded | Still true. A scope neither mutates nor upgrades a link's capabilities; a link created under a scope carries capabilities within the scope. |
| Four disjoint owners | Unchanged. The **scope authority** (`DomainDelegationScopeAuthority`, held by `DelegationScopeRuntime`) is an authority *input*, not a fifth owner of link state, notices, claims, or wake policy. Any future descendant-prompt notice enters only through the passive reducer; any wake-policy change lives only in the wake coordinator. No transport-level dampers. |
| Snooze suppresses admission, never delivery | Unchanged. Scope approval cards and batch confirmation cards never pass through the oversight transport. |

Rules that hold the scope design together:

- **Membership is projected, never argued.** `DelegationMembershipProjector` computes membership
  proofs from persisted provenance (`parentSessionID`, `createdByOverseerSessionID`, and the
  future `organizationalParentID`) and presents them to the authority, the same way link leases are
  presented. Tool arguments only name targets.
- **One authority check.** `DomainDelegationScopeAuthority.authorize` runs, in order: scope live
  (grantee, active, unexpired, generation), capability held (target-independent, so checked first
  and it cannot probe membership), membership proofs valid for the scope *and every ancestor* (an
  attenuated scope never reaches beyond its parents), guardrails (whole-subtree counts across the
  scope chain), batch confirmation (an approved card authorizes one application). Each target lease is then
  re-bound by `DomainAgentSessionOperationAuthorizer` to the exact operation, caller, and target
  under the `.delegationScope(scopeID, generation, capability)` basis.
- **Uniform denials.** Only `scope_capability_missing`, `scope_guardrail_exceeded`, `scope_expired`,
  and `confirmation_required` are caller-visible. Unknown scopes, non-grantees, non-members, and
  unresolved callers all receive the existing uniform "not available / not found" text.
- **`.allSessions` scopes** hold only `observe`, `organize`, and `restructure`.
- **Human-only stays human-only.** Deleting sessions, removing or pruning worktrees, keys and
  providers, permission modes, MCP approvals and server control, settings writes, app quit/update,
  and handoff instructions are not capabilities. `agent_manage.cleanup_sessions` refuses the scope
  basis outright.
- **Revocation is a generation bump.** Revoking, releasing, or expiring a scope cascades to every
  attenuated descendant and stops authority immediately. Sessions keep running and links stay until
  released.
- **External MCP is untouched.** `session_admin` is policy-gated (`agent_session_admin`), granted by
  no static profile, recomputed live per `tools/list` and `tools/call` only for an exactly routed
  Agent Mode run (live scope, or orchestrator/overseer for `request_scope`), never advertised or
  admitted for administrative principals, and fails closed in direct-headless.

Scope intent persistence is described in
[`settings-persistence.md`](settings-persistence.md#delegation-scope-intent).

## Same-process window reopen

Window close still revokes live authority, leases, queues, and wakes. Before teardown, the runtime
bridge captures only reference-backed saved pairs in the existing launch coordinator. Its current
parked reference owns restoration or an already-admitted Unlink; historical closed references only
fence late cleanup. Exact endpoints, durable token, and assertion generation fence both paths.
Parking survives transient hydration and sequential closes until a valid restoration proof enters
the ordinary establishment path. Unlink and committed deletion forget intent; failed removal uses
the existing cleanup warning/retry. Parking is process-local, preserves no capabilities, and adds no
UI or MCP state; cold launch keeps its existing restoration policy.
Hydration need is derived from current readiness on existing reconciliation events; the loader owns
loaded/in-flight deduplication. Queued passive work must still match its complete discovery owner and
persisted descriptor before admission, so an abandoned request cannot suppress successor recovery.

## Route authority is independent of tool discovery

A provider input never waits for a returned tool catalog. For native Claude/Codex runs with exact
outbound oversight, `qualifyProviderInputRoute` obtains the existing server-actor route token:
run, endpoint incarnation, connection, routing authority generation and connection lifecycle generation.
After each suspension it rechecks the session/run/endpoint; the immutable result travels to the final
bidirectional MainActor mapping fence. Controller/configuration/attempt ownership, Stop, physical
acquisition and cancelled-before-dispatch tombstones remain independent hard gates. A real route
failure still refuses or uses the existing bounded route recovery. Unknown, absent or stale tool names
are not route failures and never trigger send-time controller recycling.

Prompt carry and wake admission read exact published membership and the claim epoch, not catalog
freshness. Required rendered content, current authority, budget and provider acceptance still own
claims/receipts; catalog refresh cannot acknowledge them. ACP's existing route/startup and dispatch
fences remain in place without importing a native pre-discovery requirement into deferred clients.
Catalog observations and `tools/list_changed` remain discovery/usability signals. This changes no
MCP tool name, schema, operation, caller identity or per-call authorization contract.

## Configuration-only model selection

`set_model(session_id, model_id)` requires the exact original **Manage** lease and a fully idle,
loaded target of the same agent kind. The target owns the final authority hop; after it returns,
endpoint identity, readiness, destination availability, and advertised membership are checked and
configuration committed synchronously. A concurrent composer claim wins. Revocation/relink before
that hop cannot substitute a new grant; later revocation does not undo an already admitted commit.
Busy/loading/settling refusals are retryable, never queued. Even identical selections pass every gate.

`AgentAdvertisedModelCatalog` indexes full compound IDs when ordinary catalogue producers run.
Admission performs bounded memory lookups only: no persistence warming, full catalogue flattening,
provider discovery, or legacy resolver fallback. Registry/backend changes invalidate the index;
a cold index tells the caller to refresh `agent_manage.list_agents` in the destination window.
`create_lane` accepts either an explicit `model_id` using this same admission or the existing
`role`/default path; specifying both is an error. Explicit selection never silently substitutes a role.

The `set_model` transport and service caller resolvers read only already-installed connection/run/context maps.
They refuse cold, pending, displaced, ambiguous, or terminal routes actionably instead of invoking generic
run recovery (rehydration, binding, session creation, selection mirroring, or routing persistence). Explicit
routing hints must match that exact installed route. Its original endpoint and routing/lifecycle generations
travel with dispatch identity through the final provider-entry fences; a successor cannot replace the caller.
Window and workspace-qualified tab indexes are derived by their existing owners on array mutation;
authorization and catalog reachability use the existing link authority's derived pair/outbound indexes and
inbound target membership. No call rebuilds an index or sweeps windows, workspaces, tabs, catalogs, or links.
Dashboard close-safety projections are derived on dashboard replacement rather than rescanned during tool
registration/completion. Generic operations retain their recovery behavior.

This is a routing specialization, not a permission fast path. Early live-link visibility, restricted-tool/role
policy, enabled-server checks, connection/resource admission, cancellation, catalog-generation ownership,
domain connection-generation validation, and exact Manage authorization still run. The model-only domain
security context deliberately grants **no** verified-process assurance, filesystem roots, or ephemeral mutation
capabilities: this operation does not belong to the protected filesystem family and authorizes solely through
its exact Manage lease. Thus no executable `lstat`, root canonicalization, or cold domain-registration repair
is needed merely to construct unused filesystem authority. Generic security-context construction is unchanged.

Model endpoint checks enforce the same observer eligibility and endpoint/deletion predicates as generic
revalidation, but **deny without eager persistent cleanup**; normal lifecycle invalidation owns cleanup.
These paths are decision-equivalent, not side-effect-equivalent. Transport-wide logging, per-run event
observer delivery, and deferred ordinary save/dashboard/publication remain ordinary infrastructure costs;
this is not a claim that the entire transport or its callbacks are O(1).

Acceptance changes per-session model/effort and narrow active UI projections, schedules persistence
and existing MCP publication, and leaves identities, provider sessions, ACP pins, draft, and staged
handoff intact. It does not start/resume/apply/reset a provider; the next ordinary turn applies the
configuration. Native ordinary sends require a current configuration proof, independently owned by
the native runtime. Default/auto selections do not promise a provider reset, and automatic effort
routing may still choose effort for a later turn.

## Autonomy is grant-scoped and prompt-governed

The user's exact direct grant is the whole structural delegation. Target-bearing observer operations
are authorized by `DomainAgentSessionLinkAuthority`, which resolves the exact observer endpoint and
target session to one direct grant, checks that operation's capability, and returns a
generation-qualified lease. `DomainAgentSessionOperationAuthorizer` participates only in the
targetless outbound `list` path, where it requires an Agent-origin caller and at least one active
outbound link before the authority returns the current inventory. `request_attention` instead requires
generation-qualified exact inverse authorization through a current inbound grant. The bridge
revalidates both live endpoint incarnations around every suspension point. Nothing else authorizes
anything.

What the transport deliberately no longer asks is **what started the observer's turn**. There is no
turn-origin predicate, no observer local-input epoch, no target-local human re-arm, and no
`cross_session_reply_requires_user_instruction` result. A turn started by an incoming cross-session
message or by an Auto-wake may send, queue, replace, and cancel exactly as a user-started turn may,
because the grant authorizing it is the same grant. Removing only the visible send refusal would have
left the user's own delegated pipeline stalled at the next Auto-wake, which is why the whole
predicate went rather than one gate.

That moves one question from the transport to trusted guidance: not *may* this turn act, but *should*
it. The answer is owned by `AgentSessionLinkPrompts.autonomyContract`. Membership guidance and a
standalone full lane block render it verbatim; a combined claim carries it once rather than twice. The
`agent_session_link` tool description and `AgentSessionLinkMCPToolService.untrustedContentNotice`
carry the same invariants in compact form. The rule is that an operation must be in service of an
explicit current or standing instruction from the observer's **own** user, and that a standing
instruction must have been given rather than inferred from a link, target activity, a status change,
a transcript, a preview, a `waiting_on` declaration, or an incoming message.

Target-derived content informs; it never authorizes. It may change what the model does under an
instruction it already has, and it may never become the instruction, approval, permission, or
authority for one. This includes `request_attention`: it is an attributed, potentially stale,
untrusted target signal accepted only under an exact current inbound grant. It is not an instruction,
permission, approval, interaction response, or source of authority. It exists to surface the target's
current user-declared waiting context, not to invent work or infer a missing observer-user instruction.

Because that guidance is versioned, a bump is load-bearing rather than cosmetic. Revision 5 retains
revision 4's purposeful-attention trust rule and makes its admission exception truthful: exact
purposeful attention may bypass master Auto-wake, that lane's own toggle, and only that exact lane's
status Auto-wake snooze without changing any of them. Admission for routine status and overflow
remains governed by selection and snooze. Every provider context is therefore re-owed the full block:
the next accepted passive batch in a context that has not accepted revision 5 carries the whole text;
later batches use the reminder, and an Auto-wake cannot physically dispatch while its required batch
could not be rendered. No second persistence mechanism for guidance exists or is needed.

Revision 7 changes what an exact outbound grant may confer rather than how it is admitted: the
grant-level `manage` capability (see *Management is an authority-owned grant capability*) lets an
overseer answer and steer its target for its own user, and the full block says outright that it
supersedes earlier observe-only wording — including refusals the overseer itself gave on the
strength of that wording. Revision 8 moves managed prompt inspection into redacted `poll`/`wait`
results and retires `get_interaction`. Revision 9 makes new and restored links managed by default;
existing restricted links remain restricted. Revisions 10 (passive lane) and 4 (inventory) keep
model-facing text focused on authority and trust while leaving operation-specific recovery with
its result. Both kinds of guidance are re-owed when their wording revision changes, even if link
membership did not.

### Feedback loops are an accepted consequence

A single grant A → B can now sustain repeated wakes. A, the observer, may send to B under that direct
grant; B may then issue `request_attention` back through the grant's exact inverse signal path; A may
wake and continue under the same original grant. The inverse signal does not create a B → A send grant,
a generic reverse-send channel, transitive authority, reciprocity, or an interaction response. It only
surfaces attributed, untrusted context for A to evaluate under A's own user's still-applicable
instructions.

If the user independently creates both A → B and B → A and selects Auto-wake for both lanes, the two
sessions can also keep waking each other through ordinary lifecycle edges. Every accepted wake
produces genuinely new edges, and queue receipts, status deduplication, and failed-fingerprint
suppression only collapse *duplicates*. This does not violate non-reciprocity — neither grant implies
the other, and the user created both explicitly.

The transport contains no cycle damper, reciprocal-link detector, chain counter, or cooldown, and none
may be added here. **Guidance is not a structural bound either**: revision 5 reduces pointless
discretionary work by telling the model not to invent follow-on work from an update or attention signal
that needs none, but that is model judgement, not a guarantee, and no surface may describe it as one.

That clause is deliberately two sentences on every surface — *do not invent work from it*, then
*continue what the instructions still require and end only when none remains*. A lane batch also
hitchhikes on turns the observer's own user started, and the per-response notice comes back mid-request,
so a single "report and end" would read as license to abandon the user's in-flight work. Any future
rewording of the contract has to preserve that split across all four surfaces
(`AgentSessionLinkPrompts.autonomyContract`, its compact `laneGuidanceReminder`,
`AgentSessionLinkMCPToolService.untrustedContentNotice`, and the tool description in both
`MCPAgentControlToolProvider` and `AgentSessionLinkAutonomyContractMigration`).

The controls are the user's, and they are the ones that already exist:

| Control | Effect |
| --- | --- |
| Per-lane `snooze_auto_wake` | Routine status and overflow on that lane stop being reasons to start an automatic turn for a bounded window; one pending explicit attention occurrence from that exact lane may still admit without changing the snooze |
| Master Auto-wake off | Stops master selection for routine status and overflow; a lane whose own Auto-wake toggle remains on stays selected, while exact purposeful attention may bypass the master setting |
| Effective lane deselection | With master Auto-wake off and that lane's toggle off, routine status and overflow stop admitting; exact purposeful attention may still admit without changing either setting |
| `Limit routine wake-ups` + `Minimum interval` | Routine status and overflow must wait a minimum interval after the observer's last oversight wake; exact purposeful attention and `Wake now` bypass it without changing it |
| `Wake now` | Processes the currently pending updates in one turn, ignoring routine selection, snooze, the interval, and failure suppression for that one attempt and changing none of them |
| Unlink / revocation | The grant and its queued sends or pending attention are gone; this remains a hard gate with no attention exception |

New live sessions start with the observer-level Auto-wake preference enabled. That is only a
creation default: hydration replaces it with the durable session value, and payloads written before
the setting existed continue to decode as off rather than silently opting restored sessions in.

Effective lane deselection — master Auto-wake off *and* that lane's own toggle off — prevents
*subsequent routine* status and overflow admission. Exact purposeful attention may bypass that
selection state and the exact lane's snooze without mutating any of them. Selection and snooze changes
may retract a routine pre-dispatch attempt, but not an exact live attention-backed attempt. Unlink,
revocation, and every other hard gate still retract either kind. No control claims to cancel a
physical provider call already in flight.

## Exact projection is presentation truth

An overseer role is derived from one exact live endpoint's stored `AgentMonitorPillProps`, never from
a session UUID, a durable intent, or an authority-wide query. `isOverseer` means exactly that the
projection has at least one outbound row. An inbound-only session is not an overseer.

`agentSessionLinkIsOverseer(tabID:expectedSessionID:)` therefore fails closed unless all of these
still agree:

1. the tab's active session ID;
2. the tab's current generation-bearing endpoint;
3. the projection map key; and
4. `props.endpoint` inside the stored value.

An in-place rebind cannot inherit the retired incarnation's badge or title marker. Active sidebar
rows read this exact role directly rather than caching it in the sidebar list model. `WindowState`
applies the same rule only to the active compose tab, decorates a freshly resolved base title with
`U+1F441 U+FE0E U+0020`, and keeps its fallback title cache undecorated. The final decorated value
flows through `displayedWindowTitle` to native tabs, the Agent titlebar cluster, `NSWindow.title`,
and Dock window lists.

## One post-storage invalidation seam, two consumer schedulers

`agentSessionLinkMutateProjectionStorage` is the sole mutation boundary for the exact projection
map. Its ordering is contractual:

```text
apply every write and removal in the logical batch
→ replace projection storage
→ synchronize the status-pill snapshot
→ post RepoPrompt.agentSessionLinkOverseerProjectionDidChange once
```

Equal replacements post nothing. A batch that changes several exact entries posts only after all of
them are visible. The notification is sent on the main actor, names the owning
`AgentModeViewModel` as `object`, and carries no `userInfo`; consumers re-read exact current state.
Neither the bridge nor the authority posts it, and there is no second role or menu synchronization
path.

The two consumers intentionally use different main-thread schedulers:

| Consumer | Scheduler | Follow-through |
| --- | --- | --- |
| `AgentSessionsSidebarView` | `DispatchQueue.main` | Wrapping revision bump read by `body`; no `.id(revision)` or row-state reset. The queue continues to drain while a system menu is tracking. |
| `WindowState` | `RunLoop.main` | Existing coalesced title request and equality-guarded window-title writer. A projection change that leaves the title equal is harmless. |

## Three eyes have three different meanings

| Eye | Surface | Meaning | Visual and interaction |
| --- | --- | --- | --- |
| Dashboard eye | Existing toolbar `AgentMonitorPill` | Open and manage this observer's oversight dashboard | Existing pill styling; interactive |
| Role eye | Permanently beside an overseer session title | This exact session currently oversees at least one target | Bare purple `eye.fill`; noninteractive; mandatory role help |
| Management eye | Sidebar trailing hover action and context menu | Manage which observers oversee this exact target | Neutral outlined `eye`; interactive menu |

The dashboard pill renders no number at absolute zero and renders each directional count only when
that direction is nonzero. An outbound relationship uses the filled accent-colored eye and outbound count;
an inbound relationship uses the orange directional indicator and inbound count; a bidirectional
state shows both. The complete rounded capsule is the button hit target, while its material and
stroke remain decorative.

The role eye uses fixed system purple rather than the user's accent color. It is a bare filled glyph;
stable placement, its tooltip, and the row's directional accessibility wording ensure the role is not
conveyed by hue alone. It remains visible without hover and in selection mode. The management eye is
hidden with other mutation controls in selection mode, and is omitted when the target has neither an
eligible observer to add nor an existing relationship to unlink. A row may legitimately show both
sidebar eyes at once; their fill, color, placement, interaction, tooltip, and directional
accessibility wording must remain distinct.

## Management is the default exact-grant capability

Every newly created oversight link includes `.manage` on its exact, directional, revocable grant.
This applies equally to an interactive Add, a restored saved pair, and an explicit re-add of a
still-saved pair. The dashboard has no Manage toggle: the link itself is the user's delegation to
observe, answer one-time prompts, and steer under the observer's own user's instructions. There is
also no oversight Auto-approve control or listener; provider permission prompts remain manual unless
the managed overseer explicitly responds to a particular eligible request.

The durable oversight document stores only observer → target UUID pairs. Older documents with a
`delegations` key decode safely because unknown fields are ignored; those values are never applied,
and the next successful mutation rewrites the document without them. No saved management or
permission-auto-approval choice can silently override the current grant default or manufacture a
reverse link. Explicitly restricted in-memory grants remain restricted and are not upgraded by an
idempotent reservation. Unlink revokes the exact grant and its issued leases; re-adding creates a
fresh managed generation, not a resurrection of the old one.

`respond` and `steer` still require `.manage` at every exact-grant fence. Managed `poll` and `wait`
retain their watch-level operation grant but disclose prompt bodies only after a separate whole-batch
management fence and live-endpoint check. A restricted link can still `poll` or `wait` for status
with `managed: false` and no prompt body; `respond` and `steer` return `management_not_granted`.
When that fence fails for a multi-target `wait` after a non-terminal wake, each target is re-fenced on
its own (as terminal survivors already are): healthy siblings keep their rows, cursors, and prompts,
and a sibling that failed its own fence releases nothing and is named in `unavailable_session_ids`.
A single-target wait, or a batch with no survivor, is still denied.
An unlinked UUID still receives the indistinguishable denial. A steer's ledger
commit still uses `commitSendAuthorization(requiresManagement: true)`, and revocation before the final
fence releases the uncommitted reservation without delivery.

### Inspecting and answering prompts

Accepted local composer input advances
an in-memory generation for the exact observer endpoint and cancels its older waits, including
requests delayed between routing and admission. New-generation waits may park in the same run.
Authority release precedes Claude/ACP's MCP-idle gate and Codex's steering drain. This affects
neither managed/cross-session input nor mutations or child providers. A route snapshot just after
the input bump may still park. Cancellation uses the
existing result with metadata-only `wake_reason: local_user_input` and re-fenced survivor rows.

Managed `poll` and `wait` may return the target's current pending approval, permission, MCP
elicitation, or question beside the sanitized snapshot, with free text through the oversight redactor
and one-time option labels verbatim. Restricted links never receive a prompt body; a single prompt
over 64 KiB yields an ID-only `too_large` manual-only stub, and multi-target results omit whole
prompts beyond their 20 KiB aggregate prompt budget. A `respond_hint` appears only with a respondable
pending interaction. `respond` answers exactly one `interaction_id`: the target view model compares the ID, validates the answer
with the parser behind `agent_run respond`, awaits the bridge's final fence (the management lease
re-validated inside the authority, both live endpoints, deletion state), compares again, and
submits without suspending. Approvals and permissions accept only `accept` (this request only),
`decline`, or `cancel`. Session-wide and exec-policy-amending approvals, Codex project-hook trust,
app-owned worktree-merge reviews, and user-input requests containing a secret field are visible but
`manual_only`. ACP permissions use only a genuine one-time allow option for accept and a one-time
reject (otherwise `cancelled`) for decline. When the provider offers no genuine one-time allow
option, `poll`/`wait` omit `accept` and `respond` refuses only accept (`manual_only`,
`no_one_time_allow_option`); decline and cancel stay available. A wait for the session's next instruction is not a prompt `respond` answers;
the managed pending-interaction note says to deliver that instruction with `steer`.

### Steering

`steer(session_id, message, idempotency_key)` delivers one instruction *now*, whatever the target
is doing, and shares `send`'s idempotency ledger under a separate digest domain
(`AgentSessionLinkMessageDigest.steerDigest`), so one key names one delivery across both
operations and a retry replays the stored receipt.

| Target state | Route | `delivery_state` |
| --- | --- | --- |
| Fully idle and send-ready | The attributed send transaction (durable row, then run start) | `run_started` / `run_start_failed` |
| Running Codex turn | Native steer, or the durable fallback queue, reported by the steer acknowledgement tracker; the deferred dispatch re-proves the exact endpoint and the exact active run, and withdraws the row (`steer_not_accepted`) if either moved | `steered` / `queued_follow_up` |
| Running Claude-native turn | The provider's interrupt-steering queue | `queued_interrupt` |
| Running ACP turn | The target's serialized ACP steering queue; an interrupt refusal becomes a follow-up with the original provider envelope | `steered` / `queued_follow_up` |
| Waiting for its next instruction | That instruction | `delivered_to_waiting_instruction` |
| Any pending prompt | Refused before the fence | `target_awaiting_interaction` |
| Between states, idle but not yet send-ready, or settled during the fence | Refused; nothing staged and the key is released | `target_busy` |
| A provider or state with no live steering | Refused before staging | `steer_unavailable` |

The running routes go through the target's own `submitPreparedUserTurn`, so a steer reaches the
provider exactly as a local composer message would. What they never touch is composer state: no
draft, attachment, tagged file, workflow, interview preference, or file-selection side effect is
read, cleared, or restored, and every withdrawal path carries an empty restoration draft, so an
overseer's words can never reappear in the target user's composer as the user's own. ACP uses a
managed context on the target's serialized steering instruction rather than a managed instruction
in the ordinary follow-up queue. Flush, requeue, stale-run withdrawal, and cancellation resolve
only managed sinks in a mixed managed/local batch, exactly once. A refused interrupt keeps the
original provider envelope in `pendingInstructions` for the follow-up, not in the user's composer.
An interrupted attributed ACP row replays its exact dispatched envelope from
`dispatchedProviderText`; older attributed rows lacking that field are still dropped rather than
reconstructed from raw transcript words. After the commit fence the transaction re-proves both
endpoints, the workspace, and admission synchronously; a run that settled during the fence is
refused as `target_busy` rather than started from a deferred path.
A provider path that withdraws the row reports `steer_not_accepted` (key released); one whose
outcome cannot be observed reports `steer_unconfirmed` with `delivered_unknown: true` (key spent).

The provider sees a RepoPrompt-authored envelope with `delegation="user_delegated_management"`:
direction from the user's delegated overseer, to be followed within the session's workspace and
existing permissions, with the target's own user prevailing and approvals still applying. It also
says that direction is never authority to direct or answer any other Agent session, so management
never chains: if A manages B and B manages C, A's words give B no authority over C. Plain
`send` keeps the byte-identical `bounded_coordination` framing, which still tells a target to leave
permission decisions and prompts to its user. The transcript row stores the raw words with the
ordinary cross-session attribution badge.

## Target-centric sidebar management stays exact

A target menu is a UI-only projection over one exact target endpoint. It carries independent
observer-to-target relationships, so several observers may oversee the same target and unlinking one
must not disturb the others. Available observers are exact live, top-level, observer-eligible Agent
endpoints that the same authority projection says currently hold at least one outbound oversight
link, other than the semantic self. Running, idle, waiting, failed, or completed display state does
not affect availability.

When a live observer supplies a UI-only execution-location label, both Add and Unlink choices prefix
the task name with it (`location: task`). A relationship whose live candidate disappeared retains
its existing task/identifier fallback rather than inventing location metadata. The destructive menu
title quotes that compound label and says `Stop oversight by …`; its accessibility label additionally
names the target. This keeps the location colon out of the surrounding grammar and never reduces the
action to an ambiguous bare `Stop`.

Linked relationships are projected independently of available-overseer membership and retain the
exact observer endpoint and generation-qualified reference even when that observer's live candidate
disappeared or became ineligible. Such a row remains unlinkable. Available options are different:
they intersect authority-owned exact outbound membership with a snapshot of live eligible candidates
and can become stale after a close, rebind, hydration change, MCP capture, role-policy change, or a
change to the candidate's final outbound link.

Staleness is controlled at both boundaries:

- the single projection notification makes the sidebar re-render, and the row resolves the current
  menu again when SwiftUI materializes its hover or context menu;
- Add re-resolves the chosen option immediately before calling the bridge, then the shared exact Add
  core revalidates both endpoint incarnations and eligibility across its suspension points. The
  sidebar entry point additionally requires existing exact outbound membership before durable
  insertion, at reservation, and atomically at activation; other Add surfaces may still create an
  observer's first link.

A stale Add fails closed, focuses neither window, and writes persistent row-level feedback that
survives hover loss and menu dismissal. The authority task itself also survives menu dismissal.
Relationship state is never changed optimistically; the next exact projection publication renders
the result.

### Stop is authority-first

Stop does not use candidate availability as proof. Under the existing pair-retirement lane it asks
`DomainAgentSessionLinkAuthority.activeGrant(for:)` for the generation-qualified reference and
requires the recorded observer and target endpoints to match the captured exact endpoints. An
endpoint mismatch is stale and mutates nothing; an authority-absent reference is idempotently already
stopped, even if the UUID pair was later re-added.

When the grant is active, Stop settles and removes only the bookkeeping or durable token owned by
that exact reference, then revokes only that reference. It never derives a token or replacement grant
from the UUID pair, never deletes a newer token, and never touches another observer of the target.
This is why a target can unlink an authority-recorded observer after that observer's window has
disappeared.

Sidebar unlink is a destructive per-observer action with no confirmation and no Undo. Popup unlink
continues to offer its existing bounded Undo. The sidebar must not reuse the popup's recovery state.

## Seen is an exact `.monitorPoll` presentation commit

`New` is the only explicit acknowledgement control. Opening the dashboard, rendering a row, or using
View Agent does not acknowledge activity. The first authoritative row establishes a baseline; equal
or regressed activity does not reassert `New`, while strictly newer activity does.

The Seen path authorizes `.monitorPoll`, derives the actual generation-qualified reference from its
lease, and compares the expected reference plus both exact endpoints. It then performs final lease
validation, re-reads the live exact candidates, samples the target's current activity, advances the
exact target high-water, and writes the exact observer/target/reference-qualified Seen record
without another suspension. The record is observer-local presentation state: it changes no link
authority, target, prompt, or Agent-visible state. There is no Agent-facing completion action.

## Presentation-only repaints cannot become Auto-wake

The authoritative projection pass may publish prompt inventory and collect and reconcile
passive-status samples.
The presentation-only lane is structurally narrower: `performMonitorProjectionRefresh` builds only
`makeMonitorProjection`, leaves status-sample collection disabled, and deliberately discards its
`statusSamples`. Location, Seen, settings, sidebar-menu eligibility, and observer-role repaints
therefore cannot:

- publish prompt inventory or reconcile the passive reducer;
- advance target-local activity or narrate a status edge;
- enqueue, claim, or receipt an Auto-wake; or
- read, resume, or notify the target session.

The post-storage notification carries no sample, authority value, or mutation request, so its
sidebar and title consumers cannot cross this boundary either. Auto-wake admission continues to read
the canonical passive queue and the wake coordinator described above, never sidebar presentation. A
location repaint before claim reservation may affect the claim's local display provenance described
below, but it still cannot enqueue, authorize, or alter the Auto-wake itself.

## Purposeful attention is an inverse signal, not reverse send

`request_attention` is an operation on the existing `agent_session_link` tool, not a new tool or
capability. The target calls from its exact live endpoint. The bridge enumerates only active grants
whose exact generation-qualified target endpoint matches, removes stale observer endpoints, and then
resolves the optional `observer_session_id`. Omitting it succeeds only when exactly one live authorized
observer remains; ambiguity is bounded and fails closed. An exact active link in either direction
deliberately makes `agent_session_link` reachable even when the run profile's restricted-tool,
policy-gated-grant, or role advertisement/execution filters would otherwise hide or reject it. The
exception is limited to this tool and a server-routed exact endpoint: a static policy grant cannot
manufacture it, global MCP disable remains absolute, and the disabled-tool setting still wins for
catalog advertisement. Reachability never supplies outbound or inverse operation authority; the
service authorizes each direction independently.

After inverse authorization, the bridge awaits the existing observer-scoped authoritative projection
refresh before revalidating the proof and enqueuing. This repairs a missing or lagging observer-local
baseline without fabricating a grant or a one-lane reducer; all exact endpoint, eligibility, membership
revision, and generation fences remain after the refresh. An authorized request then appends one
immutable occurrence identity to separate, observer-local attention storage. A hard enqueue-time cap refuses excess attention rather than evicting an occurrence, and
attention neither evicts nor consumes the reducer's coalesced status intervals. Publication lets the
occurrence ride a natural observer turn or, if every hard admission gate permits, start an Auto-wake
through its exact lane. Exact purposeful attention may bypass master and per-lane routine selection and
that exact lane's snooze without changing them; admission for routine status and overflow remains
selection- and snooze-governed. The rendered immutable claim names the occurrence and grant. Before
provider preparation and again at physical acquisition, the occurrence must still be pending under
that exact current grant; omission from the rendered budget or loss of authority is a definite no-call.

The prompt renderer owns the one 24 KiB supplement budget. It reserves room for passive progress
before admitting inventory rows, then chooses a deterministic subset of the current passive snapshot:
purposeful attention first, routine status second, stable within each group, while continuing past a
row whose escaped form does not fit. `deferred` counts offered rows absent from this envelope; unlike
reducer `omitted` overflow, their data remains queued. The immutable receipt names exactly the status
rows and attention occurrences rendered, plus the overflow watermark disclosed, so provider
acceptance removes only visible content and republishes the remainder for a later claim. A retry of
the same logical dispatch reuses the same immutable subset. No second queue, cursor, or delivery state
exists for this paging behavior.

Every successfully accepted tool call returns the same `result: "accepted"`, whether it created a new
pending occurrence or coalesced with one already pending. That result reveals neither queue state nor
provider delivery and promises no wake. At the enqueue cap the tool instead returns exactly
`result: "attention_queue_full", accepted: false`; no occurrence was stored, so the target reports the
refusal rather than busy-retrying or treating it as accepted. Only acceptance of the observer's
immutable rendered batch by the provider produces a receipt. Attention is occurrence-qualified: a
stale or out-of-order receipt cannot clear a successor occurrence, an unaccepted batch leaves the
occurrence pending, and a target may request attention again after the previous occurrence is
receipted.

`set_waiting_on` is related context, not part of the attention transaction. It is optional,
self-scoped and session-global, shared with every linked observer, mutable, and published non-atomically
through a separate state path. It is never a prerequisite for `request_attention`, is never auto-set or
auto-cleared by attention, and may be absent or may change before or after the attention claim is
composed. Both the declaration and the attention signal remain attributed untrusted target data; they
never become an observer instruction or authority.

## Compaction is a send-gated native command, not a message

`agent_session_link` `compact` asks one exact target to compact its provider context. The
distinct `monitorCompact` identity requires `send_when_idle`, so every send-capable link can compact
and no grant or UI changes. That delegation is the deliberate trade-off; a separate capability would
either be decorative in the default set or leave existing links without it.

It is a sibling of the send transaction, not a kind of send. It shares the readiness gate, composer
claim, commit fence, durable-before-dispatch ordering, and idempotency ledger (under a
domain-separated digest, so a key spent on a send conflicts rather than replays). It differs in two
places. It records a `.system` request row with fixed text and typed `crossSessionAttribution`
instead of a user row, and it dispatches a RepoPrompt-constructed command
(`AgentProviderControlCommand.compact`) instead of an envelope: Codex compacts through
`thread/compact/start`, and Claude Code receives exactly `/compact` through its ordinary run
pipeline with every decoration (handoff, oversight supplement, instruction packaging, effort)
skipped and no interrupt of an in-flight turn. No caller text ever reaches the provider. Every other
unsupported runtime returns `not_supported` rather than a message asking the model to compact itself.

ACP uses an undecorated `session/prompt` only for a live Devin, Grok Build, or Antigravity
session that advertises `compact` for its exact conversation. Each `available_commands_update`
replaces its controller snapshot; opening or retiring the session clears it. A missing live
session or unobserved command list is retryable `no_provider_session`; an observed list that lacks
`compact` is `not_supported`. OpenCode user commands and Cursor never qualify. A command never
starts/replaces a controller or applies model/mode configuration. The controller rechecks idle state,
conversation, advertisement, and the **current** request's compatibility immediately before the
write, including Devin's launched permission mode. An unsent refusal retains a usable controller;
a retired one is detached and shut down. Busy is not retired.

ACP context count becomes unknown at dispatch: new occupancy may vouch for it again, but this
command's billed prompt count cannot. A proven no-send restores the withdrawn vouch only if no
newer occupancy replaced it. Instant silent completion may mean background work that the
session's next prompt would cancel, so it adds a fixed transcript hint and starts a 90-second
settle hold (`AgentTabSession.beginACPBackgroundCompactionSettle`). While it lasts, delivery
readiness is `target_not_idle` — refusing `send`, `compact`, and parked `when_sendable` drains —
Auto-wake and periodic wakes are not admitted, and `poll` reports `idle_for_send: false` with
`send_blockers: ["background_compaction_settling"]`. Expiry publishes a readiness change, so parked
work resumes without polling; any new run start (the session's own user is never held) ends the
hold early. It is a cancellation guard, not completion proof. Duplicate receipts retain the
background metadata.

A failed last run is not a readiness blocker, so a target that died on context length is admissible;
any interaction or `awaiting_user` is `target_not_idle`. `accepted` means started, not completed: completion is
observed through `poll`/`wait`, where the `context` count reads unknown after the compaction signal
until the provider reports a new one.

## Snooze suppresses routine admission, never delivery

A snooze is observer-local policy on one exact lane. It is keyed by
`(observer endpoint, generation-qualified link reference)`, held only in process memory on the
owning `AgentTabSession`, and dies with that incarnation — a rebind, unlink/relink, or relaunch
always starts unsnoozed.

What it does: stops routine status and overflow on that lane from being reasons an automatic turn
starts. One still-pending attention occurrence from that exact lane may bypass this snooze, master
Auto-wake, and that lane's own toggle. It does not clear or shorten the snooze or change either
selection setting, and after the occurrence is receipted the still-active snooze continues to suppress
routine admission.

That exact purposeful-attention exception bypasses no other gate. Unlink and revocation, exact
authority, readiness, bounded queue admission, failure suppression, prompt eligibility, immutable
claim and budget, physical-dispatch acquisition, and the tombstone fence all remain hard. The
exception neither grants generalized priority nor changes routine status and overflow admission.

What Snooze deliberately does **not** do, and must never be changed to do:

- filter, receipt, baseline, or discard the canonical queue;
- change link authority, durable Auto-wake selection, or failure suppression;
- read, write, resume, or notify the overseen session.

Consequences that follow from that, and are intended rather than bugs:

- a snoozed lane's updates keep coalescing and still ride along on a turn the observer's own user
  starts, or on a wake another unsnoozed lane admitted (a *hitchhiker*);
- expiry promises **one ordinary re-evaluation**, not a turn. The usual readiness, authority,
  routine-selection and suppression gates still decide, so content already delivered naturally, or a
  lane that net-reverted, correctly produces nothing.

Because the reducer's status storage keeps one coalesced status interval per lane and no status event
history, the only honest description of what survives a snooze is "the current coalesced summary" —
never a count of missed events. Copy and model guidance are written to that standard on purpose.

### The Auto-wake control is subordinate to its lane

In the dashboard's Overseeing list, each lane is a compact two-line block. The primary location label
is the lane's sole normal View affordance; only that label activates the existing exact deep-link
route, and the separate View control has been removed. It remains a native SwiftUI `Button` with an
accent treatment and a rectangular content shape; no cursor abstraction is part of this contract. If
the presentation location is missing while the route remains valid, the actionable fallback reads
`Open session` rather than presenting a clickable unavailable-state label. Its accessible name
contains both the visible location/fallback and the task name. Route failure copy speaks only about
whether the session can be opened, reserving “location” for the worktree/workspace label.

New, Auto-wake, Snooze status Auto-wake, and Unlink remain independent controls, but the location
View action and the row's other primary mutations retain the same shared busy-row gate, exact route,
and failure-feedback path as before. Task metadata and the smaller Snooze status Auto-wake control
share the secondary line. This
keeps the control visibly attached to the metadata it qualifies and balances it beneath the primary
actions. A faint rule may fall only *between* two complete blocks
(`AgentMonitorLaneGrouping.drawsSeparator`) — never inside one, which would present a lane's snooze
control as an entry with no lane, and never after the last, where the section's own `Divider()`
already ends the list and a second rule reads as an empty lane. Manual design review should verify
enabled and disabled tooltip copy, keyboard and VoiceOver activation, exact routing and failure
feedback, and the independence of New, Auto-wake, Snooze status Auto-wake, and Unlink.

The inbound **Overseen by** list applies the same navigation rule to only the observer's primary
name/identifier label. Its route is derived from the authority-recorded exact observer endpoint, and
it shares that generation-qualified row's busy and failure-feedback state with Unlink. Provider
metadata remains static, and neither the secondary detail nor the complete row becomes a navigation
target, so opening an observer cannot overlap or masquerade as revocation.

## The routine wake interval is admission spacing, not a schedule

An observer may require a minimum interval between *routine* automatic wakes. It is durable
observer-session configuration (`routineWakeIntervalEnabled`, `routineWakeIntervalSeconds`), default
off, retained while off, and normalized to one of 60/300/600/900/1800/3600/10800 seconds by
`AgentSessionLinkRoutineWakeInterval.normalized` — the one helper every decode, restore, and write
path shares.

Timing is measured from the **transport boundary**, not from a clock: the first successful transition
to `.dispatching` in `agentSessionLinkAcquirePhysicalDispatch` records an endpoint-qualified monotonic
stamp on `oversight.lastOversightWakeDispatch`. Four consequences are deliberate. Every oversight wake
stamps — routine, purposeful attention, and manual alike — so an attention wake restarts the interval.
The stamp is recorded even while limiting is off, so enabling it later measures from the wake that
actually happened. A re-entrant acquire cannot restamp, and a definite no-call never stamps at all.
And because the stamp names the exact observer endpoint, a rebind fails open rather than inheriting
its predecessor's timing, while an unlink/relink inside one incarnation does not reset it.

The interval filters `AgentSessionLinkAutoWakeAdmission.routineAdmittingLanes` and overflow, not just
the initial scheduling decision. That is load-bearing: `routineLaneAdmits` is what the physical fence
uses to tell a basis from a hitchhiker, so a boolean-only gate would still let a deferred rendered
status row justify a provider call. Deferral is admission-only in the usual sense — nothing is
receipted, baselined, or dropped, and deferred rows still ride along on the observer's own next turn
or on any admitted wake.

Expiry owes **one ordinary reevaluation**, and it shares the snooze deadline task rather than adding a
second scheduler: `nextAutoWakeDeadline` takes whichever of the two comes first, so simultaneous
deadlines produce one evaluation. The interval is armed only when routine content is actually waiting
on it (`routineDeferralOwingReevaluation`: pending routine content, not the shape already parked in
failure suppression, and a prompt context that could carry it). Without that condition this would be a
periodic timer, which it is not.

## `Wake now` is one attempt, not a second queue

`Wake now` reserves an ordinary `AgentSessionLinkAutoWakeAttempt` whose stored
`admissionBasis` is `.manual`, alongside `.routineStatusOrOverflow` and `.purposefulAttention`. The
basis is what every later gate re-evaluates under — pre-claim reselection, the shared eligibility
fence, and physical acquisition — which is why it is stored rather than re-derived: nothing in the
queue could recover a user's click.

For that one attempt, manual policy admits every exact live lane and ignores snooze, the interval, and
failure suppression. It **writes** none of them: the stored `suppressedWakeFingerprint` survives a
manual attempt, so a later automatic publication of the same failed shape stays suppressed, and
ordinary acceptance remains the only thing that clears it. Every hard gate still applies — authority,
readiness, the immutable claim and its budget, physical acquisition, and the tombstone fence — and a
manual attempt still requires rendered content that is live under exact current membership.

A request is answered for the instant it was made. `AgentMonitorWakeNowRefusal` refuses an empty queue,
an occupied slot (including a tombstone), a busy observer, and an ineligible prompt context; a busy
refusal stores nothing to run later, and a manual reservation is released rather than parked if the
observer stops being dispatchable before preparation. `.scheduled` says a reservation was accepted,
never that a provider call happened.

The dashboard renders the same predicate it acts on. `AgentMonitorPendingUpdates` counts *coalesced*
queue content — status entries plus attention occurrences, grouped by target and labelled from the
existing lane rows — and discloses unattributed overflow separately, so an overflow-only queue reads
as `Additional changes pending` rather than empty. The `Next wake in …` countdown appears only when
the interval is the one thing delaying a wake that would otherwise be accepted right now, and it is
omitted rather than shown as zero once elapsed. `agent_session_link` is unchanged: the interval and
`Wake now` have no agent-facing surface.

## Periodic idle wake

Periodic waking is a separate, default-off observer-session preference, not notification admission
spacing. It applies only while the session has at least one live outbound oversight relationship.
The compact `Wake periodically when idle` checkbox and adjacent picker offer 10/30/60/120/360 minutes
(default 30). The existing routine-limit checkbox likewise keeps its picker on the same row. The entire
wake-controls block is visible only with outbound oversight; inbound-only sessions do not show it.
Hiding these controls does not clear the session's saved preferences.

A periodic wake starts an ordinary turn after the observer has remained idle for the chosen interval
since its last completed turn. It may run with no pending notifications. The turn receives:

> [Periodic wake-up. Perform only checks or follow-ups previously requested by the user. If none are due, take no action and return to idle.]

Periodic waking never interrupts an active turn or answers an approval/user interaction. Missed ticks
are not accumulated. It is independent of routine notification selection, throttling, and per-target
snoozes; explicit attention remains immediate. The timer grants no new tool or task authority, and
an otherwise empty check still consumes a model turn. Enabling or restoring the preference while idle
starts a fresh interval; there is no restart catch-up.

The independent idle timer reserves the existing `pendingAutoWake` slot with a periodic basis, not a
fabricated notification. Exact session/composer ownership fences preparation and cancellation; a
cancelled producer remains fenced until refusal or proven settlement. Provider acceptance releases
execution ownership even without a notification claim. ACP's ordinary instruction wait also releases
its exact acquired reservation, because ACP reports acceptance only after its prompt completes;
optional notification receipts still belong to that captured completion callback.

## The `.cancelledBeforeDispatch` tombstone is a fence, not bookkeeping

When a snooze or selection loss retracts a routine wake that is already in `.preparingDispatch`, or
when any hard eligibility loss retracts either kind of wake, `cancelAgentSessionLinkAutoWake` does not
clear the attempt. It converts it to `.cancelledBeforeDispatch` and leaves it in place.

That tombstone looks like dead state and is not. Providers do not mint the wake's dispatch ID — they
use their own (`codexNativeSend`, `claudeNativeSend`, `codexFallback`, and so on), and
`agentSessionLinkEffectiveDispatchID` plus `AgentModeViewModel.dispatchRequiresLaneBatch` (both in
`AgentModeViewModel+SessionLinkPrompt.swift`) rewrite that ID to the wake's **only while an attempt
exists in `.preparingDispatch`, `.cancelledBeforeDispatch`, or `.dispatching`**.

Clear the tombstone while a provider path is still preparing and the rewrite stops happening: the
provider's own ordinary ID reaches `agentSessionLinkAcquirePhysicalDispatch`, which correctly
classifies it as *not* in the reserved Auto-wake family and returns `true`. The call goes through
unfenced, and the retracted lane wakes the model with no claim and no provenance row.

The reserved family itself fails closed. An ID whose raw form is in the `lane.autowake:` family but
does not parse as exactly one canonical UUID is refused rather than treated as ordinary, and
`dispatchRequiresLaneBatch` classifies the whole family as non-ordinary, so a constructor and parser
that disagreed could not downgrade an Auto-wake into an unfenced dispatch. That protects the *format*;
it cannot protect a rewrite that was never applied, which is what the tombstone is for.

Two rules follow.

1. **Only a path that can prove no transport call happened may release a tombstone** — the
   preparation finalizer, the physical-acquisition refusal, or an explicit not-attempted settlement.
2. **Repeated cancellation preserves a tombstone for every wake type.** Once preparation is
   cancelled, settings changes, local submits, and endpoint invalidation cannot clear its dispatch
   fence. Only the owning preparation finalizer or a definitive no-call settlement may release it.

A tombstone can never be rescheduled, so a publication absorbed while it stands schedules nothing.
The preparation finalizer replays one ordinary evaluation after releasing it, which is what keeps
the expiry and clear promises true.

## Lane attribution is local display only

An accepted Auto-wake appends one `.system` provenance row. Its raw `text` is a fixed canonical
marker and must stay that way: transcript replay re-emits system rows verbatim inside
`<system>…</system>`, so interpolating a target-derived name there would put untrusted target prose
into trusted-looking provider context and could break the envelope.

Richer wording is derived at render time from `AgentLaneUpdateDisplayAttribution`, typed metadata
captured from the **immutable rendered batch of the accepted claim** — never from acceptance-time
live links, selection, or snooze state. During claim reservation, the observer synchronously snapshots
only its exact endpoint's current monitor projection and joins rendered entries to UI execution
locations by generation-qualified link reference. A persisted local label may therefore read
`location: task`; location means the UI location at immutable claim construction, not at the earlier
status transition. A later repaint, unlink, relink, or acceptance cannot rewrite the claim. Missing,
blank, invalid, or generation-mismatched display data degrades to the existing task-only attribution.

The transient reference-to-location map does not enter prompt context, render requests, provider
fragments, fingerprints, receipts, or link authority. Attribution still carries at most two
already-capped, sanitized labels, a distinct-lane count, and one overflow flag: no UUID, reference,
endpoint, preview, path, or status payload. Location and task are sanitized separately;
`location: task` is used only when the complete sanitized pair fits the existing 120-byte label
budget. Otherwise the optional location is omitted and the full sanitized task label is preserved.
Labels are stripped of format and bidi scalars, and the sentence's own curly quote delimiters are
folded to ASCII inside a label, so an untrusted name cannot close the
quoted span the grammar opened around it. The transcript row's canonical raw text remains unchanged.

## Bounded race fixes and known deferred work

Purposeful attention could be a one-shot signal followed by target idleness, so three races that status
could previously self-heal on a later edge required bounded fixes. Those fixes deliberately did not
replace the wake attempt or tombstone architecture:

1. At the existing `attemptedFingerprint` assignment, the attention component comes from the reserved
   immutable claim. The status component retains its prior behavior.
2. One observer-session reevaluation-owed Boolean records publication absorbed by a non-schedulable
   attempt. Safe release paths drain that one-shot debt rather than waiting for another target edge.
3. The emptied-queue cancellation path phase-checks an existing `.cancelledBeforeDispatch` tombstone,
   so a repeated cancellation cannot clear the transport fence while preparation may still acquire.

The larger root cause remains accepted deferred work: **the status wake attempt stays mutable after its
provider claim is immutable, and the tombstone that fences an in-flight dispatch lives in the same
single slot as the live attempt.** A future general remedy is one immutable in-flight dispatch record
on `AgentTabSession`, separate from the mutable reservation. The bounded attention fixes must be
absorbed into that record rather than duplicated.

### A returned catalog can get stuck saying the tool is gone

One projection state cannot heal itself: the *returned* catalog says `agent_session_link` is absent
while the link authority says that exact endpoint holds a live grant in either direction. It is produced by
ordinary code. `notifyToolListChangedForAgentSession` republishes the observation with the returned
presence **preserved** and any-link presence recomputed, so a grant restored against a live run whose
client has not re-read `tools/list` lands on exactly `hasAgentSessionLink == false` plus
`hasAnyActiveLink == true`. A client may therefore lack usable observer tools or inverse `request_attention` even though the
server still authorizes current calls. This no longer withholds `agentSessionLinkPromptContext` or
blocks a send: discovery repair is separate from route proof and current operation authority.
The repair uses any-link membership; observer operations remain strictly outbound-only.

The repair is Codex-only, bounded to **one controller replacement per repair cycle**, and made of
parts that already existed:

| Piece | Where |
| --- | --- |
| Mismatch and close predicates, cycle value | `AgentSessionLinkCodexCatalogRepair` (`isStuckProjection`, `projectionResolvesCycle`, `Cycle`) |
| Cycle record | `AgentTabSession.codexSessionLinkCatalogRepairCycle` |
| Opens/closes the cycle | `agentSessionLinkReconcileCodexCatalogRepair` in `AgentModeViewModel+SessionLinkPrompt` |
| Spends the cycle | `codexRepairSessionLinkCatalogIfQuiescent` in `CodexAgentModeCoordinator` |
| Quiescence gate | `isQuiescentForControllerReplacement` in `CodexAgentModeCoordinator`, reading `oversight.pendingAutoWakeOwnsTransportBoundary` |
| Re-admits the queue | `agentSessionLinkRedriveCurrentPassiveSnapshot` in `AgentModeViewModel+SessionLinkAutoWake` |

**The cycle records a controller generation, not a Boolean.** `nil` on the session is no cycle;
`Cycle.state(currentControllerGeneration:)` answers `.pending` while the recorded generation still
equals `codexControllerGeneration` and `.spent` once it differs. The spent state is written by
nobody — `codexController.didSet` rotates the generation on every identity change, so *surviving*
that rotation is the record that some replacement already happened. That is why it must never be
cleared from controller teardown, and why repeated higher-revision false publications cannot cause a
second replacement: generation comparison, not projection revision, is the loop bound. A Boolean
cannot express "an unrelated reconnect already spent this cycle" without a second field or
instrumenting all five teardown routes.

One spent shape is a dead end rather than a recovery, and is the one case the repair still acts
on. A `preserveRunID: true` reconnect can retire the controller while its follow-up
`ensureCodexNativeSession` fails, leaving an established run with no provider at all: nothing will
ever publish a healed catalog for that run, so the established-run gate keeps failing closed forever.
When the cycle is spent but `codexController == nil` and `runID != nil`, the repair retires the
run identity through the same host-authoritative reset the pending path uses, clears the cycle, and
re-drives — no second controller replacement.

**Opening happens in the projection reconciler**, which is the only frame where the mismatch and the
storage that produced it are visible in one synchronous MainActor step; writing the marker before
calling the coordinator is what makes the open atomic against a nested publication.
`projection.isReady` is deliberately not used — the state being recognized is intentionally unready,
and `AgentSessionLinkCodexCatalogRepair.isStuckProjection` names it.

What the publish guard proves is *identity*, not route currency: the projection carries a route token
naming this tab's current endpoint, for this session object's current run, at a revision no lower than
the stored one. It does not prove the observing connection still owns the authoritative route when the
repair actually runs; native dispatch instead qualifies its own actor-owned route token and checks
the exact bidirectional mapping immediately before entry, independently of positive catalog presence. The accepted bound
is therefore that a projection may already be one connection generation stale by the time the repair
runs, costing one controller replacement on a session that was going to reconnect anyway — bounded by
the cycle record, and no more accurate than an authority round trip that can go stale the same way.

A cycle is closed by exactly five paths, all of which mean it is *over* rather than spent:

| Close path | Where |
| --- | --- |
| Exact current positive catalog (`hasAgentSessionLink == true`) | projection reconciler |
| Exact any-link loss (`hasAnyActiveLink == false`) | projection reconciler |
| Provider switch away from `.codexExec` | `handleProviderSwitch` |
| `agent_session_link` disabled when the cycle is spent | repair entrypoint |
| Stranded consumed run (`codexController == nil`, `runID != nil`) after its retirement | repair entrypoint |

An unknown observation closes nothing and leaves the cycle open, because it is not evidence that
anything healed (`projectionResolvesCycle` is deliberately not the negation of `isStuckProjection`).

**The repair retires the process run** (`invalidateCodexControllerForReconnect(… preserveRunID: false)`)
and that is the point rather than a side effect. `codexConversationID` and `codexRolloutPath` are
deliberately untouched, so the next ordinary start resumes the same Codex conversation and can initialize a successor
catalog. Run retirement remains the existing bounded discovery repair mechanism, not a prerequisite
for admitting the already published passive snapshot or a reason to wait during provider dispatch. Late completions from
the retired route stay safe through the existing `session.runID == projection.runID` publish guard and
`completeRunCatalogObservation`'s ownership rule.

**Quiescence is mandatory, not advisory.** Invalidation deliberately abandons the fallback queue with
the controller, so repairing under fallback ownership would drop the user's queued text; a terminal
commit that has staged its revision but not finished publishing still owns the run; and a wake in
`.preparingDispatch`, `.cancelledBeforeDispatch`, or `.dispatching` owns the same transport boundary
the tombstone fences. A blocked cycle is simply left pending — no task, timer, queue, or new phase —
for the next projection reconciliation or the next winning terminal commit.

**Enablement is re-sampled at spend time, not inherited from the open.** A cycle opened while
`agent_session_link` was enabled can be spent much later at a terminal commit that never passes
through the reconciler's own gate. Once the tool is disabled the absent catalog is truthful, so the
cycle closes and nothing reconnects.

**Terminal ordering is load-bearing.** In `finalizeCodexRun.postCommit` the repair runs *after*
`settleCodexComputerUseActivationAfterTurn`, so a computer-use replacement rotates the generation
first and the two coalesce into the cycle's one replacement; and *before*
`scheduleCodexIdleShutdownIfNeeded`, so shutdown is never armed against a controller about to be
retired. It is deliberately **not** gated on `providerSuccessor == nil`: a successor that is still
accepted or retryable *is* the fallback queue head, which the fallback-ownership guard already
refuses, while a stale or permanently rejected successor leaves no queue behind and gating on its
mere presence would strand the cycle on a session with nothing left to re-drive it.

The accepted cost is that a healthy idle controller may be recycled during the transient interval
before a compliant client processes `list_changed`. That is bounded at one replacement per cycle,
which is the trade for having no grace timer, no retry task, and no successor protocol.

The feature intentionally has no reason payload, priority, broadcast, idempotency ledger, persistence,
expiry, cooldown, target-side cancellation, delivery-ack API, reciprocal-link detector, new capability,
new tool, per-caller schema variants, target-side prompt supplement, inbound inventory operation,
generic reverse-send channel, provider-adapter changes, or broad immutable-dispatch refactor. These are
YAGNI non-goals, not missing pieces to infer from the attention operation.

## Catalog-convergence diagnostics

Oversight catalog repair has one always-on, local diagnostic channel in normal builds. It uses macOS
Unified Logging rather than a custom file, setting, exporter, or retention service, so macOS owns
bounded storage and rotation. The category records only low-volume catalog lifecycle transitions:
server projection publication, host projection acceptance or rejection, repair cycle open/close and
terminal spend outcomes, and receipt of an `agent_session_link` tool call.

The diagnostic API is typed. Fields are closed enums, booleans, bounded revision/generation values,
and one-way hashes used only to correlate run, tab, and connection lifecycles. It never accepts or
records prompts, transcript text, tool arguments or results, workspace/session names, paths, raw UUIDs,
URLs, credentials, provider payloads, or arbitrary error strings. The broad Agent Mode performance
logger and raw provider-event capture remain DEBUG-only and opt-in.

This channel observes existing authority; it does not add a refresh receipt, retry loop, timer, queue,
state machine, or provider policy. Its purpose is to distinguish future failures where RepoPrompt never
publishes the tool from failures where the server projection is ready but the provider/model catalog
does not converge.
