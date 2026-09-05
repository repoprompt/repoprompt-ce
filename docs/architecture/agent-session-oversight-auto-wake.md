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
| Link authority | Grants, capabilities, generations, cursors, revocation. Process-memory. | `DomainAgentSessionLinkAuthority` |
| Passive reducer | The canonical observer-local queue: first-to-final coalescing of target status edges plus separate, non-lossy attention occurrences. Owns no authority and performs no delivery. | `AgentSessionLinkPassiveStatusNotices` |
| Claim / receipt | The immutable rendered batch a provider was actually sent, including exact attention occurrence identities, and what that provider's acceptance therefore acknowledges. | `AgentSessionLinkPromptContext` |
| Wake coordinator | Temporary admission policy: may this lane start an automatic turn *right now*? | `AgentModeViewModel+SessionLinkAutoWake` |

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

An authorized request appends one immutable occurrence identity to separate, observer-local attention
storage. A hard enqueue-time cap refuses excess attention rather than evicting an occurrence, and
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
2. **`cancelAgentSessionLinkAutoWake` is not idempotent across phases.** It converts
   `.preparingDispatch` into a tombstone, but a *second* cancel of an already-tombstoned attempt
   falls past both phase guards and clears the slot. Any new caller must check the phase first.
   Repeated eligibility loss is the ordinary case, not an exotic one: a hard gate publishing again,
   or a routine lane's snooze extension or idempotent selection repeat, can all re-drive that path.

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
absorbed into that record rather than duplicated. The general non-idempotent-cancel refactor beyond the
single phase guard also remains deferred.

### A returned catalog can get stuck saying the tool is gone

One projection state cannot heal itself: the *returned* catalog says `agent_session_link` is absent
while the link authority says that exact endpoint holds a live outbound grant. It is produced by
ordinary code. `notifyToolListChangedForAgentSession` republishes the observation with the returned
presence **preserved** and outbound presence recomputed, so a grant restored against a live run whose
client has not re-read `tools/list` lands on exactly `hasAgentSessionLink == false` plus
`hasActiveOutboundLink == true`. For any established run `agentSessionLinkPromptContext` then fails
closed, and the only admission exception — the `session.runID == nil` cold bootstrap — is unreachable
while that run identity persists. Auto-wake is blocked behind a projection nothing else will fix.

The repair is Codex-only, bounded to **one controller replacement per episode**, and made of parts
that already existed:

| Piece | Where |
| --- | --- |
| Episode marker | `AgentTabSession.codexSessionLinkCatalogRepairSourceGeneration` |
| Opens/closes the episode | `agentSessionLinkReconcileCodexCatalogRepair` in `AgentModeViewModel+SessionLinkPrompt` |
| Spends the episode | `codexRepairSessionLinkCatalogIfQuiescent` in `CodexAgentModeCoordinator` |
| Re-admits the queue | `agentSessionLinkRedriveCurrentPassiveSnapshot` in `AgentModeViewModel+SessionLinkAutoWake` |

**The marker is a controller generation, not a Boolean.** `nil` is no episode; equal to
`codexControllerGeneration` is pending; different is consumed. The consumed state is written by
nobody — `codexController.didSet` rotates the generation on every identity change, so *surviving*
that rotation is the record that some replacement already happened. That is why it must never be
cleared from controller teardown, and why repeated higher-revision false publications cannot cause a
second replacement: generation comparison, not projection revision, is the loop bound. A Boolean
cannot express "an unrelated reconnect already spent this episode" without a second field or
instrumenting all five teardown routes.

One consumed shape is a dead end rather than a recovery, and is the one case the repair still acts
on. A `preserveRunID: true` reconnect can retire the controller while its follow-up
`ensureCodexNativeSession` fails, leaving an established run with no provider at all: nothing will
ever publish a healed catalog for that run, so the established-run gate keeps failing closed forever.
When the episode is consumed but `codexController == nil` and `runID != nil`, the repair retires the
run identity through the same host-authoritative reset the pending path uses, clears the marker, and
re-drives — no second controller replacement.

**Opening happens in the projection reconciler**, which is the only frame where the mismatch and the
storage that produced it are visible in one synchronous MainActor step; writing the marker before
calling the coordinator is what makes the open atomic against a nested publication.
`projection.isReady` is deliberately not used — the state being recognized is intentionally unready.

What the publish guard proves is *identity*, not route currency: the projection carries a route token
naming this tab's current endpoint, for this session object's current run, at a revision no lower than
the stored one. It does not prove the observing connection still owns the authoritative route when the
repair actually runs; only `hasCurrentRunCatalogRouteTokenInCurrentMCPServer` proves that, and it
additionally demands the positive catalog presence this state by definition lacks. The accepted bound
is therefore that a projection may already be one connection generation stale by the time the repair
runs, costing one controller replacement on a session that was going to reconnect anyway — bounded by
the episode marker, and no more accurate than an authority round trip that can go stale the same way.

An episode is closed by exactly five paths, all of which mean it is *over* rather than spent:

| Close path | Where |
| --- | --- |
| Exact current positive catalog (`hasAgentSessionLink == true`) | projection reconciler |
| Exact outbound loss (`hasActiveOutboundLink == false`) | projection reconciler |
| Provider switch away from `.codexExec` | `handleProviderSwitch` |
| `agent_session_link` disabled when the episode is spent | repair entrypoint |
| Stranded consumed run (`codexController == nil`, `runID != nil`) after its retirement | repair entrypoint |

An unknown observation closes nothing and leaves the episode open, because it is not evidence that
anything healed.

**The repair retires the process run** (`invalidateCodexControllerForReconnect(… preserveRunID: false)`)
and that is the point rather than a side effect. `codexConversationID` and `codexRolloutPath` are
deliberately untouched, so the next start resumes the same Codex conversation while `runID == nil`
lets the cold-bootstrap exception admit the *already published* passive snapshot. Preserving the run
instead would leave the same false projection gating admission with no way to reach a successor
catalog short of a route-successor protocol, which this design exists to avoid. Late completions from
the retired route stay safe through the existing `session.runID == projection.runID` publish guard and
`completeRunCatalogObservation`'s ownership rule.

**Quiescence is mandatory, not advisory.** Invalidation deliberately abandons the fallback queue with
the controller, so repairing under fallback ownership would drop the user's queued text; a terminal
commit that has staged its revision but not finished publishing still owns the run; and a wake in
`.preparingDispatch`, `.cancelledBeforeDispatch`, or `.dispatching` owns the same transport boundary
the tombstone fences. A blocked episode is simply left pending — no task, timer, queue, or new phase —
for the next projection reconciliation or the next winning terminal commit.

**Enablement is re-sampled at spend time, not inherited from the open.** An episode opened while
`agent_session_link` was enabled can be spent much later at a terminal commit that never passes
through the reconciler's own gate. Once the tool is disabled the absent catalog is truthful, so the
episode closes and nothing reconnects.

**Terminal ordering is load-bearing.** In `finalizeCodexRun.postCommit` the repair runs *after*
`settleCodexComputerUseActivationAfterTurn`, so a computer-use replacement rotates the generation
first and the two coalesce into the episode's one replacement; and *before*
`scheduleCodexIdleShutdownIfNeeded`, so shutdown is never armed against a controller about to be
retired. It is deliberately **not** gated on `providerSuccessor == nil`: a successor that is still
accepted or retryable *is* the fallback queue head, which the fallback-ownership guard already
refuses, while a stale or permanently rejected successor leaves no queue behind and gating on its
mere presence would strand the episode on a session with nothing left to re-drive it.

The accepted cost is that a healthy idle controller may be recycled during the transient interval
before a compliant client processes `list_changed`. That is bounded at one replacement per episode,
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
server projection publication, host projection acceptance or rejection, repair episode open/close and
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
