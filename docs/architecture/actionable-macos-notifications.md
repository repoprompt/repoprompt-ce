# Actionable macOS Notifications — Design

Status: **Implemented** (phases A–D plus the Phase E MCP `ask_user` opt-in). Section 12 records the
decisions taken during review; section 11 lists what was built and what is deferred.
Owner areas: `Sources/RepoPrompt/App/Notifications`, `Sources/RepoPrompt/Features/AgentMode`, `Sources/RepoPrompt/Features/Settings`

Section 2 is the pre-implementation survey and describes the code as it was before this work.

## 1. Goals and non-goals

Goals:

1. Notify when an Agent Mode session is **blocked on the user**: approvals, questions, structured input, reviews, and "waiting for next instruction". Today most of these states send no notification.
2. Let the user **answer simple choices from the notification**, such as Approve or Decline for a fully visible, low-risk command, a single-choice `ask_user` question, or a short text reply. Resolution must go through the same code path as the in-app card. An answer from a notification must never be weaker than one from the UI.
3. Clicking a notification opens the **exact workspace, window, tab, and agent session** and scrolls to the pending card. This includes a cold launch, where the click is what starts the app.
4. Manage the notification lifecycle: group by session, replace instead of stacking, retract a notification when its interaction resolves anywhere, suppress it when the session is already on screen, and badge the Dock with the count of pending requests.
5. Add settings: per-category toggles, a default for actionable approvals, and integration with the existing Settings UI and `app_settings` MCP surface.
6. Make the stack testable by putting a protocol seam over `UNUserNotificationCenter` and moving the decision logic into pure policy types.

Non-goals (v1):

- No notification content extensions or custom notification UI. macOS cannot host a custom UI extension for this app bundle shape without an app extension target.
- No remote or push notifications.
- Approving file-change diffs, apply-edits reviews, worktree merges, hook trust, permission grants, or MCP elicitations from a notification. These stay **Open-only** because they need the full review surface.
- Persisting pending interactions across relaunch. Runs do not survive a process restart, so an interaction from a previous launch is stale by definition.

## 2. Current state (survey)

### 2.1 Stack

| Piece | Location | Notes |
|---|---|---|
| `NotificationService` (`@MainActor`, singleton, `UNUserNotificationCenterDelegate`) | `App/Notifications/NotificationService.swift` | Builds four notification kinds. Every request id is `UUID().uuidString`. There are no categories, actions, or `threadIdentifier`s. |
| Authorization | `AppDelegate.applicationDidFinishLaunching` → `Task { await NotificationService.shared.requestAuthorization() }` | Skipped when `launchConfiguration.suppressesNonessentialLaunchSideEffects`. |
| Delegate install | Lazy `center` getter in `NotificationService` sets `center.delegate = self` | Runs only on first access, inside an async `Task` after launch. |
| Click routing | `NotificationService.userNotificationCenter(_:didReceive:…)` → `AgentSessionDeepLinkRoute.parse(notificationUserInfo:)` → `AppDeepLinkRouter.route(notificationRoute:)` | Only one route kind exists (`agent_session`, route v1). |
| Route model | `App/AppDeepLinkRoute.swift` (`AgentSessionDeepLinkRoute`: `windowID?`, `workspaceID`, `tabID`, `sessionID?`; userInfo keys `rp_route_kind`, `rp_route_version`, `window_id`, `workspace_id`, `tab_id`, `session_id`) | The same route also has a `repoprompt-ce://agent/session?...` URL form. |
| Router | `App/AppDeepLinkRouter.swift` → `WindowState.routeToAgentSession(_:)` (`App/WindowState.swift` ~1621) | Tries preferred windows, then fallback windows. Switches workspace if needed, restores a stashed tab, and hydrates the session via `AgentModeViewModel.activateRoutedAgentSession`. |
| Foreground behavior | `willPresent` → `completionHandler([])` | Nothing is ever shown while the app is active. The `notify*` methods also return early when `NSApp.isActive`. |

### 2.2 Current triggers

| Trigger | Call site | Route? |
|---|---|---|
| Chat complete | `Features/Chat/ViewModels/Oracle/OracleViewModel.swift:3479` | No |
| Context Builder complete | `Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift:4888` | No |
| Agent turn complete | `AgentRunTerminalCommitBarrier` (`request.notifyTurnComplete`) → hooks → `AgentModeViewModel.notifyAgentTurnComplete(for:)` (~20297) | Yes |
| Agent waiting for instruction | `AgentModeViewModel` ~19618 (instruction wait only) | Yes |

### 2.3 Pending-interaction model (what a notification must represent)

Everything lives on `AgentTabSession` (`Features/AgentMode/ViewModels/AgentTabSession.swift` ~150–200), with one `AgentModeViewModel` per `WindowState`, keyed by `tabID`:

| State | Set by | UI resolve API | MCP `respond` kind |
|---|---|---|---|
| `pendingApproval: AgentApprovalRequest` (`.commandExecution`, `.fileChange`; request id `.codex` / `.claudeControl` / `.acp`) | Codex `CodexAgentModeCoordinator` ~8552, Claude runner `ClaudeIntegratedAgentModeRunner` ~297, ACP runner ~1053 | `submitApprovalDecision(tabID:decision:)` (`AgentModeViewModel+InteractionActions.swift`). **Not id-checked.** | `approval` |
| `pendingPermissionsRequest` (Codex) | Codex ~8560 | `codexCoordinator.submitPermissionsDecision` (id-checked) | `approval` |
| `pendingMCPElicitationRequest` (+ queue) | Codex ~8572 | `submitMCPElicitationResponse(tabID:requestID:response:)` | `mcpElicitation` |
| `pendingUserInputRequest` (+ queue; questions may be `isSecret`) | Codex ~8596 | `submitUserInputResponse(tabID:requestID:response:)` | `userInput` |
| `pendingAskUser: AgentAskUserPendingState` | `AgentModeViewModel` ~19809+ (ask_user tool) | `submitAskUserResponse(tabID:interactionID:draftsByQuestionID:)`, `skipAskUser` | `question` |
| `pendingCodexHookReview` | Codex ~739–1190 | `submitCodexHookReviewDecision` (id-checked, async) | `hookApproval` |
| `pendingApplyEditsReview` | `AgentModeViewModel` ~4808 | `submitApplyEditsReviewDecision(tabID:reviewID:decision:)` | n/a |
| `pendingWorktreeMergeReview` | `AgentModeViewModel+WorktreeMerge.swift` ~715 | `submitWorktreeMergeReviewDecision` | `approval` |
| `waitingPrompt` + `instructionContinuation` (`runState == .waitingForUser`) | `AgentModeViewModel` ~19605 | Composer submit → `resumeWaitingInstructionContinuation` (~19691) | `instruction` |

Two existing pieces are especially useful:

- `mcpResolvePendingInteraction(sessionID:interactionID:payload:)` (`AgentModeViewModel.swift` ~10698) is already a single, id-checked, kind-dispatched resolver. It validates that the interaction is still current before doing anything. The notification path should follow the same shape, but it must not require `mcpControlledSession`.
- `session.monitorReadinessChangePublisher` (`AgentTabSession.swift`) already merges every pending-state publisher plus `runState`. It is a ready-made, level-triggered observation channel for "attention state changed".

Visibility inputs that already exist: `WindowState.isCurrentlyFocused` (`@Published`; `NSApp.isActive && window.isKeyWindow`), `AgentModeViewModel.isAgentModeActive` (private, set via `setAgentModeActive`), `AgentModeViewModel.currentTabID`, and `session.activeAgentSessionID`.

In-app cards render at the transcript bottom with stable ids: `"pendingApproval"`, `"pendingAskUser"`, `"pendingUserInputRequest"`, `"pendingMCPElicitation"`, `"pendingApplyEditsReview"`, `"pendingWorktreeMergeReview"` (`AgentModeView.swift` ~2440–2560). This gives routing a deterministic scroll target.

Workspace switching discards the previous workspace's live sessions (`WorkspaceSwitchSessionProvider`). A **live pending interaction therefore always lives in the active workspace of exactly one window**. That simplifies action routing, and it means an action handler must never trigger a workspace switch.

### 2.4 Gaps and defects found

1. **The blocking states are silent.** Approvals, permissions, elicitation, structured input, `ask_user`, hook review, apply-edits review, and merge review post nothing. Only the plain "waiting for instruction" state notifies.
2. **Failures are silent.** `notifyTurnComplete` is true only for `.completed` outcomes (Claude runner ~231, ACP ~1151, Headless ~253).
3. **Notifications accumulate.** Random request ids, no `threadIdentifier`, and no removal mean stale "needs input" notifications stay in Notification Center after the user answers in-app.
4. **Cold-launch clicks can be lost.** The delegate is installed lazily inside an async task, and not at all in suppressed-launch configurations. Apple requires the delegate to be set before `applicationDidFinishLaunching` returns.
5. **A click with no live window is dropped.** `routeAgentSession(_:sourceURL:)` queues into `WindowStatesManager.pendingURLs` only when `sourceURL != nil`, and the notification path passes `nil`. This is codified for in-app routing by `testInAppAgentSessionRouteReturnsResultWithoutQueueingURL`. A cold launch, or a click while every window is backgrounded through `MCPBackgroundModeCoordinator`, just activates the app.
6. **Some sessions get no route.** `agentNotificationRoute(forTabID:)` returns `nil` when the tab is not in `workspaceManager.activeWorkspace`.
7. **Suppression is app-level only.** It checks `NSApp.isActive` without knowing whether *this* session is on screen, and `willPresent` always returns `[]`.
8. **`suppressUserNotifications` is dead.** It is set to `true` for MCP-controlled runs (`AgentModeViewModel.swift` ~9397) but never read. Sessions driven by `agent_run` notify exactly like user sessions, even though the orchestrator answers their interactions through `respond`.
9. **`submitApprovalDecision(tabID:decision:)` does not check the request id.** In the UI the race window is milliseconds. For a notification it can be minutes, and a newer approval could receive a decision meant for an older one.
10. **Other attention states never notify.** These are the Context Builder `ask_user`, the window-level MCP `ask_user` tool (`MCPAskUserToolProvider`, which instead *activates the app and steals focus* for non-MCP-controlled tabs), MCP `manage_workspaces` approvals (`WorkspaceApprovalManager`, 300 s deadline), and MCP client connection approvals (`ServerController`).
11. **There are no notification settings, no badge, and no visible authorization status.**

## 3. Architecture overview

```
 AgentTabSession (@Published pending*, runState)
        │  monitorReadinessChangePublisher (per session)
        ▼
 AgentModeViewModel+AttentionNotifications   (per window; builds [AgentAttentionState])
        │  update(windowID:, states:)  (coalesced)
        ▼
 AgentNotificationCoordinator (@MainActor)   ── reads ── NotificationPreferences, SessionVisibilityProviding
        │  pure: AgentNotificationPlanner.plan(previous, current, visibility, prefs) -> [NotificationCommand]
        ▼
 UserNotificationCenterClient (protocol)  ── live ── UNUserNotificationCenter
        ▲                                   └─ fake ── FakeUserNotificationCenter (tests)
        │  delegate callbacks
 NotificationService (delegate, installed in applicationWillFinishLaunching)
        │  AppNotificationResponse (Sendable, parsed off-main)
        ▼
 AppNotificationResponseHandler (@MainActor)
        ├─ open  → AppDeepLinkRouter.route(notificationRoute:) → WindowState.routeToAgentSession → reveal card
        └─ act   → find owning window → AgentModeViewModel.resolveNotificationAction(...) → same submit* APIs as the UI
```

Key principles:

- **Level-triggered reconciliation, not edge-triggered posting.** Nothing calls "post approval notification" from the eight provider code paths. The coordinator diffs *desired* notifications, derived from live session state, against *delivered* ones. Resolving an interaction anywhere (UI, `agent_run respond`, timeout, cancel, auto-approve, window close, workspace switch) therefore retracts its notification automatically.
- **The notification is a view of live state, not a capability.** An action carries identifiers and a content fingerprint only. At action time the handler re-reads the live interaction, re-checks eligibility against it, and applies the decision only if everything still matches.
- **Pure core, thin shell.** Payload encoding and decoding, eligibility, the planner, fingerprints, and visibility rules are pure, `Sendable`, and unit-tested. `UNUserNotificationCenter` sits behind one protocol.

## 4. Notification taxonomy

### 4.1 Kinds

| Kind (`rp_notification_kind`) | Trigger | Default | Sound | `relevanceScore` |
|---|---|---|---|---|
| `interaction` | A session's top-priority pending interaction (§4.3) appears or changes | On | default | 1.0 |
| `turn_failed` | Terminal commit with a failed or error outcome (not user-cancelled) | On | default | 0.7 |
| `turn_complete` | Terminal commit `.completed` (existing hook) | On | default | 0.4 |
| `chat_complete` | Existing Oracle hook | On | default | 0.3 |
| `context_builder_complete` | Existing hook | On | default | 0.3 |
| `feedback` | Result of a background action (for example "Couldn't apply — no longer pending") | Always | none | 0.2 |

`interaction` covers all blocking states, including instruction waits. The existing `notifyAgentWaitingForUser` becomes one input to the reconciler instead of a separate path.

### 4.2 Interaction kinds and their classification

`AgentPendingInteractionKind` is a new pure enum that mirrors the in-app card priority in `AgentModeView`, so the notification always matches the card the user will see:

1. `hookReview` (`pendingCodexHookReview`)
2. `applyEditsReview`
3. `worktreeMergeReview`
4. `approval` (`pendingApproval`)
5. `permissions` (`pendingPermissionsRequest`)
6. `mcpElicitation`
7. `userInput` (`pendingUserInputRequest`)
8. `askUser` (`pendingAskUser`)
9. `instruction` (`waitingPrompt` with `runState == .waitingForUser`)

Only the **single top-priority** interaction per session is notified. Queued elicitations and user-input requests surface only after they are promoted to pending, and the reconciler handles that naturally.

### 4.3 What counts as a "simple choice" (actionable) and what is Open-only

Eligibility is decided by the pure function `AgentNotificationActionEligibility.actions(for:isMCPControlled:preferences:) -> [AgentNotificationAction]` (`Features/AgentMode/Models/AgentNotificationActionEligibility.swift`). Anything not explicitly eligible gets the **Open-only** set (default click plus "Review…").

Global gates that apply before the table: notifications disabled, or a session driven by an orchestrating agent (`agent_run`, `isMCPControlled`), always yield Open-only — including Decline, so a user never races the orchestrator's `respond`. Decline requires "Approve from notifications" **or** "Answer from notifications"; option buttons, Skip, and Reply require "Answer from notifications". For Claude approvals that name a tool, Approve additionally requires a shell tool (`Bash`), so a non-shell tool's `command` field is never approved from a banner.

| Interaction | Actionable when **all** conditions hold | Actions offered | Otherwise |
|---|---|---|---|
| `approval`, `.commandExecution` | "Approve from notifications" preference is on. "Show details in notifications" is on. `command` is non-empty, a **single line**, and **≤ 160 characters**, so the notification body shows it **verbatim with no truncation** ("what you see is what you approve"). The command matches no high-risk pattern (§7.3). The session is not MCP-controlled. | **Approve**, **Decline**, **Review…** | Decline and Review… (Decline is always safe) |
| `approval`, `.fileChange` | never | Decline and Review… | — |
| `permissions` (Codex sandbox grants) | never | Decline and Review… | — |
| `askUser` | Exactly **1 question**, `allowsMultiple == false`, **1–4 options**, every label ≤ 40 characters, no duplicate labels after trimming | One button per option (`choice.<i>`). Plus **Reply…** (text input) if `allowsCustom`. Plus **Skip**. Plus Review…. | Review… only |
| `askUser` (free text) | Exactly 1 question, **0 options**, `allowsCustom` | **Reply…** (text input), **Skip**, Review… | Review… only |
| `userInput` (Codex `request_user_input`) | Exactly 1 question, **not `isSecret`**, 1–4 options with labels ≤ 40 characters | Option buttons, plus Reply… if `isOtherOptionEnabled` (maps to the note), Review… | Review… only |
| `instruction` (waiting for next instruction) | always | **Reply…** (text input), Review… | — |
| `mcpElicitation` | never (schema-driven content) | Review… | — |
| `hookReview`, `applyEditsReview`, `worktreeMergeReview` | never | Review… | — |
| `turn_complete` | "Reply from completion notifications" preference is on | **Reply…** (sends a follow-up turn), Open | Open |
| `turn_failed` | never | Open | — |

Deliberately excluded in v1:

- **"Always allow" / `acceptForSession` / `acceptWithExecpolicyAmendment`.** These mutate standing policy and should be chosen with full context. They are Open-only.
- **"Cancel run".** It is destructive and rarely the intent from a banner.
- **Multi-select or multi-question wizards.** They cannot be represented faithfully.

### 4.4 Categories and actions

Action identifiers are stable constants in `AppNotificationActionID`:

| Action id | Title | `UNNotificationActionOptions` |
|---|---|---|
| `UNNotificationDefaultActionIdentifier` | (click) | — → Open |
| `rp.action.review` | "Review…" | `.foreground` |
| `rp.action.approve` | "Approve" | `.authenticationRequired` (no `.foreground`; resolved in background) |
| `rp.action.decline` | "Decline" | `.destructive` |
| `rp.action.skip` | "Skip" | — |
| `rp.action.choice.0` … `rp.action.choice.3` | option label | — |
| `rp.action.reply` | "Reply…" (`UNTextInputNotificationAction`, button "Send", placeholder "Reply to agent…") | — |

`.authenticationRequired` has no effect on macOS today, but it is harmless and documents intent. It would carry over if the flow is ever ported.

Categories:

| Category id | Actions | Registration |
|---|---|---|
| `rp.agent.actions.approve+decline+review` | Approve, Decline, Review… | Static |
| `rp.agent.actions.decline+review` | Decline, Review… | Static |
| `rp.agent.actions.review` | Review… | Static |
| `rp.agent.actions.reply+review` | Reply…, Review… | Static |
| `rp.agent.actions.reply+skip+review` | Reply…, Skip, Review… | Static |
| `rp.agent.actions.reply+open` | Reply…, Open (turn complete, opt-in) | Static |
| (none) | Turn failed, Chat, Context Builder, feedback: click opens | — |
| `rp.agent.choice.<interactionID>` | `choice.i` titled with the option labels, plus Reply…, Skip, Review… as eligible | **Dynamic** |

Non-choice category identifiers are derived deterministically from the ordered action list (`AgentNotificationAction.category(for:interactionID:)`), and every list the policy can produce is registered at launch (`AgentNotificationAction.staticActionLists`).

Choice labels differ per notification, and `UNNotificationAction` titles are fixed per category, so choice questions need a **dynamic category per interaction**. `NotificationCategoryRegistry` handles this:

- It keeps `static ∪ dynamic` in memory and always calls `setNotificationCategories` with the full union, because the API replaces the whole set.
- It serializes registration, then awaits a `notificationCategories()` round-trip before calling `add`. This works around the known race where a request added right after registration shows no actions.
- It prunes dynamic categories whose interaction is no longer desired, capped at 32. On overflow it falls back to the Open-only category.
- At launch it re-registers the static set only, which drops all dynamic categories from previous launches.

## 5. Payload (`userInfo`) schema

Payload v2 is backward compatible and keeps all route v1 keys unchanged, so `AgentSessionDeepLinkRoute.parse(notificationUserInfo:)` keeps working and older delivered notifications still route.

```text
# Route (unchanged, route version stays 1)
rp_route_kind        = "agent_session"
rp_route_version     = 1
workspace_id         = UUID string         (required)
tab_id               = UUID string         (required)
session_id           = UUID string         (optional)
window_id            = Int                 (optional hint; not stable across launches)

# New (payload version 2)
rp_payload_version   = 2
rp_notification_kind = "interaction" | "turn_complete" | "turn_failed" | "chat_complete"
                       | "context_builder_complete" | "feedback"
rp_launch_id         = UUID string         (process-launch identity; see §7.2)
interaction_id       = UUID string         (interaction kind only)
interaction_kind     = "approval" | "permissions" | "ask_user" | "user_input" | "mcp_elicitation"
                       | "hook_review" | "apply_edits_review" | "worktree_merge_review" | "instruction"
interaction_fp       = 32-hex (first 16 bytes of SHA-256 over the canonical displayed content, §7.4)
choice_count         = Int                 (choice interactions; action index bound check)
turn_marker          = String              (turn_complete only; transcript turn count + latest user row id)
posted_at            = Double (unix seconds)
```

Types (new file `App/Notifications/AppNotificationPayload.swift`):

- `struct AppNotificationPayload: Sendable, Equatable` holds `route: AgentSessionDeepLinkRoute?`, `kind`, `launchID`, `interaction: InteractionRef?` (`id`, `kind`, `fingerprint`, `choiceCount`), and `postedAt`.
- `var userInfo: [AnyHashable: Any]` and `static func parse(_ userInfo: [AnyHashable: Any]) -> AppNotificationPayload?` reuse the existing tolerant `String`/`NSString`/`NSNumber` key and value readers from `AppDeepLinkRoute.swift`. Those readers get hoisted into a shared `NotificationUserInfoReader`.
- Unknown `rp_payload_version > 2` values parse the route only, degrading to Open. A missing payload version means v1 and is treated as Open.

`AgentSessionDeepLinkRoute` gains an optional `interactionID: UUID?` (URL query item `interaction_id`) so a URL or click can request "reveal this card". Absent means today's behavior.

Request, thread, and summary identifiers:

| Notification | `request.identifier` | `threadIdentifier` | Replaces |
|---|---|---|---|
| Interaction | `rp.agent.interaction.<interactionID>` | `rp.agent.session.<sessionID ?? tabID>` | Same interaction (content update) |
| Turn complete | `rp.agent.turn.<tabID>` | same thread | Previous completion for that tab |
| Turn failed | `rp.agent.failure.<tabID>` | same thread | Previous failure for that tab |
| Feedback | `rp.feedback.<interactionID>` | same thread | — |
| Chat / Context Builder | `rp.chat.<tabID>` / `rp.cb.<tabID>` (tab id if available, else UUID) | `rp.compose.<tabID>` | Previous for that tab |

`summaryArgument` is the session display name. `targetContentIdentifier` is the route URL string.

## 6. Deep-link routing on click

### 6.1 Flow

1. `NotificationService.userNotificationCenter(_:didReceive:) async` (nonisolated) extracts `AppNotificationResponse { requestIdentifier, actionIdentifier, userText?, payload?, route? }` **before** hopping to the main actor. `UNNotificationResponse` and `userInfo` are not `Sendable`.
2. `AppNotificationResponseHandler.handle(_:)` (`@MainActor`) routes default click, `rp.action.review`, and any action that downgrades (stale or ineligible) to `open(payload)`.
3. `open`:
   - With no route, `NSApp.activate` only.
   - With **no live windows**, which includes cold launch and background mode, it calls `MCPBackgroundModeCoordinator.shared.restore()` if the app is backgrounded. Otherwise it **enqueues `route.url`** in `WindowStatesManager.pendingURLs`. `registerWindowState` already drains `pendingURLs` through `AppDeepLinkRouter.route(url:)` after window restore, which fixes gap 5. The in-app `route(agentSession:)` keeps its no-queue contract. The notification path uses a new `route(notificationRoute:)` behavior that queues.
   - Otherwise it calls `AppDeepLinkRouter.route(agentSession:)`, which already handles window preference, workspace switch, stashed-tab restore, and session hydration.
4. When the route carries an `interactionID`, `WindowState.routeToAgentSession` finishes by calling `agentModeViewModel.revealPendingNotificationInteraction(tabID:)`, which publishes a one-shot reveal request. `AgentModeView` pins that tab's transcript to its live bottom, where every pending card renders (`"pendingApproval"`, `"pendingAskUser"`, …), so the card is on screen and Return triggers its prominent button as today. The same path runs for URLs drained from `pendingURLs` after a cold launch, because `interaction_id` is part of the route URL. (Deferred: an in-app "already handled" toast when the interaction resolved before the click.)
5. On non-`.routed` results (`sessionUnavailable`, `tabUnavailable`, `workspaceSwitchBlocked(message)`), activate the best window and surface the existing workspace-switch-blocked notice where applicable. Never switch workspaces behind the user's back while a run is active; `requestWorkspaceSwitch` already enforces this.

### 6.2 Cold launch

- **Install the delegate early.** Add `AppDelegate.applicationWillFinishLaunching` → `NotificationService.shared.installDelegate()`, which synchronously sets `UNUserNotificationCenter.current().delegate` when running from a `.app` bundle. This runs even under `suppressesNonessentialLaunchSideEffects`; only the *authorization prompt* stays suppressed.
- **Register static categories at the same point.**
- A response that arrives before any window exists is handled as in §6.1 step 3. The queued URL is drained once the restored window registers, and `routeToAgentSession` already awaits `workspaceManager.awaitInitialized()`.
- **Launch sweep.** Once the delegate and categories are installed, remove every delivered `interaction`, `turn_*`, and `feedback` notification whose `rp_launch_id != currentLaunchID`. The launch that is processing the click keeps that response in memory, so removal does not affect it. Stale interaction notifications from a previous process disappear instead of offering dead buttons.

## 7. Action handling

### 7.1 Resolution path

`AppNotificationResponseHandler.act(response)`:

1. **Launch fence.** If `payload.launchID != currentLaunchID`, the action is stale (§7.2).
2. **Locate the owner window.** `WindowStatesManager.shared.allWindows.first { !$0.isClosing && $0.workspaceManager.activeWorkspaceID == route.workspaceID && $0.agentModeViewModel.sessions[route.tabID] != nil }`. The `window_id` hint is tried first. Any action that would require a workspace switch is stale.
3. Call `agentModeViewModel.resolveNotificationAction(_ request: AgentNotificationActionRequest) async -> AgentNotificationActionOutcome`. This is a new method in `Features/AgentMode/ViewModels/AgentModeViewModel+NotificationActions.swift`:
   - Re-derive the **live** top-priority interaction with the same `AgentPendingInteractionDescriptor.make(from:)` the planner uses.
   - Require `live.id == request.interactionID`, `live.kind == request.kind`, and `live.fingerprint == request.fingerprint`. Otherwise return `.stale`.
   - Re-run `AgentNotificationActionEligibility.evaluate` against the live interaction and **current** preferences. If the requested action is not in the live action set, return `.ineligible`. This covers the user disabling "Approve from notifications" after the banner was posted.
   - Dispatch to the **existing UI APIs**, never to provider controllers directly:
     - approve / decline → `submitApprovalDecision(tabID:requestID:decision:)`, a **new id-checked overload**. The UI card switches to it as well, which fixes gap 9. The old signature forwards to the new one with the current id and is kept for tests.
     - `permissions` decline → `codexCoordinator.submitPermissionsDecision(session:request:.decline)`.
     - choice.i / skip / reply for `askUser` → build `AgentAskUserDraft` (option or custom) → `submitAskUserResponse(tabID:interactionID:draftsByQuestionID:)` / `skipAskUser`. Validation errors return `.invalidInput`.
     - choice.i / reply for `userInput` → `AgentRequestUserInputResponse` → `submitUserInputResponse(tabID:requestID:response:)`.
     - reply for `instruction` or `turn_complete` → the composer submit path, `submitUserTurn(text:tabID:…)`. That path handles decoration, token accounting, session-link claims, and the waiting-continuation resume (`resumeWaitingInstructionContinuation`). A notification reply is therefore indistinguishable from typing in the composer.
   - Call `handleObservedMCPStateChange` / `publishRunInteractionStateChange` exactly as the current resolvers do. The id-checked resolvers already do this internally.
4. Outcomes:
   - `.applied`: the reconciler retracts the notification on the next state change. No feedback notification.
   - `.stale`, `.ineligible`, `.windowUnavailable`: post a `feedback` notification in the same thread, such as "Couldn't apply 'Approve' — the request is no longer pending" (or "…needs review in RepoPrompt"), with Open. **Never apply a different decision.** Never auto-open the app for a background action.
   - `.invalidInput` (for example an empty reply): feedback "Reply was empty — nothing sent."

### 7.2 Idempotency and staleness

- **Single consumption.** Every resolver clears the pending state synchronously on the main actor before the async provider response. A second attempt through the notification, the UI, or `respond` fails the id or fingerprint match and becomes `.stale`. There is no separate "handled" set; live state is the only source of truth.
- **Launch fence.** `rp_launch_id` means an action from a notification posted by a previous process can never resolve anything. A newly relaunched app could theoretically reuse a stable id, because approval ids are derived from provider request ids plus thread/turn/item ids.
- **Session ended, tab closed, or workspace switched.** The owner window is not found, or the session has no pending interaction, so the result is `.stale`.
- **Content changed under the same id.** The fingerprint mismatch makes it `.stale`.
- **Reply on an older turn-complete notification.** The payload's `turn_marker` must equal the live `AgentNotificationTurnMarker`, the run must be idle, and no interaction may be pending; otherwise `.stale`.
- **Timed-out `ask_user` or instruction.** Pending state is cleared, so it is `.stale`, and the reconciler has already retracted the notification.

### 7.3 Security policy

A notification is a *weaker* context than the in-app card: it is smaller, possibly truncated, easy to click by accident, and shown on shared screens. The rule is **the notification path must be at least as strict as the UI, and stricter where visibility is reduced**:

1. **What you see is what you approve.** Approve is offered only when the full, untruncated command is in the notification body, and the fingerprint binds the action to exactly that text.
2. **Decline fails closed.** It is offered whenever responding from notifications is enabled at all (not for agent-driven sessions).
3. **Only one-shot scope.** Nothing that expands standing policy (always allow, session grant, execpolicy amendment, hook trust, permissions grant) can be chosen from a notification.
4. **High-risk demotion (heuristic, demote-only).** `AgentNotificationCommandRiskClassifier` marks a command high-risk if it matches any of the following: `sudo`; `rm` with `-r`/`-f`; `git push` with `--force`/`-f`/`--mirror`/`--delete`; `git reset --hard`; `git clean -f`; `git checkout --`/`git restore` over paths; `dd`, `mkfs`, `diskutil`; `chmod`/`chown -R`; `curl … | sh`/`bash`; `eval`; `>` into a path outside the working directory; `launchctl`; `security`; `defaults write`; `kill -9`. It also matches anything with command chaining (`;`, `&&`, `||`, `|`, backticks, `$(`) that the classifier cannot fully parse. High-risk commands get Decline and Review… only. The classifier can only *remove* Approve, never add it, so its false negatives fall back to the other gates and its false positives just cost a click.
5. **MCP-controlled sessions** (`isMCPControlled(tabID:)`) are Open-only. The orchestrating agent owns `respond`, and a user acting on the same interaction would race it.
6. **Preferences are re-checked at action time** (§7.1). Turning off "Approve from notifications" takes effect for banners already on screen.
7. **Privacy.** With "Show details in notifications" off, the body shows only generic text ("Needs your approval"), and Approve is never offered because of rule 1.
8. **Telemetry** (deferred). Tagging approval telemetry with `source = notification` is a follow-up; the id-checked submit path is shared with the UI either way.

Requiring Touch ID or a password before a notification approve was considered and rejected for v1. macOS offers no notification-level authentication, and presenting `LAContext` from a background action would activate the app, which defeats the purpose. Users who want that friction can disable "Approve from notifications", which removes Approve from every notification. (Decided: no Touch ID; §12.)

### 7.4 Fingerprint

`AgentPendingInteractionDescriptor.fingerprint` is SHA-256 over a canonical, newline-joined tuple: `kind`, `interactionID`, `title`, the displayed body text (the command verbatim for approvals), and option labels in order. It uses the `StableUserInteractionIdentity`-style CryptoKit helper already in `UserInteractionModels.swift`. It is computed identically when posting and when acting.

### 7.5 Concurrency (Swift 6)

- `NotificationService` stays `@MainActor`. Its delegate methods are `nonisolated` and use the **async** delegate variants (`didReceive response: async`, `willPresent: async -> UNNotificationPresentationOptions`), so the system waits for handling and no completion handler crosses isolation.
- All response parsing (`AppNotificationResponse.init(response:)`) happens in the nonisolated context. Only `Sendable` values cross to the main actor.
- `UserNotificationCenterClient` is `@MainActor` and exposes async methods that take and return `Sendable` value types (`NotificationRequestSpec`, `DeliveredNotificationSummary`, `NotificationCategorySpec`). The live adapter builds `UN*` objects internally. `UNMutableNotificationContent` never escapes it.
- `AgentNotificationCoordinator` is `@MainActor`. It serializes posting through one task chain: category registration, then `add`, then a record of the result. Updates that arrive mid-flight are coalesced, and the latest desired state wins.
- There is no `DispatchQueue` and no `@unchecked Sendable` except the adapter's retained `UNUserNotificationCenter`. That instance is MainActor-confined, so the conformance is justified in a comment.

## 8. Lifecycle

### 8.1 Posting and retraction (reconciler)

Per window, `AgentModeViewModel+AttentionNotifications` subscribes to each live session's `monitorReadinessChangePublisher`. It attaches and detaches in the `sessions` `didSet`, which is already the single hook for session add and remove. On change it builds `[AgentAttentionState]`:

```swift
struct AgentAttentionState: Sendable, Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID?
    let sessionName: String
    let isMCPControlled: Bool
    let interaction: AgentPendingInteractionDescriptor?   // top-priority only
}
```

It then calls `AgentNotificationCoordinator.update(windowID:states:)`.

The coordinator runs the pure `AgentNotificationPlanner.plan(previous:current:visibility:preferences:now:)` and gets back `[NotificationCommand]` (`post(spec)`, `remove(ids)`, `setBadge(n)`):

- **New interaction.** After a **1.0 s grace delay**, post it if it is still desired. This absorbs interactions that are auto-resolved immediately, such as the ACP auto-approve paths in `AgentModeProviderBindingService` ~220/235 or `ask_user` answered through `respond` by an orchestrator.
- **Same id, different fingerprint** (for example a queued item promoted under the same id). Re-post with the same identifier, which replaces it in place.
- **Delivery bookkeeping.** A request is recorded as delivered only after `add` succeeds, so a failed add is retried on the next pass. Turn-complete/failed posts are queued into the same serialized pass, so a retraction decided in that pass (the tab became visible or now asks for input) always wins. The launch sweep clears the badge and then schedules a pass to recompute it.
- **Interaction gone.** Remove the delivered notification and any pending one, and prune its dynamic category.
- **Window closed.** `WindowState` teardown calls `coordinator.removeWindow(windowID)`, which retracts everything that window owned.
- **Workspace switch or tab close.** The sessions dictionary changes, so the states disappear and the notifications are retracted.
- **Turn complete / failed** are edge-triggered from the terminal commit hook, as today. They go through the coordinator for suppression, identifiers, and threads. Posting a new interaction for a tab removes that tab's `turn_complete`, so the "done" and "needs input" banners do not contradict each other.

### 8.2 Suppression (visibility)

`SessionVisibilityProviding` is implemented by the App layer over `WindowStatesManager`. A session is **visible** when all of the following hold for its owning window:

`NSApp.isActive && window.isCurrentlyFocused && agentVM.isAgentModeActive && agentVM.currentTabID == tabID && (sessionID == nil || session.activeAgentSessionID == sessionID)`.

Minimal accessors are exposed for this: `isAgentModeActive` becomes `private(set)`, and `WindowState` gets a combined `isAgentSessionVisible(tabID:sessionID:)`.

| Situation | interaction | turn_complete / turn_failed |
|---|---|---|
| Session visible | Do not post. If already delivered, **remove** it (the user is looking at it). | Do not post. |
| App active, session not visible (other window, tab, or mode) | Post, and `willPresent` returns `[.banner, .list, .sound]` if the "Notify while RepoPrompt is active" preference is on (default on) | Post only if that same preference is on; default behavior for completions stays "only when inactive" (preference `completionsWhileActive`, default **off**) |
| App inactive or hidden | Post | Post |
| Session MCP-controlled | Post only if "Include agent-driven sessions" is on (default **off**). **This makes `suppressUserNotifications` real.** | Same |

Visibility changes (focus, tab switch, mode switch) trigger re-planning, so a delivered notification is retracted as soon as the user navigates to the session by other means.

`willPresent` consults the coordinator's latest visibility snapshot for the notification's route. The app is active in that case, so visibility is deterministic.

### 8.3 Grouping

- `threadIdentifier = rp.agent.session.<sessionID ?? tabID>`: all notifications for one session collapse into one stack.
- `summaryArgument = sessionName`, which gives summaries like "3 more notifications from *Refactor auth*".
- At most one live `interaction` notification per session, because only the top-priority one is shown.

### 8.4 Badge

- The badge count is the number of sessions with a live pending interaction across all windows (not delivered notifications), excluding MCP-controlled sessions unless included.
- It is applied through `UNUserNotificationCenter.setBadgeCount(_:)` (macOS 13+; the package targets macOS 14), which honors the user's badge permission. It falls back to `NSApp.dockTile.badgeLabel` only if `setBadgeCount` fails.
- It is cleared on launch sweep and termination (`applicationShouldTerminate` path).
- Preference "Show pending count on Dock icon" defaults to on.

### 8.5 Authorization

- Keep requesting `[.alert, .sound, .badge]` at launch as today. Track the status reactively: re-read `notificationSettings()` on `NSApplication.didBecomeActiveNotification`, because the user may change it in System Settings.
- If not authorized, actionable features degrade to the existing dock bounce (`requestUserAttention(.informationalRequest)` for completions, `.criticalRequest` for interactions). The badge still works.
- Settings shows the status plus an "Open System Settings…" button (`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle id>`).

## 9. Settings

### 9.1 Model

The preferences live in an additive `scalarPreferences.notifications` group (`GlobalScalarPreferences.NotificationSettings` in `Features/Settings/Models/GlobalSettingsDocument.swift`). Every field is optional; `nil` means "product default", resolved by `NotificationSettings.resolved()` into the `NotificationPreferences` `Sendable` snapshot (`App/Notifications/NotificationPreferences.swift`) that all policy code consumes.

Compatibility contract (verified by `NotificationSettingsPersistenceTests`):

- **No schema bump.** The group does not participate in `requiredSchemaVersion`, so a document whose only new content is this group is still stamped baseline v2 and `currentSchemaVersion` is unchanged.
- **Missing keys decode.** Partial or absent groups decode and resolve to defaults.
- **Older builds ignore it.** `GlobalScalarPreferences` uses synthesized `Decodable`, which ignores unknown keys; the frozen v1.3.0 typed codec (`FrozenV130GlobalSettingsDocument`) loads a file containing the group. Current writers preserve unknown keys through the raw-diff save path, so a downgrade-then-upgrade keeps the user's choices unless an older build rewrites the file; the worst case is falling back to defaults.

| Field | Default | Meaning |
|---|---|---|
| `enabled` | true | Master switch for all app notifications |
| `agentInteractions` | true | Approvals, questions, input requests, reviews |
| `agentInstructionWaits` | true | "Waiting for your next instruction" |
| `agentTurnComplete` | true | Existing behavior |
| `agentTurnFailed` | true | New |
| `chatComplete` | true | Existing behavior |
| `contextBuilderComplete` | true | Existing behavior |
| `approveFromNotifications` | **true** (gated by §4.3 and §7.3) | Offer Approve on eligible command approvals |
| `answerFromNotifications` | true | Option buttons, Skip, Decline, Reply on questions and instruction waits |
| `replyFromCompletion` | **false** | Reply action on turn-complete |
| `showDetails` | true | Include command, question, and preview text. Off means generic bodies and no Approve. |
| `notifyWhileActive` | true | Banners for non-visible sessions while RepoPrompt is frontmost |
| `completionsWhileActive` | false | Same, for completions |
| `includeAgentDrivenSessions` | false | Notify for MCP-controlled (`agent_run`) sessions (Open-only) |
| `dockBadge` | true | Pending-count badge |
| `mcpAskUserNotifyInsteadOfActivate` | **false** | Phase E opt-in: an external MCP `ask_user` in an Agent Mode tab posts a notification instead of activating RepoPrompt while it is in the background |

`GlobalSettingsStore.notificationPreferences()` and `updateNotificationSettings(_:)` are the typed accessors; changes post `.notificationPreferencesDidChange`, which triggers a reconcile. `NotificationSettingDescriptor` (`Features/Settings/Models/NotificationSettingDescriptors.swift`) is the single table of keys, labels, and descriptions shared by the Settings pane and `app_settings`.

### 9.2 UI

`Features/Settings/Views/General/NotificationSettingsView.swift` is the "Notifications" pane under Settings → General (`SettingsTab.notifications`; `.showNotificationSettingsTab` opens it). It shows the macOS authorization status with an "Open System Settings…" button, then descriptor-driven toggles grouped into General, Agent Sessions, Responding from Notifications, and Chat & Context Builder.

### 9.3 MCP `app_settings`

A new **`notifications`** group (`notifications.enabled`, `notifications.approve_from_notifications`, `notifications.reply_from_completion`, …) is registered in `Infrastructure/MCP/AppSettingsMCPService.swift`, generated from `NotificationSettingDescriptor`. The group was added to the tool's `group` enum and description. The standalone headless catalog (`DomainAppSettingsCatalog`) is a curated subset and does not expose these app-only keys.

## 10. Testability

### 10.1 Seams

```swift
@MainActor protocol UserNotificationCenterClient: AnyObject {
    var isAvailable: Bool { get }                               // false outside an .app bundle
    func requestAuthorization() async -> NotificationAuthorizationStatus
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func setCategories(_ categories: Set<NotificationCategorySpec>) async
    func registeredCategoryIdentifiers() async -> Set<String>
    func add(_ request: NotificationRequestSpec) async throws
    func deliveredNotifications() async -> [DeliveredNotificationSummary]
    func removeDelivered(identifiers: [String])
    func removePending(identifiers: [String])
    func setBadgeCount(_ count: Int) async
}
@MainActor protocol AgentSessionVisibilityProviding: AnyObject {
    var isAppActive: Bool { get }
    func isAgentSessionVisible(windowID: Int, tabID: UUID, sessionID: UUID?) -> Bool
}
@MainActor protocol NotificationPreferencesProviding: AnyObject {
    var currentNotificationPreferences: NotificationPreferences { get }
}
@MainActor protocol AgentNotificationActionTarget: AnyObject { /* id-checked submit forwards */ }
@MainActor protocol AppNotificationRouting: AnyObject { func openNotificationRoute(_:) async }
@MainActor protocol AgentNotificationActionDispatching: AnyObject { func dispatch(_:route:preferences:) -> AgentNotificationActionOutcome }
```

The coordinator also takes injectable `now`, `gracePeriod`, `authorization`, and `requestUserAttention` closures.

`LiveUserNotificationCenter` wraps `UNUserNotificationCenter.current()`. `FakeUserNotificationCenter` lives at `Tests/RepoPromptTests/Helpers/FakeUserNotificationCenter.swift`, records every call, and simulates delivered state. `NotificationService` becomes a thin facade that holds the client and forwards the delegate callbacks.

### 10.2 Unit tests

| File | Covers |
|---|---|
| `Tests/RepoPromptTests/Helpers/FakeUserNotificationCenter.swift` | Fake center, preferences provider, and visibility provider |
| `Tests/RepoPromptTests/App/AppNotificationPayloadTests.swift` | Payload v2 round trip; route v1 compatibility; `NSString`/`NSNumber` bridging; future versions degrade to route-only; malformed input; launch identity; `interaction_id` URL round trip; stable identifiers. `NotificationCategoryRegistryTests`: static install, dynamic union/prune, no redundant writes, dynamic cap fails closed |
| `Tests/RepoPromptTests/App/AppNotificationResponseHandlerTests.swift` | Click opens the exact route; route-v1-only clicks still open; background actions dispatch with the interaction reference and never activate; previous-launch actions are stale and never dispatched; feedback on stale; reply text forwarded; unknown payload opens; dismiss/review; **no-window click queues the route URL** (cold launch); MCP `ask_user` opt-in policy |
| `Tests/RepoPromptTests/AgentMode/AgentNotificationActionEligibilityTests.swift` | Every §4.3 row; 160/161-character boundary, multi-line, padding; non-shell tools; preference gates; MCP-controlled; risk classifier positive and negative corpora; action identity parsing; static vs dynamic categories. `AgentPendingInteractionDescriptorTests`: card priority, exact command, ask_user shape, fingerprint stability and sensitivity |
| `Tests/RepoPromptTests/AgentMode/AgentNotificationPlannerTests.swift` | Actionable post content; grace deferral and wakeup; retract on resolve; no re-post when unchanged, in-place replace when changed; visible suppression, retraction, and silent re-post; foreground and category toggles; agent-driven exclusion; hidden details; turn retraction; badge. `AgentNotificationCoordinatorTests`: end-to-end post, dynamic category registration and pruning, window removal, unauthorized Dock-bounce fallback, turn complete/failed suppression and preferences, launch sweep, foreground presentation decisions, inert client |
| `Tests/RepoPromptTests/AgentMode/AgentNotificationActionResolverTests.swift` | Approve applies exactly once; never reaches a replacement interaction; fingerprint mismatch under the same id is stale; preferences and risk re-validated at action time; MCP-controlled rejects; session incarnation mismatch; permissions decline-only; ask_user choice/reply/exact-option/empty/skip; Codex user-input "Other" note; instruction reply through composer submission; turn-complete reply opt-in and staleness |
| `Tests/RepoPromptTests/Settings/NotificationSettingsPersistenceTests.swift` | Defaults; partial and unknown-key decoding; no `requiredSchemaVersion` impact; store persists at v2 and the frozen v1.3.0 codec loads the file; change notification; descriptor coverage; `app_settings` `notifications` group list/set/get |

### 10.3 Manual / live validation (per phase)

`make dev-run`. Start an agent run that requests command approval with RepoPrompt in the background. Then check:

- The banner shows Approve/Decline, and Approve resumes the run without activating the app.
- Answering in-app retracts the banner.
- Quitting and clicking an old banner relaunches, routes to the session, and shows no dead buttons.
- `ask_user` with 2–3 options shows option buttons.
- Reply on an instruction wait continues the run.
- With System Settings → Notifications → RepoPrompt CE set to "Alerts", actions stay on screen.

Use `rpce-cli-debug … agent_run start` plus an `ask_user` prompt to drive interactions deterministically.

## 11. Implementation (as built)

App layer (`Sources/RepoPrompt/App`):

- `Notifications/UserNotificationCenterClient.swift` — `Sendable` spec types, the `@MainActor` `UserNotificationCenterClient` seam, and `LiveUserNotificationCenter` (inert outside an `.app` bundle; completion-handler APIs wrapped so only `Sendable` values cross isolation).
- `Notifications/AppNotificationPayload.swift` — payload v2, `AppNotificationLaunchIdentity`, stable request/thread identifiers.
- `Notifications/AppNotificationCategories.swift` — action and category identifiers, `NotificationCategoryRegistry`.
- `Notifications/AppNotificationResponseHandler.swift` — `AppNotificationResponse` (extracted before the actor hop), the handler (open vs. act, launch fence, feedback), and the live router, dispatcher, and visibility adapters.
- `Notifications/NotificationPreferences.swift` — preferences snapshot and provider seam.
- `Notifications/NotificationService.swift` — facade: early delegate install, async delegate methods, authorization tracking, compose (Chat/Context Builder) notifications with stable identifiers, ownership of the coordinator and handler.
- `AppDelegate.swift` (`applicationWillFinishLaunching` installs the delegate; termination clears the badge), `AppDeepLinkRoute.swift` (`interactionID`, shared `NotificationUserInfoReader`), `AppDeepLinkRouter.swift` (notification route queues when no window is live and restores background mode), `WindowState.swift` (focus signal, `isAgentSessionVisible`, reveal after routing), `WindowStateManager.swift` (retract on window close), `Notifications/AppNotifications.swift` (names).

Agent Mode (`Sources/RepoPrompt/Features/AgentMode`):

- `Models/AgentPendingInteractionDescriptor.swift` — kind, display content, fingerprint, and `make(from:)` in card priority order.
- `Models/AgentNotificationActionEligibility.swift` — actions, action identities, category mapping, eligibility, and the risk classifier.
- `Services/AgentNotificationPlanner.swift` — pure planner and text preview.
- `Services/AgentNotificationCoordinator.swift` — reconciler, grace timer, turn outcomes, feedback, launch sweep, badge.
- `Services/AgentNotificationActionResolver.swift` — id/fingerprint/eligibility validation and dispatch.
- `ViewModels/AgentModeViewModel+AttentionNotifications.swift` — per-session observation feeding the coordinator, visibility helper, reveal requests.
- `ViewModels/AgentModeViewModel+NotificationActions.swift` — `AgentNotificationActionTarget` conformance (id-checked forwards).
- `ViewModels/AgentModeViewModel+InteractionActions.swift` — id-checked `submitApprovalDecision(tabID:requestID:decision:)`; the in-app approval card now uses it.
- `AgentModeViewModel.swift` (tracker, visibility hook, observer sync, turn outcomes through the coordinator, direct instruction-wait notification removed), `Views/AgentModeView.swift` (reveal → pin to live bottom), `Runtime/AgentRunTerminalCommitBarrier.swift`, `AgentRunTerminalSessionBinding.swift`, `AgentModeRunServiceHooks.swift` (defaulted `notifyAgentTurnFailed` hook).

Settings and MCP: `Features/Settings/Models/GlobalSettingsDocument.swift`, `GlobalSettingsManager.swift`, `NotificationSettingDescriptors.swift`, `Views/General/NotificationSettingsView.swift`, `Views/SettingsView.swift`, `App/Views/ContentViewNotificationHandler.swift`, `Infrastructure/MCP/AppSettingsMCPService.swift`, `Infrastructure/MCP/WindowTools/MCPAskUserToolProvider.swift` (Phase E opt-in), plus the Chat and Context Builder call sites (group identifiers).

Deferred follow-ups:

- The "already handled" in-app toast when a click reveals an interaction that has since resolved (the click still opens the session).
- Approval telemetry `source = notification`.
- Phase E remainder: Context Builder `ask_user`, MCP `manage_workspaces` approvals, MCP client-connection approvals, and time-sensitive interruption level.
- Codex permission requests have no in-app card today, so "Review…" opens the session without a visible card; Decline still works from the notification and `agent_run respond` remains available.
- A Reply sent from a notification goes through the composer submission path, so any images or tagged files already staged in that tab's composer are sent along with it, exactly as if the user had pressed Send.

## 12. Decisions

Recorded from design review:

1. "Approve from notifications" defaults **on**, within the strict eligibility and risk rules.
2. **No Touch ID** or password gate for notification actions.
3. **No time-sensitive entitlement** for now; interactions use the default interruption level.
4. **Alert style is not forced**; users can choose Alerts in System Settings.
5. A new **`notifications`** `app_settings` group.
6. An additive `notifications` settings group with **no schema version bump**; decoding tolerates missing keys and older builds ignore the unknown key (tested).
7. Reply on turn-complete defaults **off**.
8. MCP `ask_user` → notification is an **opt-in** setting; the default keeps today's activate-and-reveal behavior.
