# Agent Mode Re-prompt: Plan

## 1. Goal

Add an optional **Re-prompt** step to Agent Mode. When enabled, each eligible local composer message is first rewritten by an **isolated side call** — which may, at its own discretion, consult Oracle and/or run Context Builder for repository grounding — into a *balanced task brief* — goal, constraints, acceptance criteria, relevant known context, assumptions, open questions — that preserves the user's intent and wording and **never prescribes implementation steps the user didn't ask for**. The user reviews and edits the brief (answering at most a few load-bearing clarification questions first) before anything reaches the implementing agent. Rewrite guidance is user-replaceable in Settings with Restore Default. Re-prompt must compose frictionlessly with Model Router, Auto Effort, and usage balancing: they judge the approved brief, add no extra prompts, and add no avoidable latency.

### Decisions at a glance (answers to the original open questions)

| Question | Decision | Why |
|---|---|---|
| First prompt only, or every prompt? | **Every eligible local prompt while the pill is on.** Off by default; transient per window/view-model instance (no persisted enable flag). | Follow-ups are often the vaguest prompts. "First turn only" is already Interview's job; a sticky toggle lets the user turn it off once the task is well-scoped. |
| Own session? | **Yes — stateless rewrite requests, not a visible agent session.** The rewriter itself has no tools and no history; refinement is a fresh request. Context consults it requests run through the existing Oracle / Context Builder entry points as their own (background) runs, never in the implementing agent's transcript. | Zero pollution of the implementing agent's context and no session clutter. |
| Surface the rewrite? | **Always.** Mandatory editable review; never auto-send. The edited text is authoritative. | Meaning drift can't be detected mechanically; review is the real guardrail against micromanaging rewrites. |
| Re-confirm when unclear? | **Yes, bounded:** ≤3 load-bearing questions (≤4 options each, custom answer allowed, skippable), then at most one refinement call. Remaining gaps become explicit "Open questions" in the brief. | Prefer a useful brief with explicit unknowns over a long interview. |
| Which model? | The effective Agent Models profile's **primary Oracle model** (`planningModelRaw`) for the rewrite. No extra lanes, presets, router, Auto Effort, or fallback to the implementing model. **All factory-built providers, including CLI providers**, are supported; the rewrite contract travels as `AIMessage.systemPrompt`, the same way Oracle's headless sends deliver theirs (§3.4.1). | Already the user's chosen "thinking" model; CLI side-call transports are already fresh, tool-less, and non-resuming. |
| Repo context? | **Rewriter's discretion.** Call 1 sees the message plus a small workspace manifest (root names, selected file paths). It may request **none, an Oracle consult, a Context Builder run, or both** (§3.4.2). Their results feed the single refinement call. Users can skip context gathering per run or turn it off in Settings. Context typed into the review editor goes only to the implementing agent. | Lets the rewriter turn vague terms into codebase vocabulary when that matters, without paying the latency on clear prompts. |
| Model Router? | **Re-prompt runs first; Router, Auto Effort, and balancing judge the approved brief afterward**, with no new UI. Auto Effort's raw-draft input is fixed, oversized briefs fall back to the original text for judging, and a speculative pre-judgment during review hides router latency when the brief is sent unedited (§3.10). | The router gets a better signal and the user sees a single flow. |

## 2. Background (current state)

### 2.1 Composer submission path

```text
AgentInputBar.sendMessage → executeSubmit(claim, trimmed)
  → executeComposerSubmitAttempt → submitClaimedComposerUserTurn
  → submitUserTurn → submitPreparedUserTurn
  → startAgentRun → AgentModeRunService.startRun → provider runner
```

- UI send: `AgentInputBar.sendMessage()` — `Sources/RepoPrompt/Features/AgentMode/Views/AgentInputBar.swift:1631–1670` (actions wired `:126–129`).
- `executeComposerSubmitAttempt(text:claim:)` — `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:17718–17781`. Revalidates the claim after hydration, handles initial execution-location preparation (`expectedInitialStartLocation`), clears the composer only after `.submitted` via `clearComposerDraftIfUnchanged`. The claim identifies the exact source session and draft snapshot and blocks competing submissions.
- `submitUserTurn` (`:18340–18484`): validates input/provider, classifies native commands and slash skills, captures then clears selected workflow and pending attachments.
- `submitPreparedUserTurn` (`:19071–19234`): builds bubble text and provider text; provider-text precedence is **managed → native-wrapper → submitted text**; then Computer Use wraps eligible input, Interview prepends on first turn (`:19133–19162`), selected workflow wraps (`AgentWorkflow.wrapUserText`, `Models/AgentWorkflow.swift:240+`); appends the user row; routes active-turn steering vs new run.
- Automation wrappers between admission and preparation: `submitUserTurnAfterHydration` (`AgentModeViewModel.swift:18542`), `submitUserTurnAfterFreshTaskRouting` and `submitUserTurnAfterAutoEffort` (`AgentModeViewModel+Routing.swift:140, 284`), `submitUserTurnAfterUsageBalancing` (`AgentModeViewModel+UsageBalancing.swift:142`). Each can drop a carried replacement or re-read the original, and routing/balancing can change model/effort asynchronously.
- `startAgentRun` (`:20891–21053`) → `augmentUserMessageForProviderSend` (`:20622–20631`; slash-skill expansion `:20743+`, tagged files, attachments) → `AgentModeRunService.startRun` (`Runtime/AgentModeRunService.swift:179–329`), which dispatches already-prepared turns to Codex / Claude / ACP / headless — too late and too broad for interactive rewriting.
- **Hazard:** `trimmedText` also drives bubble construction, mention-driven file selection, and steering logic. Re-prompt needs explicit separation of **source text** vs **approved replacement**; globally replacing `trimmedText` would change command recognition and file selection.

### 2.2 Interview pill precedent

- `interviewFirst` is transient view-model state (`AgentModeViewModel.swift:307–311`), first-message-only, reset after consumption (`:19162`).
- Projection: `AgentStatusPillsSnapshot` in `ViewModels/UI/AgentStatusPillsUIStore.swift:42,62`; `update` publishes only unequal snapshots; `AgentStatusPillsRow` (`Views/Components/AgentStatusPillsRow.swift:61–63`) doesn't observe the whole VM. Pill: `AgentInterviewPill` (`Views/Components/AgentTogglePills.swift:47–62`); setters `AgentModeViewModel+StatusPillsUI.swift:162–169`; metrics `Views/Components/AgentStatusPillMetrics.swift`.
- Interview = in-context clarification by the implementing agent. Re-prompt = out-of-context rewrite before the agent sees anything. They coexist.

### 2.3 Model / side-call precedent

- No standalone title/commit/"enhance prompt" generator exists.
- **Stateless transport:** `AIProvider.completeMessage(_:model:maxTokens:)` / `streamMessage`, constructed via `AIProviderFactory` (`Sources/RepoPrompt/Infrastructure/AI/Providers/AIProviderFactory.swift`). `AIMessage` carries a `systemPrompt` and `transientImages`; results are `AICompletionResult` text (so prompt-only JSON, not native structured output, is correct).
- **How existing side calls deliver system prompts (incl. CLI providers):** Oracle headless sends freeze a `HeadlessContextSnapshot`, and `PromptViewModel.buildHeadlessAIMessage` puts the plan/chat/review system prompt (or a preset override) into `AIMessage.systemPrompt` (`Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift:1400–1455`; `PromptViewModel+HeadlessPlan.swift:72–165`; `OracleHeadlessRuntime.swift:41–80,111–117`, 4-hour outer timeout). Each CLI provider then maps it as follows:
  - `ClaudeCodeProvider`: native `--system-prompt` replacement when delivery is `.nativeSystemPrompt`, otherwise wrapped into the user prompt (`ClaudeAgentToolPreferences.swift:7–35`, `ClaudeCompatibleProviderRuntimeBridge.swift:229–233`, `ClaudeCodeAgentProvider.swift:384`). Empty MCP config plus `--strict-mcp-config`, an extensive `disallowedTools` list, no resume. Default timeout 6000 s (`ClaudeCodeProvider.swift:10–94,127–189,270–304,362–384`).
  - `CodexCLIProvider`: fresh app-server session; `systemPrompt` → `baseInstructions`; `existing: nil` (no resume); shell, web, multi-agent, and MCP disabled; read-only sandbox; approval `.never`. 45 min timeout (`CodexCLIProvider.swift:115–161,491–500,935–1079`).
  - `CursorCLIProvider` / `OpenCodeCLIProvider`: fresh ACP, `workspacePath: nil`, `resumeSessionID: nil`, `AgentMessage.systemPrompt`; Cursor runs in `ask` mode with a no-tools instruction, OpenCode uses `.noTools`; RepoPrompt MCP excluded (`CursorCLIProvider.swift:28–35,111–140`; `OpenCodeCLIProvider.swift:17–24,108–137`).
  - `DevinCLIProvider`: private temp cwd, MCP disabled, prompt file containing the system prompt plus a no-tools instruction. 6000 s timeout (`DevinCLIProvider.swift:7–31,113–288`).
  - Child processes honor `cancelChildOnTaskCancellation: true`. Provider default timeouts are very long, so Re-prompt needs its own outer timeout.
- **Programmatic Oracle:** `OracleViewModel.tool_chatSend(...)` (`OracleViewModel+MCP.swift:825`). Inputs: message, mode (`chat|plan|review`), resolved execution/roster, `PromptViewModel`, and an `OracleSendTabContext` (tab/workspace IDs, frozen prompt, `StoredSelection`, lookup/review-Git contexts; `:27–154, 846–855`). It creates/locates a `ChatSession`, autosaves it, and returns `chat_id`/response/`context_id` (`:908–1070`). The session is visible/activated unless the context requests background activation. Cancel via `cancelStreaming(in:)` / `cancelAIResponse` (`OracleViewModel.swift:4071–4100`). The MCP adapter is `MCPOracleToolService.executeAskOracle` (`Infrastructure/MCP/MCPOracleToolService.swift:120,310`).
- **Programmatic Context Builder:** `ContextBuilderAgentViewModel.runContextBuilderForMCP(...)` (`:2100`). Inputs: `WorkspaceSelectionIdentity`, frozen nested tab/workspace/lookup context, agent/model/run behavior, optional instructions override, and an MCP-control token. `clarify` is context-only (no Oracle chat); `question`/`plan` add an Oracle follow-up. It **commits its selection into the workspace tab** and persists it (`MCPServerViewModel+TabContext.swift:4574–4718`), and persists per-tab run history (`:2502–2504, 3969–3974`). In agent mode it reuses the invoking tab (`MCPServerViewModel.swift:4350–4519`). With the default `PromptEnhancementMode.fullRewrite`, it **sets the tab prompt** (`augment` appends; `preserve` leaves it alone; `SystemPromptService.swift:183–287`). Cancel via `cancelMCPContextBuilderRun` (`:2187–2191, 3404–3429`). Typical duration 30 s–5 min (`MCPContextBuilderToolProvider.swift:342`); progress stages and heartbeats are at `:568–640`.
- Context Builder reads `effectiveAgentModelsProfile(workspaceID:)` → `planningModelRaw` (+ `additionalOracleModelRaws`) — `Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift:5641–5668`.
- `OracleExecutionResolver` (`Features/Chat/Services/OracleExecutionResolver.swift`; roster `:377–383`) resolves via `AIModel.fromModelName` and checks `mcpOracleIsProviderConfigured(for:)`. Its full path also captures chat presets, prompt context, system prompts, extra lanes, reconciliation guidance — **inappropriate** for an isolated rewrite. Reuse only its model-resolution/availability primitives.
- Context Builder's `PromptEnhancementMode` (`fullRewrite`/`augment`/`preserve`, `Sources/RepoPromptSettingsCore/ContextBuilderSettingsValues.swift:3–14`; guidance in `Infrastructure/AI/SystemPromptService.swift:11–17,181–215`) is vocabulary precedent only — no coupling.

### 2.4 Settings precedent

- Editable Oracle reconciliation guidance: view `Features/Settings/Views/AgentModelsSettingsView.swift:394–418`; save/restore/conflict in `Features/AgentMode/ViewModels/UI/AgentModelsSettingsViewModel.swift:305–345` (model settings `:392–478`).
- `AgentModelsSettingsProfile` supports workspace/global scope and retained workspace overrides.
- `Sources/RepoPromptSettingsCore/GlobalSettingsDocument.swift:83–99`: per-feature schema constants; `oracleReconciliationGuidanceSchemaVersion = 11`, `currentSchemaVersion = 12` (verified). `requiredSchemaVersion` fences meaningful settings (including retained workspace profiles) from older typed writers.

### 2.5 Clarification UX precedent

- `AgentAskUserInteraction`, `AgentAskUserPendingState` (`Features/AgentMode/Models/UserInteractionModels.swift:131–154, 267–310`) and `AgentAskUserWizardCard` (`Views/ToolCards/AgentAskUserWizardCard.swift`, shared with Context Builder): one question at a time, options/custom/skip, validation. `AgentAskUserPendingState` requires `interaction.timeoutSeconds` (default 300) and `timeoutStartedAt`; the card renders a countdown (`:106–108`) and a pulse derived from `timeoutSeconds / 3.0` (`:352`). For single-select, a custom answer clears selected options (`answer(from:)`).
- Re-prompt clarification is **local pre-submission UI**: must not set `session.pendingAskUser`, move the run to waiting, or inherit runtime timeouts.
- Workflow prompt guidance on grounded clarification: `Sources/RepoPromptShared/Workflows/WorkflowPrompt+Build.swift:75–89`, `WorkflowPrompt+Optimize.swift:61–70`, `WorkflowPrompt+Reminder.swift:40` ("ask when ambiguity is load-bearing; don't guess").

### 2.6 Session-link boundary

- Idle attributed sends use `persistAndStartNoncomposerTurn` → `startAgentRun` directly; managed steers enter prepared submission with `AgentNoncomposerTurn`. Both intentionally skip composer preferences (`Runtime/SessionLinks/AgentModeViewModel+SessionLinkSend.swift:335`, `AgentSessionLinkManagedSteer.swift:10`). Readiness admission already treats an in-flight composer submission as a blocker.
- Re-prompt stays absent from these paths. A pending local rewrite keeps holding the ordinary composer claim and gains no new session-link authority.

### 2.7 Model Router / Auto Effort / usage balancing

- **What and when.** The Model Router picks **provider, base model, and initial effort** from local opaque candidates using a finite-choice task classification, followed by an effort classification. It never picks the workflow, tab, or worktree (`AgentModeViewModel+Routing.swift:518–621`). It runs only on an eligible **first send of a fresh session**: empty/new, non-MCP, non-child, inactive, and not blank or slash (`:282–304, 665–684`). Auto Effort judges eligible inactive turns, including settled follow-ups, but never an active turn or a Router-owned start. Usage balancing (`AgentModeViewModel+UsageBalancing.swift:36–74`, `AgentUsageBalancer.swift:55–143`) is local quota arithmetic that narrows the providers before routing.
- **Inputs.** `submitUserTurnAfterFreshTaskRouting` (`+Routing.swift:140`) judges the passed `text` via `routeModelThenEffort(requestID: claim.attempt.id, text:...)`, checks `freshTaskRoutingEligibility(session:text:)`, and records `freshTaskRoutingByTabID` ownership for the source and destination tabs. Its stale checks are `composerSubmitClaimIsCurrent`, the destination session, `configuration.revision`, and `selectedBackendID`; a failed apply rolls back via `RoutedSelectionRollback`. **`submitUserTurnAfterAutoEffort` judges `claim.attempt.rawDraftSnapshot`, not `text`** (`:299–302`), so as written it would ignore an approved brief. Auto Effort only accepts turns of ≤4,000 characters and sends a 1,200-character masked excerpt (`Routing/AutoEffortTaskSummary.swift:8–68`). The Router forwards short text directly and reduces/masks long text (`Routing/ModelRouterDecisionPolicy.swift:35–114`, `Routing/AgentTaskRoutingTaskExcerpt.swift:8–27`).
- **Transport and UI.** Decisions go to `FiniteChoiceDecisionRequest`s on Jev (`jev-1.13.0`) or OpenAI Decisions (`gpt-6-luna`), with a **5 s deadline and no retry**. The Router may make two sequential judgments (`Routing/Backends/OpenAIDecisions/OpenAIDecisionsDecisionService.swift:10–151`, `Routing/Backends/Jev/JevDecisionService.swift:39–48`). There are no per-turn decision cards: the Router pill shows a spinner and disables itself, and fresh-task model controls are disabled while the Router owns the start. Failed or stale decisions fall back to the manual selection (`AgentTogglePills.swift:202–260`, `+Routing.swift:223–276`). Enabling Auto Effort from its pill requires a disclosure (`Features/Settings/Views/Router/RouterSettingsView.swift:542–595`).
- **Ordering and audit.** Composer worktree/tab creation happens before routing, so the Router applies its target to an already-created destination session. A per-session `AgentAutomationTurnAudit` keeps up to 128 non-content records (`Routing/AgentAutomationTurnAudit.swift:5–79`); `routerAudit: AgentAutomationTurnAudit.Feature` is threaded through `submitUserTurn`.

## 3. Design

### 3.1 Eligibility and bypasses

| Input | Behavior |
|---|---|
| Local composer text, pill on | Re-prompt |
| Native commands, slash skills, staged slash invocations, any text whose first non-whitespace char is `/` | Bypass |
| Attachments-only / tagged-files-only (no text) | Bypass |
| Text + attachments | Rewrite text only; attachments go to the agent unchanged and are **not** sent (contents, names, paths, thumbnails) to the rewrite model or to context consults |
| Whitespace-only, no attachments | Existing empty-input rejection, no side call |
| Structured interaction responses (approvals / ask_user answers) | Bypass |
| Active local steering | Supported while the captured run/attempt stays current |
| MCP starts/follow-ups, attributed sends, managed steers, auto-wakes, internal continuations | Always bypass; never read or consume Re-prompt state; never call the service |
| Workflow selected | Rewrite user text first; workflow wraps approved text exactly once. Template is never shown to the rewrite model |
| Interview on | Unchanged: consumed at its existing point. Cancelling Re-prompt doesn't consume it. Interview may still ask after dispatch |

### 3.2 Composer preparation stage and frozen context

Insert an async, composer-owned preparation stage **after** source readiness/claim/admission checks and command preflight, **before**: initial worktree creation, destination-tab creation for new-tab submits, router/Auto Effort judgments, consumption of workflow/attachments/Interview, and appending transcript rows. In the existing-session route, insert after hydration/claim/admission checks and before the `expectedInitialStartLocation` branch; apply equivalent ordering on other `executeComposerSubmitAttempt` routes.

Proposed:

```text
prepareComposerReprompt(claim, sourceContext) async
  → .unchanged | .approved(AgentRepromptApprovedTurn) | .cancelled
```

`AgentRepromptApprovedTurn` (immutable): approved trimmed text, operation ID, preparation-context identity for final validation.

Proposed: one main-actor operation record per view model (multiple windows may prepare independently) holding: operation UUID + composer claim identity; source session object identity, persistent-binding identity/generations; source tab and workspace IDs; original raw draft + input revision; source run ID, attempt ID, run-state classification; selected workflow + mutation generation; ordered pending attachment identities and staged-command state; effective settings scope, primary Oracle raw model, resolved model, guidance snapshot; phase, model task, question drafts, editable review text; a one-shot completion mechanism. Do **not** capture assistant transcript content (streaming must not invalidate).

**Freshness checks** — operation ID, task cancellation, claim, source binding, workspace, input revision, captured selections, settings snapshot — run (1) before each model call, (2) after every await, (3) before accepting clarification/review actions, (4) immediately before normal submission resumes. Invalidators: tab/workspace switch, source rebind, Stop, draft mutation, attachment/workflow change, a change to the primary Oracle model or guidance **in the captured effective settings scope** (edits to another scope don't invalidate), a newly blocking interaction, run/attempt transition (including **natural run completion during review** — conservative, avoids sending a reviewed steer into a different turn boundary). Streaming within the same attempt is fine. **Implementing provider/model/effort changes are not invalidators.** The rewrite doesn't depend on them, and post-approval dispatch reads the live selection exactly as today, so a user can change the model or toggle the Router during review without losing the brief. Router, Auto Effort, and usage balancing run after approval (§3.10). Consult tasks in flight are cancelled on invalidation. Invalidate eagerly from lifecycle events; keep the final comparison as a backstop.

On invalidation: cancel the side request, dismiss UI, resolve once as `.cancelled`, leave draft and selections untouched, never submit into a replacement session.

**Edited-brief recovery:** if invalidation (or a post-approval dispatch failure) happens after the user reached `reviewing`, keep the latest brief text in memory on `AgentRepromptUIStore` and show a non-blocking composer banner — "Re-prompt cancelled: *reason*. [Restore brief to composer] [Copy] [Dismiss]". Restore replaces the draft only on explicit click (and only if the draft is unchanged since invalidation, else it asks). The banner is cleared by the next submission, dismissal, or window teardown. Invalidation from a tab switch shows the banner on the source tab when the user returns, so the user never loses a sheet they can't find.

### 3.3 State machine

| Phase | Data | Actions |
|---|---|---|
| `generating` | input, manifest, model identity | Cancel · Send Original |
| `clarifying` + `gatheringContext` (concurrent) | first result + `AgentAskUserPendingState`; consult tasks and their progress | answer/navigate/skip · **Skip context** · Cancel · Send Original |
| `refining` | first result + answers/skips + context results | Cancel · Send Original |
| `reviewing` | editable rendered brief | Edit · Send · Send Original · Cancel |
| `failed` | safe error, retryable phase | Retry · Send Original · Cancel |

Terminal outcomes: unchanged/original, approved, cancelled. Duplicate callbacks and late responses ignored after terminal.

Algorithm:
1. Eligibility checks (no mutation).
2. Freeze context; build the workspace manifest (§3.4.2); start first request.
3. Validate response.
4. If `contextRequests` is non-empty (and policy allows), start the requested consults **immediately and concurrently** with step 5.
5. If `openQuestions` non-empty → present in model order while consults run.
6. When questions are done **and** consults have finished, failed, or been skipped: if there is ≥1 substantive answer or ≥1 successful consult result → one refinement request (original input + manifest + explicit answer/skip pairs + consult results). Otherwise use the first result with no second call. Show a "Gathering context… [Skip context]" state if questions finish before consults.
7. Render brief into editable review.
8. Gaps still reported by refinement → rendered as open questions; no second question loop.
9. Send only after explicit approval + final freshness check.

Question limits: ≤3 questions, ≤4 options each, single-select, custom response always allowed, no preselection, individually or wholly skippable. Mapping: each `openQuestions` entry → `AgentAskUserQuestion` with `allowsMultiple = false`, `allowsCustom = true`; IDs/labels must pass `AgentAskUserInteraction.validate` or the response is rejected as invalid. Refinement serializes each answer as `{question, selectedOption | customText | skipped}` — a custom answer is sent as free text (single-select custom clears options). Use existing answer builders; Re-prompt-specific limits live in its response validator, not the shared models. No countdown/auto-submit on user think time. Per-rewrite-call outer timeout: 60 s for API providers, 120 s for CLI providers. These cover Codex app-server and ACP cold starts, and they're required because provider defaults (6000 s, 45 min) are effectively unbounded; the outer timeout cancels the task, which for CLI providers terminates the child via `cancelChildOnTaskCancellation`. Provider-internal retries stay as configured but are bounded by the outer timeout. Max two successful **rewrite** calls per preparation (excluding explicit Retry), plus at most one Oracle consult and one Context Builder run.

### 3.4 Isolated side-call service

Proposed `AgentRepromptService`: a **nonisolated** (Sendable) service owning prompt assembly, the provider call, timeout, and decoding; it does not run on `MainActor`. The **operation** (lifecycle, UI, freshness) is owned by the `@MainActor` `AgentModeViewModel+Reprompt` extension, which awaits the service. Injectable: model resolution, availability/transport policy, provider factory.

```text
// proposed; model supplied separately from prompt content
generate(request: AgentRepromptRequest, model: AIModel) async throws → AgentRepromptResult
```

Request: original user text, workspace manifest, captured guidance, optional answers + skipped question IDs, optional consult results.

Must: reuse `AIModel.fromModelName` + existing provider-configuration check; execute one standalone provider request with no previous messages; create no Oracle chat/session and no canonical history **for the rewrite itself**; use a fresh request for refinement; never invoke normal prompt-context packaging (`buildHeadlessAIMessage`) for the rewrite. Refinement is rebuilt from the **original message + manifest + Q/A pairs + consult results**, not the first response — prevents compounded drift. Do **not** call `OracleExecutionResolver.resolve(.automatic, …)` for the rewrite.

**Transport:** call `AIProvider.completeMessage` on a provider built by `AIProviderFactory` (no second client), with a single `AIMessage` whose `systemPrompt` = fixed contract + guidance and whose body = delimited user text + manifest (+ Q/A and consult results on refinement); `transientImages` empty. Prove with a request-capture test at the `AIMessage` level and one per provider family against real factory-built provider types (stubbed transport) showing the system prompt is delivered and nothing beyond the declared inputs is added.

#### 3.4.1 System prompt delivery on all providers (incl. CLI)

Follow the Oracle headless precedent exactly: the fixed contract + guidance goes in `AIMessage.systemPrompt`; each provider already maps it (§2.3) and already runs side calls fresh, tool-less, and non-resuming. No allowlist and no new provider flags.

- **Claude Code:** request `.nativeSystemPrompt` delivery (`ClaudeAgentToolPreferences.nativeSystemPromptOverride`) so the contract **replaces** the Claude Code agent preamble rather than competing with it. If the user's configured delivery is wrapped, the contract is wrapped into the user prompt. The contract text must work in both positions; it opens with "You are a prompt rewriter, not a coding agent; output only the JSON object."
- **Codex CLI:** `systemPrompt` → `baseInstructions` (replaces Codex's default developer instructions for that fresh session).
- **Cursor / OpenCode / Devin:** their existing system-prompt + no-tools mapping applies unchanged.
- **Verify in step 1** (not a design change): the Claude Code side-call cwd is not a workspace root, so project `CLAUDE.md`/memory isn't loaded into the rewriter. If it is, give it a private temp cwd like `DevinCLIProvider` does.
- Cancellation terminates CLI children via `cancelChildOnTaskCancellation`.

#### 3.4.2 Discretionary repository context (Oracle / Context Builder)

**Manifest (call 1 input).** Workspace root names plus currently selected file paths (relative, capped at 50 paths / 4 KiB, with "+N more"). Never file contents, git state, transcript, or attachments. That's enough for the rewriter to judge whether its message references code it can't resolve.

**Request contract.** The call-1 response may include:

```text
contextRequests: [
  { kind: "oracle", question: String }            // ≤1; answered from the tab's current selection
  { kind: "contextBuilder", instructions: String } // ≤1; discovers relevant files when unknown
]
```

The rewriter chooses none, either, or both. Fixed-contract guidance on when to use each:
- **none:** the message is clear or not about code specifics (most messages).
- **oracle:** a quick question that the current selection can likely answer ("what's the existing pattern for X?").
- **contextBuilder:** the relevant files are unknown and the terms are ambiguous (slow, 30 s–5 min, so it should be rare).
- **both:** Context Builder is the broad sweep and Oracle answers a focused question. They run concurrently and Oracle uses the pre-run selection.

The rewriter can't request more than one round; consult results go only to refinement.

**Execution (owned by `AgentModeViewModel+Reprompt`, not by the rewrite service):**
- **Oracle consult:** proposed `AgentRepromptContextConsultant.consultOracle` → `OracleViewModel.tool_chatSend` with `mode: chat` and **background activation**, using an `OracleSendTabContext` frozen from the source agent tab (the same selection the implementing agent's `ask_oracle` would see). It uses the normal Oracle roster for that workspace, so the consult is an ordinary Oracle chat. The chat is titled "Re-prompt consult", autosaved like any Oracle chat, and never added to the agent transcript. Outer timeout 180 s; cancel via `cancelStreaming(in:)`.
- **Context Builder run:** proposed non-MCP entry `runContextBuilderForReprompt(...)` on `ContextBuilderAgentViewModel`. It is a thin wrapper over the same core as `runContextBuilderForMCP` (`:2100`) without the MCP-control token, using `clarify` (no Oracle follow-up) against the source agent tab, the rewriter's `instructions`, and a **per-run `PromptEnhancementMode.preserve` override** so the tab prompt is never rewritten (Re-prompt owns the rewriting). If the run-behavior type has no per-run enhancement override, add one; don't snapshot and restore the prompt instead. Outer timeout: Context Builder's own; the user can Skip at any time.
- **Selection side effect:** Context Builder commits its selection to the agent tab. Snapshot the tab's `StoredSelection` before the run. On **approval**, keep the new selection (it's useful to the implementing agent's later `ask_oracle`/tool use) and state it in review ("Context Builder selected N files"). On **Cancel / Send Original / invalidation**, restore the snapshot only if the tab selection still equals what Context Builder committed; otherwise leave the user's newer changes.
- **Results fed to refinement:** Oracle answer text (≤16 KiB, truncated with an explicit "[truncated]" marker, since this is model output rather than user input) and the Context Builder selected file paths + its effective prompt/summary (≤16 KiB, same rule). Results go under "Relevant known context" only when the rewriter judges them relevant. The fixed contract forbids turning consult findings into new requirements; they are context and assumptions, not obligations.
- **Failure:** a failed, timed-out, or skipped consult is a non-fatal note ("Context Builder skipped") and refinement proceeds without it. If every consult fails and there are no answers, use the first result.
- **Policy setting:** `agentRepromptContextPolicy: automatic | never` (default `automatic`). `never` strips `contextRequests` from the contract and omits the manifest, which restores the text-only behavior.

**Response contract** (versioned JSON parsed from text; no native structured-output dependency):

```text
version: 1
brief: { goal: String, constraints: [String], acceptanceCriteria: [String],
         knownContext: [String], assumptions: [String] }
openQuestions: [{ id, question, options: [{ label, description? }] }]
contextRequests: [{ kind: "oracle" | "contextBuilder", question? | instructions? }]  // call 1 only; must be empty on refinement
```

All fields required; arrays may be empty; `goal` non-blank. A response with only `goal` (all arrays empty) is valid — that's the "minimal changes" path for already-clear messages. Render non-empty sections in order: Goal, Constraints, Acceptance criteria, Relevant known context, Assumptions, Open questions. No placeholder criteria or empty-section filler. The review editor holds the complete final text; it becomes provider base text verbatim (no regeneration).

**Bounds (UTF-8):** input ≤32 KiB; guidance ≤16 KiB; total answers ≤16 KiB; response body and approved text ≤64 KiB each. Reject malformed JSON, unsupported versions, blank goal, duplicate question IDs/options, excess counts. Permit one surrounding JSON code fence; don't extract JSON from prose. Never truncate silently. No automatic JSON-repair call.

**Typed errors:** missing/unknown/unconfigured primary Oracle; invalid context request (unknown kind, duplicates, >1 per kind, present on refinement → the response is invalid); size limit; timeout; auth/rate-limit/network/provider; malformed/invalid response; cancelled/stale. Shown in preparation UI, never in the implementing transcript. Drafts and selections preserved. Retry repeats the failed phase with the same frozen context; changed settings invalidate instead.

### 3.5 Instructions and default guidance

Two layers:
1. **Fixed contract** (not editable): role line ("prompt rewriter, not a coding agent"), output schema, delimiting user text and consult results as untrusted content to rewrite (not instructions to the rewriter), no direct tool use, preservation rules, clarification limits, context-request rules and when-to-use guidance (§3.4.2), and "consult findings are context, never new requirements".
2. **Editable guidance**: wording/organization preferences, and how eagerly to request context. Cannot remove review, exceed consult limits, bypass `agentRepromptContextPolicy`, enable tools, or override the contract.

Draft default guidance:

> Rewrite my message into a balanced task brief for an implementing agent. Preserve my intent, scope, important wording, named entities, uncertainty, and explicit constraints. Keep distinctive wording where it already communicates well; improve organization rather than replacing my voice unnecessarily.
>
> Cover the goal, constraints, acceptance criteria, relevant known context, assumptions, and open questions when the supplied information supports those sections. Omit empty sections. Acceptance criteria must restate outcomes I requested, not introduce new obligations.
>
> Never invent requirements, repository facts, APIs, files, deadlines, platform choices, or implementation decisions. Never prescribe implementation steps, architectures, testing requirements, migrations, or delegation unless I requested them. A clearer brief is not an implementation plan.
>
> Distinguish supplied facts from assumptions. Do not convert uncertainty into a requirement. Avoid assumptions where a question would materially change scope, safety, correctness, or the requested outcome.
>
> Ask only load-bearing questions that cannot reasonably be left open. Prefer a useful brief with explicit open questions over a long interview. Do not ask about information already supplied, or ask me to choose incidental implementation details.
>
> For a short or already-clear message, make minimal changes.
>
> Request repository context only when my message refers to code, behavior, or conventions you can't resolve from what I wrote. Prefer no context for clear requests, a focused Oracle question when the current selection likely has the answer, and Context Builder only when the relevant files are unknown. Use what you learn to name things the way the codebase does, not to add work I didn't ask for.

Product copy: "balanced task brief". No new persisted mode enum.

### 3.6 UI

**Pill:** icon-only **Re-prompt** pill next to Interview, same metrics/conventions. Proposed (field set may adjust) `AgentRepromptPillProps: Equatable { isOn, isAvailable, isPreparing, modelDisplayName: String?, unavailableReason: String? }` added to `AgentStatusPillsSnapshot` (with `.empty` defaults). Large drafts never go through the pill snapshot.

- Off + available → enable after a disclosure confirmation:
  > Re-prompt sends the text of each eligible local prompt, your rewrite guidance, and your workspace root names and selected file paths to the workspace's primary Oracle model (*model/provider name*) before sending it to the agent. When it needs more context, it may consult Oracle or run Context Builder on this workspace, just as an agent could. This may be a different provider than your agent, with its own data-retention terms, so avoid pasting secrets. Attachments and conversation history are not included, and anything you add while reviewing goes only to the agent. You review and approve every result. (With context gathering set to Never, only the message text and guidance are sent.)

  The acknowledgement (not the enable flag) is persisted as a local app preference outside `GlobalSettingsDocument`, so new windows don't re-prompt; it resets if the primary Oracle provider changes.
- Off + unavailable → open Agent Models settings.
- On → click disables future preparation; an in-flight operation is controlled by its own Cancel/Send Original.
- On + unavailable → stay on, show warning; an eligible submit opens the failure/options UI rather than silently sending unchanged.

**Sheet** (composer-attached, driven by a separate proposed `AgentRepromptUIStore` the input bar/presentation host observes):
- progress: model name + Cancel/Send Original;
- clarification: existing wizard, with a compact consult strip underneath ("Oracle: answering…", "Context Builder: discovering files (1:12)") and a **Skip context** button;
- gathering context: shown only if questions finish before consults, with the same strip and Skip;
- review: collapsed original, editable brief, a "Context used" disclosure (Oracle consult link opens the background chat; Context Builder file count), privacy/model note, actions;
- error: safe message, Retry/Send Original/Cancel.

"Send Original" bypasses only Re-prompt (workflow, Interview, Computer Use, attachments still apply). Review Send disabled for blank/oversized text; if open questions remain, show a warning that they stay unresolved. Every dismissal (Esc/close) = Cancel. Composer Send is unavailable while the claim is held. On Cancel, Send Original, or Send, focus returns to the composer input; all actions have accessibility labels.

**Wizard adaptation:** add `showsTimeout: Bool = true` to `AgentAskUserWizardCard`; when `false` it hides the countdown (`:106–108`) **and** uses a fixed pulse period instead of `timeoutSeconds / 3.0` (`:352`). Re-prompt constructs `AgentAskUserPendingState` with the default `timeoutSeconds` as an inert value — nothing enforces it because the state is not in `TabSession` — so `UserInteractionModels.swift` stays unchanged. Activity callback may be a no-op. Question state lives in the operation, not `TabSession`; runtime pending-question projection and notifications untouched.

### 3.7 Carrying approved text without changing source semantics

Add `repromptedText: String? = nil` to `submitUserTurn`, `submitPreparedUserTurn`, `submitUserTurnAfterHydration` (`:18542`), `submitUserTurnAfterFreshTaskRouting` / `submitUserTurnAfterAutoEffort` (`+Routing.swift:140, 284`), `submitUserTurnAfterUsageBalancing` (`+UsageBalancing.swift:142`), and any other composer helper on that chain. Existing callers compile unchanged; only the claimed local-composer route passes non-nil. A test per wrapper asserts the replacement survives. Non-nil with `isLocalComposerInput == false` or `managedTurn != nil` is rejected; non-nil with slash source is unreachable (bypassed earlier) and is enforced by `assertionFailure` + a precondition test, not runtime behavior.

| Concern | Text source |
|---|---|
| Command/skill classification | Original only |
| Mention-driven auto file selection | Original only |
| Draft restoration | Existing `rawDraftText` / claim snapshot |
| User bubble | Approved replacement when present |
| Provider base text | managed → native → **approved** → original |
| Workflow wrapping | Existing workflow, once |
| Computer Use, Interview | Existing order/behavior |
| Usage estimation | Actual provider payload |
| Steering / queued follow-up | Approved, wrapped payload |

The bubble shows what the user approved; no new transcript metadata or serialization. Never reparse the replacement as a command: carry a "composer Re-prompt replacement" provenance flag to the slash-expansion seam in `augmentUserMessageForProviderSend` (`:20743+`) and skip slash expansion for that text. Audit every branch after `submitPreparedUserTurn`'s shown range: any provider-bound `steeringMessage` / `trimmedText` must use the final wrapped replacement; local restoration keeps using the original.

**Automation:** see §3.10. Re-prompt itself never changes model selection.

### 3.8 Settings and persistence

Editor under Oracle settings in `AgentModelsSettingsView`. It explains that the primary Oracle writes the brief and may consult Oracle/Context Builder, and it includes a "Gather repository context: Automatic / Never" picker. Reuse reconciliation guidance's Save / Restore Default / conflict detection / Reload Current Text.

| Location | Field | Default |
|---|---|---|
| `AgentModelsSettingsProfile` | `agentRepromptGuidance: String?` | nil |
| `AgentModelsSettingsProfile` | `agentRepromptContextPolicy: AgentRepromptContextPolicy?` (`automatic` \| `never`) | nil = `automatic` |
| `GlobalScalarPreferences.ModelSelectionSettings` | `agentRepromptGuidance: String?` | nil |
| `GlobalScalarPreferences.ModelSelectionSettings` | `agentRepromptContextPolicy: AgentRepromptContextPolicy?` | nil = `automatic` |

- nil/whitespace → built-in default. Trim outer whitespace only. Reject (don't truncate) oversized guidance on save.
- New `AgentRepromptGuidance` in `RepoPromptSettingsCore`: single owner of default text, normalization, 16 KiB limit; no UI/provider deps.
- Update profile init + custom decoding; global scalar init + decoding; effective-profile assembly and profile writes; workspace/global copies; recommendation/reset paths that rebuild profiles; any normalized reconstruction. Recommendations and unrelated model changes must preserve guidance.
- Workspace overrides use their own guidance; nil = built-in default, **not** field-level inheritance from global.
- Add `agentRepromptGuidanceSchemaVersion = 13`; bump `currentSchemaVersion` to 13; `requiredSchemaVersion` returns 13 **only** when a non-blank guidance override or a non-nil context policy exists globally or in any retained workspace profile. This follows the `oracleReconciliationGuidanceSchemaVersion = 11` precedent; users who never customize guidance are never fenced. Before step 2, confirm no open PR also claims schema 13 (renumber if so).
- `AgentRepromptContextPolicy` lives in `RepoPromptSettingsCore` next to `AgentRepromptGuidance`. Unknown raw values decode as `automatic`.
- Not persisted by Re-prompt: enable flag, model override, rewrite history, questions, drafts. (Oracle consult chats and Context Builder run history persist through their own existing owners.)

### 3.9 Cancellation, lifecycle, privacy

- All operation state, UI publication, claim interaction, continuation resolution on `MainActor`; provider I/O async, never blocking the actor.
- Cancel → cancel side task, release without submitting. Send Original → cancel side work, resolve once, continue normal submission with no replacement.
- Stop cancels preparation before ordinary run cancellation; an idle preparation must not manufacture a cancelled run attempt.
- Window teardown cancels and releases suspended waiters. Late results from providers ignoring cancellation are rejected by operation-ID checks.
- Claim held through clarification/review, released via existing `executeComposerSubmitAttempt` lifetime; verify `releaseComposerSubmitClaim` is paired on every exit, including invalidation and teardown.
- CLI providers: Cancel/teardown must terminate the child process; test with a fake provider that ignores cancellation.
- Consults: Cancel, Send Original, Skip context, invalidation, and teardown cancel in-flight Oracle (`cancelStreaming(in:)`) and Context Builder (`cancelMCPContextBuilderRun` core) work, then apply the selection-restore rule (§3.4.2). Late consult results are rejected by operation-ID checks.
- Pre-approval failure never clears draft, attachments, workflow, or Interview. Post-approval dispatch failure: existing recovery restores the **original** draft.
- Never log prompt text, guidance, answers, or output. Diagnostics: phase, duration, model/provider ID, sizes, error category only, routed through the existing `RepoPromptInstrumentation` / Telemetry owners; update `docs/privacy` to describe the side call, the manifest, discretionary consults, and router speculation. Drafts memory-only until approved text becomes an ordinary transcript row.

### 3.10 Model Router / Auto Effort / usage-balancing integration

Goal: with the Router and/or Auto Effort enabled, Re-prompt adds **no new prompts, cards, or settings interactions**, and post-Send latency is no worse than today.

**Ordering (unchanged pipeline, Re-prompt prepended):**

```text
Re-prompt preparation (review/approve)
  → worktree / destination-tab creation
  → submitUserTurnAfterFreshTaskRouting (usage balancing → Router: fresh eligible sessions only)
  → submitUserTurnAfterAutoEffort (eligible inactive turns)
  → submitUserTurn → submitPreparedUserTurn
```

The Router still applies its target to an already-created destination session. Its stale checks (`composerSubmitClaimIsCurrent`, destination identity, `configuration.revision`, `selectedBackendID`, `freshTaskRoutingEligibility`) and `RoutedSelectionRollback` are unchanged. The composer claim is held throughout, so the Router's claim checks keep working.

**Judged text: the approved brief.** It is a clearer task signal than the vague original.
- **Router:** already judges the passed `text`; the wrapper passes the approved text. `freshTaskRoutingEligibility(session:text:)` evaluates the approved text (never blank or slash by construction).
- **Auto Effort:** **fix** `submitUserTurnAfterAutoEffort` (`+Routing.swift:299–302`) to judge a proposed `automationJudgingText`, the approved text when present, instead of `claim.attempt.rawDraftSnapshot`. `rawDraftText: claim.attempt.rawDraftSnapshot` stays as-is for draft restoration.
- **Oversized fallback:** if the approved text exceeds Auto Effort's 4,000-character eligibility limit but the original raw draft does not, Auto Effort judges the **original** rather than silently skipping. The Router's own long-text reduction handles long briefs, so the Router always judges the approved text. The audit records which text was judged.
- The workflow category passed to Auto Effort stays `session.selectedWorkflow` (unchanged).

**Hiding Router latency (speculative pre-judgment).** When review begins, the Router is enabled and backend-ready, and the source session is fresh-task-eligible, start a speculative `routeModelThenEffort` on the **generated** brief:
- It uses a distinct request ID (`reprompt-spec-<operationID>`), so it never collides with the real `claim.attempt.id` judgment or its `freshTaskRoutingByTabID` ownership.
- It applies nothing and owns no tab.

On Send, reuse its `StagedTaskRoutingResult` only when all of these still match:
- the approved text is byte-identical to the speculated text;
- `configuration.revision` and `selectedBackendID`;
- the post-usage-balancing candidate set identity (opaque keys plus targets).

Otherwise cancel it via `runtime.coordinator.cancel(requestID:)` and judge normally. Reuse goes through a proposed optional `precomputedRouting:` parameter on `submitUserTurnAfterFreshTaskRouting`. Ownership registration, stale checks, `applyRoutingTarget`, and rollback all still run, so reuse only skips the network wait.

The same applies to Auto Effort on follow-up turns: speculate `chooseAutoEffortForUserTurn` on the generated brief, keyed by text + session model + workflow, and reuse it under the same byte-identity rule. Every preparation exit (Cancel, Send Original, invalidation, teardown) cancels outstanding speculation. Speculation sends only what the opted-in Router/Auto Effort would send on Send. The one difference is when the user cancels after it has started; `docs/privacy` notes this.

**UI coexistence.** The Re-prompt and Router pills are independent, and Re-prompt's sheet never shows routing state. On Send, the sheet closes and the Router pill shows its existing spinner (normally skipped thanks to speculation). Model controls stay enabled during review (not invalidators). They're disabled only once the Router owns the start, which is today's behavior. Re-prompt's own model (primary Oracle) is never routed.

**Audit.** Extend `AgentAutomationTurnAudit` with an optional non-content `reprompt` feature record: `outcome` (approved | sentOriginal | bypassed), `consults` (none | oracle | contextBuilder | both, each with success/skipped/failed), `automationJudgedText` (approved | originalFallback), `routerSpeculation` (reused | discardedEdited | discardedStale | none). Codable optional fields default to nil, and the existing 128-record cap applies.

## 4. File-by-file impact

### Existing files

| File | Change |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift` | Transient enabled state + operation ownership; preparation in claimed composer routes; propagate approved text through hydration/submission; source/display/provider text split; cancellation + final freshness. Lands atomically with the extension and text propagation. |
| `…/AgentMode/ViewModels/AgentModeViewModel+StatusPillsUI.swift` | Setter/toggle + props projection; Interview unchanged. |
| `…/AgentMode/ViewModels/UI/AgentStatusPillsUIStore.swift` | `AgentRepromptPillProps` + snapshot field + `.empty`; update every snapshot initializer (prod + tests). |
| `…/AgentMode/Views/Components/AgentTogglePills.swift` | `AgentRepromptPill`, disclosure, accessibility, tooltip, unavailable behavior. |
| `…/AgentMode/Views/Components/AgentStatusPillsRow.swift` | Insert pill after Interview; wire toggle + settings navigation. |
| `…/AgentMode/Views/ToolCards/AgentAskUserWizardCard.swift` | Backward-compatible `showsTimeout`. |
| `…/AgentMode/Views/AgentInputBar.swift` (or its presentation host) | Observe `AgentRepromptUIStore`, present sheet; keep submit-claim ownership. |
| `…/AgentMode/ViewModels/UI/AgentModelsSettingsViewModel.swift` | Guidance draft/save/default/reload/conflict; writes use captured editing scope. |
| `Sources/RepoPrompt/Features/Settings/Views/AgentModelsSettingsView.swift` | Scoped guidance editor. |
| `Sources/RepoPromptSettingsCore/GlobalSettingsDocument.swift` | Both fields, normalization/decoding, schema 13 constant, retained-profile version detection. |
| `GlobalSettingsStore` / effective-profile persistence owners (resolve by symbol) | Round-trip both fields via existing mutation mechanisms; publish existing change signals. |
| `AgentModeViewModel+Routing.swift`, `AgentModeViewModel+UsageBalancing.swift` | Carry `repromptedText` through the wrappers. Auto Effort judges `automationJudgingText` instead of `rawDraftSnapshot` (`:299–302`), with the oversized fallback. Add an optional `precomputedRouting:` parameter for speculation reuse. |
| `Features/AgentMode/Routing/AgentAutomationTurnAudit.swift` | Optional non-content `reprompt` feature record. |
| `Features/ContextBuilder/ViewModels/ContextBuilderAgentViewModel.swift` | Non-MCP `runContextBuilderForReprompt` wrapper over the `runContextBuilderForMCP` core; per-run `PromptEnhancementMode.preserve` override (add to the run-behavior type if absent). |
| `Features/Chat/ViewModels/Oracle/OracleViewModel+MCP.swift` | None expected: `tool_chatSend` with background activation and a frozen `OracleSendTabContext`. Add a title hint only if one isn't already supported. |
| `Infrastructure/AI/Providers/ClaudeCode/ClaudeAgentToolPreferences.swift` / `ClaudeCodeProvider.swift` | Only if needed: let the Re-prompt call request `.nativeSystemPrompt` delivery; private temp cwd if step 1 finds the side call runs in a workspace root. |
| `AgentModeViewModel.swift` `augmentUserMessageForProviderSend` (`:20622`, slash expansion `:20743+`) | Provenance flag to skip slash expansion for replacements. |
| `docs/privacy/*` | Describe the Re-prompt side call. |
| Explicit Stop and window/session lifecycle entry points (resolve by symbol) | Cancel preparation without creating run attempts; no polling. |

### New files (proposed paths)

| File | Responsibility |
|---|---|
| `Sources/RepoPrompt/Features/AgentMode/Models/AgentRepromptModels.swift` | Request/result, validation, approved-turn value, phase/error enums, stable rendering. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRepromptService.swift` | Isolated first/refinement calls, timeout, decoding, injectable transport. |
| `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRepromptContextConsultant.swift` | Manifest building; Oracle consult and Context Builder run orchestration; selection snapshot/restore; result truncation; cancellation. Injectable for tests. |
| `Sources/RepoPromptSettingsCore/AgentRepromptContextPolicy.swift` | `automatic` / `never` enum and lenient decoding. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+Reprompt.swift` | Operation lifecycle, eligibility, context capture/compare, wizard handling, review actions, one-shot completion. |
| `Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentRepromptUIStore.swift` | Presentation store separate from pill snapshot and runtime interactions. |
| `Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentRepromptSheet.swift` | Progress, clarification, review/edit, failure UI. |
| `Sources/RepoPromptSettingsCore/AgentRepromptGuidance.swift` | Default text, normalization, size limit. |

### Intentionally unchanged

`AgentModeRunService.swift`, `AgentModeViewModel+SessionLinkSend.swift`, `AgentSessionLinkManagedSteer.swift`, `AgentWorkflow.swift`, `OracleExecutionResolver.swift` (not used for the rewrite; consults use the normal Oracle path), `UserInteractionModels.swift` (reuse only), `AgentChatItem` persistence, Router decision policies and backends (`ModelRouterDecisionPolicy`, `AutoEffortDecisionPolicy`, Decisions/Jev services).

## 5. Execution index

| # | Work item | Goal | Done when | Key files | Deps | Size |
|---|---|---|---|---|---|---|
| 1 | Resolve remaining owners + verifications | Pin the presentation host, `GlobalSettingsStore`/profile persistence owners, and Stop/teardown hooks. Confirm schema 13 is unclaimed. Verify the Claude Code side-call cwd and per-call `.nativeSystemPrompt` delivery. Confirm whether Context Builder's run behavior accepts a per-run enhancement-mode override, and whether `tool_chatSend` supports background activation and a title hint. | Remaining "resolve by symbol" rows have paths; findings recorded in this plan | — | — | S |
| 2 | Settings contracts + schema 13 | Guidance persisted globally and per workspace | Round-trip, old-data decode, required-version tests pass at real load/save boundary | `GlobalSettingsDocument.swift`, `AgentRepromptGuidance.swift`, store | 1 | M |
| 3 | Models + rewrite service | Stateless rewrite calls on every provider family, with strict validation | Message-level and per-provider-family capture shows only contract+guidance+text+manifest (+answers/consults); system prompt delivered on Claude Code (native), Codex (`baseInstructions`), ACP, and Devin; validation/timeout/cancel tests pass | `AgentRepromptModels.swift`, `AgentRepromptService.swift` | 1 | M |
| 3b | Context consultant | Discretionary Oracle / Context Builder consults | Consult tests: none/oracle/CB/both, concurrency with questions, Skip, failure-non-fatal, selection restore rules, prompt never rewritten (`preserve`), cancellation | `AgentRepromptContextConsultant.swift`, `ContextBuilderAgentViewModel.swift` | 1, 3 | M |
| 4 | Operation state + UI store (disabled by default) | Lifecycle, freshness, edited-brief recovery without touching submission | Freshness/one-shot/recovery tests pass; normal submission unaffected | `AgentModeViewModel+Reprompt.swift`, `AgentRepromptUIStore.swift` | 2, 3, 3b | M |
| 5 | Composer integration (atomic) | Approved text flows to every provider route exactly once | Per-wrapper carry tests, submission/steering/slash tests, and session-link isolation tests pass | `AgentModeViewModel.swift`, `+Routing.swift`, `+UsageBalancing.swift`, Stop hooks | 4 | L |
| 5b | Router / Auto Effort integration | Frictionless automation on approved text | Auto Effort judges the approved text with oversized fallback; speculation is reused on unedited Send and discarded on edit/stale; audit records written; no new UI | `+Routing.swift`, `AgentAutomationTurnAudit.swift` | 5 | M |
| 6 | Pill, sheet, banner, settings editor | User-facing surface | Presentation tests pass; manual checks in §6.3 | pills, `AgentRepromptSheet.swift`, wizard, settings view/VM, `docs/privacy` | 2, 4 (sheet can be built against fake operations); wire-up after 5 | M |
| 7 | Verification | Prove release acceptance | All §6 commands green | — | 1–6 (incl. 3b, 5b) | S |

## 6. Verification

### 6.1 New XCTest suites

| Path | Coverage |
|---|---|
| `Tests/RepoPromptTests/AgentMode/AgentRepromptServiceTests.swift` | Primary-model-only. Request capture at `AIMessage` level and per provider family (Claude Code native system prompt, Codex `baseInstructions`, ACP, Devin): declared inputs only, empty `transientImages`. Manifest caps. First vs refinement payloads, incl. custom-answer serialization and consult results. Goal-only response valid. `contextRequests` validation (rejected on refinement). JSON validation. API 60 s / CLI 120 s timeouts. Cancellation, incl. a fake provider that ignores cancel. Bounds. Policy `never` omits manifest and context-request rules. |
| `Tests/RepoPromptTests/AgentMode/AgentRepromptContextConsultantTests.swift` | Oracle-only, CB-only, both (concurrent), none. Consults run concurrently with clarification. Skip context. Non-fatal failure/timeout. Oracle background activation + frozen tab context. CB `clarify` + `preserve` (tab prompt unchanged). Selection kept on approval; restored on cancel/invalidation only if unchanged since commit. Result truncation markers. Late results ignored. |
| `Tests/RepoPromptTests/AgentMode/Routing/AgentRepromptRoutingIntegrationTests.swift` | Router judges the approved text. Auto Effort judges the approved text (regression for the `rawDraftSnapshot` read) and falls back to the original over 4,000 chars. Speculation reused on byte-identical Send with same revision/backend/candidates; discarded on edit, revision change, or candidate change; cancelled on every preparation exit; distinct request ID from `claim.attempt.id`. Model change during review doesn't invalidate. Router stale checks and rollback still apply. Audit fields. |
| `Tests/RepoPromptTests/AgentMode/AgentRepromptSubmissionTests.swift` | Eligibility; mandatory approval; raw draft preservation; invalidation (tab/workspace/draft/selection/user model change/captured-scope settings change/run transition) vs non-invalidation (other-scope settings, streaming); edited-brief recovery banner + restore; claim release on every exit; replacement carried through hydration/routing/Auto Effort/usage-balancing wrappers; workflow/Interview/CU ordering; attachments; active steering; slash-expansion bypass + slash precondition; automation after approval |
| `Tests/RepoPromptTests/AgentMode/SessionLinks/AgentRepromptSessionLinkIsolationTests.swift` | Idle send + managed steer bypass; enabled state unchanged; zero side calls; pending local claim respected |
| `Tests/RepoPromptTests/Settings/AgentRepromptSettingsTests.swift` | Draft/save/default; stale-scope conflict; global/workspace copies; unrelated writes preserve guidance |
| `Tests/RepoPromptSettingsCoreTests/AgentRepromptGuidanceTests.swift` | Guidance default, normalization, size; `AgentRepromptContextPolicy` lenient decoding |
| `Tests/RepoPromptSettingsCoreTests/AgentRepromptSchemaTests.swift` | Old decode; round-trip; required version; retained workspace overrides; rollback fence |
| `Tests/RepoPromptTests/AgentMode/ToolCards/AgentRepromptPresentationTests.swift` | Wizard without countdown/with fixed pulse; no preselection; skips; review actions; blank/oversized validation; disclosure acknowledgement persistence/reset. Use existing view-test facilities where available; otherwise test sheet behavior through the operation and `AgentRepromptUIStore`, not SwiftUI views |

Also update existing submission, pill-snapshot, settings-codec, and wizard regression suites affected by new initializer parameters/fields.

### 6.2 Commands

```bash
make dev-test FILTER=AgentRepromptServiceTests
make dev-test FILTER=AgentRepromptContextConsultantTests
make dev-test FILTER=AgentRepromptRoutingIntegrationTests
make dev-test FILTER=AgentRepromptSubmissionTests
make dev-test FILTER=AgentRepromptSessionLinkIsolationTests
make dev-test FILTER=AgentRepromptSettingsTests
make dev-test FILTER=AgentRepromptGuidanceTests
make dev-test FILTER=AgentRepromptSchemaTests
make dev-test FILTER=AgentRepromptPresentationTests
make dev-test          # full suite
make dev-lint
make dev-build && make dev-smoke   # live CE app check (Agent Mode change)
```

### 6.3 Manual checks

Two windows preparing independently; new window doesn't re-show disclosure; new-worktree first send; primary Oracle on each provider family (API, Claude Code, Codex CLI, Cursor/OpenCode, Devin) produces a valid brief; vague repo-specific prompt triggers a consult and the brief uses codebase names; clear prompt triggers no consult; Skip context mid-Context Builder; Router + Auto Effort on: unedited Send has no visible routing wait, edited Send routes normally, follow-up turn Auto Effort judges the brief; model change during review keeps the sheet; tab/workspace switch during request and during review; Stop during each phase; unavailable credentials (pill warning + failure UI); active steering; text+attachments; every slash route; Interview + workflow together; natural run completion during review (invalidates); text scaling, keyboard dismissal (Esc = Cancel), accessibility labels.

### 6.4 Release acceptance

- An eligible local prompt causes **no** implementing-provider call before approval.
- Cancellation leaves composer content and selections intact.
- Approved text reaches every provider route exactly once.
- Session-link / noncomposer traffic causes zero Re-prompt requests.
- Captured rewrite payloads contain only the declared inputs: text, manifest (unless `never`), guidance, answers, and consult results. They never include conversation history or attachments.
- With the Router and/or Auto Effort enabled, automation judges the approved brief and Re-prompt adds no extra prompts. An unedited Send reuses speculation.

## 7. Tradeoffs and rejected alternatives

- **Hook in `AgentModeRunService`** — rejected: provider-wide, post-commit, can't host interactive review, and would catch session-link traffic.
- **Run as a visible child agent session with `ask_oracle`/`context_builder` tools**: rejected. It clutters the session list, makes an open-ended tool loop hard to bound in time and cost, and needs MCP plumbing per provider. A structured `contextRequests` response that the app executes gives the rewriter the same discretion with hard limits (one round, ≤1 of each consult) and works identically on every provider.
- **Router judges the original text**: rejected. The brief is the better signal; the original is only a fallback for Auto Effort's size limit.
- **Speculating before review** (on the first result): rejected. Briefs often change after clarification or refinement, which would waste a judgment.
- **Reuse `OracleExecutionResolver.resolve(.automatic)`** — rejected: brings presets, extra lanes, and prompt context.
- **Auto-send without review** — rejected: no mechanical drift detection; review is the core anti-micromanagement safeguard.
- **Refinement from first response** — rejected in favor of original + Q/A to avoid compounded drift.

## 8. Risks and migration

- **Settings compatibility:** old docs decode with nil guidance; no eager rewrite. A non-blank override requires schema 13 so older codecs reject instead of silently dropping it. Rollback to a schema-12 build may make the document unavailable to that build — keep existing unsupported-document safeguards; never auto-downgrade or strip. Test at the real store load/save boundary and confirm the store advertises schema-13 support.
- **Meaning drift:** mitigated by mandatory editable review, not by guidance alone.
- **Latency/cost:** up to two primary-Oracle rewrite requests plus at most one Oracle consult and one Context Builder run (30 s–5 min). Mitigations: guidance biases toward no context, consults overlap with clarification, Skip context is always available, and the `never` policy exists. Router speculation adds at most one wasted 5 s Decisions judgment on edited sends.
- **Context Builder side effects:** selection commit and run history persist. The prompt is never rewritten (`preserve`), and the selection is restored on cancel. If no per-run enhancement override exists, adding one is in scope (step 3b).
- **Consult findings inflating scope:** the fixed contract treats them as context, not requirements, and review is the backstop.
- **Stale submission:** long reviews widen races → immutable context, held claim, eager invalidation, post-await checks are mandatory.
- **Unexpected command execution:** classify only original input; suppress slash expansion for replacements.
- **Context leakage:** verify the actual rewrite payload. The rewrite must not use normal Oracle prompt packaging; repo content reaches only the consults, which use their normal paths.
- **Recovery assumptions:** downstream branches of `submitPreparedUserTurn` beyond the reviewed range must be tested with replacement provider text and original restoration text.

## Implementation ledger

### Progress and deviations

- Step 2: schema 13 plus both scoped fields, typed decoding, normalization, effective-profile assembly and writes implemented. Added `AgentRepromptGuidanceTests` and `AgentRepromptSchemaTests`, including real store reload/reset/retained-profile checks. Coordinated validation initially found a test-only existential initializer error; corrected to `GlobalSettingsFileStore(...)`; explicit module rerun passed (3 tests, zero failures): `make dev-test MODULE=RepoPromptSettingsCoreTests FILTER='AgentReprompt(Guidance|Schema)Tests'`. Regex-only filter did not resolve the app-free owner and unnecessarily built the app; its service compiler diagnostic was corrected before subsequent app validation. Validation generated an unrelated `Package.resolved` update; restored it rather than shipping dependency drift. The user-requested plan requires a durable-doc allowlist entry; the seven requested app-boundary suites require the exact +7 test-import ratchet ceiling (no source-size ratchet relaxation).
- Open PRs touching settings (#1339, #854, #344) were inspected via read-only `gh pr diff`; none introduces a schema-version constant or claims schema 13.
- Formatter deviation: conductor's `format` command does not accept file paths. Used `swiftformat <explicit changed paths> --config .swiftformat` rather than reformatting the whole repository; final lint remains daemon-coordinated.
- Step 3b correction: `.preserve` controls generated instructions but terminal Context Builder commit still installs tool-authored prompt text and an empty-prompt output fallback. Re-prompt adds an internal per-run exact-preservation commit policy; ordinary Context Builder behavior remains unchanged. Its non-MCP wrapper uses a private token internally to reuse existing generation-safe run ownership, never a caller-supplied MCP token.

### Validation ledger

- Step-2 checkpoint: `ae32ef1aa` (`feat(agent): persist scoped Re-prompt settings with schema 13`); staged-index secret scan and repository preflight passed. Settings suites passed 3/3 in coordinated ticket `c3dd3a91-c2ea-46ca-92e7-64db0846f464`.
- `make dev-swift-build PRODUCT=RepoPrompt`: ticket `ad9f17b6-5941-42d5-825e-f4b4f14e3034` failed before app compilation: pinned `swift-http-types` 1.5.1 declares no traits but `swift-nio-extras` requests `FoundationURL`. Coordinated Xcode test backend resolves 1.8.0; its lockfile changes are validation-only and must be restored before checkpointing. No dependency change is intended in this feature branch.
- Compiler iteration: fixed `ConversationEntry.Role.user` typing and split a ternary out of a guard because SwiftFormat's `andOperator` rule converted its `&&` expressions into invalid guard commas.
- Provenance deviation: shared queued steering crosses the run service's input-assembly hook. Correct slash-expansion suppression therefore requires a default-false, non-content provenance bit on queued instructions and the assembly hook, including a small `AgentModeRunService` change; the service still never invokes or observes Re-prompt preparation. ACP batches separate ordinary input from approved replacements.
- Extracted the existing pure MCP context-hint matcher into its own small extension so the existing 5,000-line source-file ratchet remains unchanged after formatting the modified context owner.

### Automation and privacy corrections

- Candidate opaque keys are freshly randomized on every builder call. Speculation therefore retains the exact staged opaque-key/target pairs and validates their authoritative metadata snapshot, role defaults, configuration/backend, and usage revision instead of regenerating different keys for comparison. It also replays the captured usage-balancing arithmetic before reuse, including time-sensitive quota changes. Ownership, stale checks, application and rollback still use the normal composer path.
- Speculative Auto Effort uses a separate request ID and does not publish `session.autoEffortJudgmentID` or a spinner while review is open. Approved-text size fallback uses the original raw draft; source command classification and draft restoration remain original-only.
- The plan's sentence that review edits go “only to the implementing agent” conflicts with its requirement that enabled Router/Auto Effort judge the approved edited brief. Privacy copy is explicit: edits are never sent back to the rewrite model, but opted-in decision services receive their ordinary approved-text judgment input.
- Ticket `6728835b-2ccc-43fd-9960-d7cce49fbdf3` compiled the app and ran 14 focused tests: all five consultant tests passed; five service/operation cases failed because their fixture referenced removed catalog model `gpt-4o`. Replaced that fixture with the current built-in `gpt61Sol`; rerun is required.

- Step-3b checkpoint: `ced6330b0`; mandatory staged-index preflight passed. Ticket `10bc8153-422e-4a56-82ff-a2d6d4a6d70a` compiled the application and all tests, and passed service (6), consultant (5), session-link isolation (3), settings-core (3), and most submission/routing cases. Two fixture failures were corrected: active steering needs a real persistent session binding before minting a composer target; Auto Effort must choose a model supported by its policy, not merely one advertising effort controls. Focused rerun pending.

### Step 1 — owner verification (2026-10-20)

- Settings authority: `Sources/RepoPromptSettingsCore/GlobalSettingsStore.swift` (`globalAgentModelsProfile`, `setGlobalAgentModelsProfile`, `normalizedAgentModelsProfile`); profile/scalar codecs in `GlobalSettingsDocument.swift`. Schema 13 is unclaimed in this base (current is 12); open-PR file checks are recorded with subsequent validation.
- Presentation host: `Features/AgentMode/Views/AgentInputBar.swift`; held claim lifecycle is `executeComposerSubmitAttempt` in `AgentModeViewModel.swift`. Explicit Stop: `cancelAgentRun`; window teardown: `prepareForWindowClose` in that same owner.
- Claude factory builds `ClaudeCodeProvider()` with nil working directory; `CLIProcessConfiguration.resolvedWorkingDirectory(nil)` resolves to the temporary directory, not the workspace. Native delivery currently reads a global preference inside `completeMessage`; a request-local override is required, without mutating the preference.
- Context Builder's `ContextBuilderRunBehavior` already has an enhancement mode, and its DEBUG convenience entry demonstrates constructing `.preserve` per run. Production entry takes resolved authority and a control token, so a non-MCP wrapper must reuse that core with private ownership.
- Oracle `OracleSendTabContext` supports `.background`; `tool_chatSend` already accepts `chat_name`, so no title-hint API addition is needed.
- Maintainer-guidance check: mandatory review is the user-intent authority; held composer claim and captured context protect state; side calls must be bounded/observable and must not acquire noncomposer authority. Validation targets the actual settings and composer boundaries, not a parallel submission path.

## 9. Open questions

None that block implementation. Step 1 verifications (Claude Code cwd, per-run Context Builder enhancement override, Oracle background activation/title) can each widen a work item but don't change the design.

## References

- `docs/architecture/source-layout.md`, `docs/architecture/provider-plugins.md`, `docs/architecture/agent-session-oversight-auto-wake.md`
- Workflow clarification precedents: `Sources/RepoPromptShared/Workflows/WorkflowPrompt+Build.swift`, `+Optimize.swift`, `+DeepPlan.swift`, `+Reminder.swift`
