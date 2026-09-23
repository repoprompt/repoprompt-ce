## Final Prompt
<taskname="Devin ACP effort+permissions rewrite"/>

<task>
Produce a MINIMAL, from-scratch rewrite plan (ordered commit list, exact files/functions, test list, diff-size estimate, risks) for the RepoPrompt CE Devin ACP integration, targeting origin/main (merge-base 4232fc4ba6). Two goals only:

1. **Reasoning effort works for Devin.** Devin's ACP session advertises a `thought_level` config option (category `thought_level`, values none|low|medium|high|xhigh|max) that is INDEPENDENT of the model id and MUST be applied via `session/set_config_option` AFTER model selection (setting `model` resets `thought_level` back to `medium`).
2. **Devin ACP permissions work correctly**, including in enterprise environments where org policy forbids `bypass` (and `autonomous`). Map onto ADVERTISED ACP modes only; when a requested mode isn't advertised or is policy-refused, fail clearly or fall back deterministically (decide + justify); "Full Approval" without `bypass` likely means relying on Devin's own `--config` allow-rules, not RepoPrompt sending a forbidden mode.

Do NOT implement yet — this is a plan only. The branch `fix/devin-acp-permission-gaps` (+1678/−110, 13 commits, currently checked out in this working tree) is being DISCARDED for being too large; its already-landed changes (visible in the files below) are reference for what NOT to repeat — see `<avoid>` below. The plan must target a fresh, small diff against origin/main (well under ~500 changed lines total including tests).
</task>

<empirical_facts>
Live-probed against real `devin acp` (Devin CLI 3000.11.1, enterprise account) via raw JSON-RPC — ground truth, overrides any comment/assumption in the code below:

- `session/new` result has `configOptions` (modern shape), categories: `mode` (accept-edits|smart|ask|plan — NOT bypass), `model` (ids like `gpt-5-6-sol-medium`; suffix does NOT change with effort), `thought_level` (none|low|medium|high|xhigh|max, current `medium`), `speed` (standard|fast). No legacy `models` field.
- `session/set_config_option` thought_level=high → thought_level becomes high, model unchanged. Setting `model` RESETS thought_level to `medium` — effort must be (re-)applied AFTER model.
- Setting mode to `bypass` or `autonomous` when org policy forbids it → JSON-RPC error -32602, data `"Mode 'bypass' is restricted by your organization's policy"`. `smart` succeeds.
- `devin --permission-mode dangerous acp` / `DEVIN_PERMISSION_MODE=dangerous devin acp` / `devin --sandbox acp`: all INERT for ACP — session mode stays whatever it was (e.g. `accept-edits`). The launch flag never reaches the ACP session.
- `devin --config <file> acp` IS honored: `permissions.allow: ["exec"]` in that file makes exec run with no `session/request_permission` at all. This is the real lever for unattended/bypass-forbidden full access.
- Permission-request options: `{allow_once, kind allow_once}`, `{allow_session, kind allow_always, "...this session"}`, `{allow_always, kind allow_always, "...in ws"}`, `{allow_always_global, kind allow_always}`, `{reject_once, kind reject_once}`. `kind` is NOT a reliable scope signal (allow_session is typed allow_always) — selection must be by exact `optionId`, e.g. `allow_once`.
</empirical_facts>

<current_state_in_selection>
The selected files are the CURRENT working tree (= old branch + main), not origin/main. Treat everything below as "what exists today, which the plan must reconcile against a clean origin/main baseline" — re-run `git diff mergebase:origin/main` yourself once git tooling is available to see the exact 1678/−110 lines, since the git tool was unavailable during this discovery pass (blocked with "Context Builder review target election is deferred").

Key architecture (all present in the selection):
- `ACPAgentProvider` protocol (`Features/AgentMode/Providers/ACP/ACPAgentProvider.swift`) already has a **generic, provider-agnostic parameterized-model-picker seam**: `supportsParameterizedModelPicker: Bool` + `modelParameterKind(for: ACPModelParameterClassificationInput) -> ACPModelParameterKind?`. `ACPAgentSessionController` (slices included) uses this to: advertise `_meta.parameterizedModelPicker` capability at `initialize` (~line 560), parse non-model/non-mode `select`-type `configOptions` into `ACPModelParameterSet`/`ACPModelParameterDefinition` (`parseModelParameterSets`, ~3024), and apply selections via `session/set_config_option` in `applySessionModelParameterSelections` (~1057).
- **OpenCode already implements exactly Devin's shape**: `OpenCodeACPAgentProvider.modelParameterKind` returns `.thinking` when `category == "thought_level" || configID == "effort"` — this is the pattern to copy for Devin (Devin's own configID is likely also `"thought_level"` per the empirical facts above; confirm the exact id/category pair against a live session before hardcoding).
- **`DevinACPAgentProvider` currently opts OUT deliberately**: comment says "Devin advertises complete model-and-effort variants as model choices; it deliberately does not opt into ACP's separate parameter picker" — THIS ASSUMPTION IS WRONG per the empirical facts (thought_level is a real, independent config option). `ACPModelParameterResolver.supportsModelParameters(_:)` and `.parameterSet(providerID:...)` (`AgentModelParameter.swift`) both hard-exclude `.devin`, and `AgentMCPModelParameterSupport.unsupportedModelParametersMessage` has a Devin-specific "combined model variants" error string — all three need to flip to `true`/route to Devin once Devin opts in, mirroring OpenCode's classification, not Cursor's static-catalogue path.
- **Mode/permission mechanism already generic**: `ACPAgentSessionController.setSessionMode(_:)` → `setSessionModeSerialized` sends `session/set_config_option` for the `mode`-category selector and validates the requested value against the live advertised snapshot (`canonicalSessionModeValue`) before sending — it already fails closed on an unadvertised mode. It does NOT yet know how to handle the org-policy -32602 refusal distinctly from "not advertised" — check `applyVerifiedConfigOptionsMutationResponse`/error mapping and decide if a policy-refusal needs a distinguishable, actionable error message (empirical fact: refusal message is `"Mode 'X' is restricted by your organization's policy"`).
- **`DevinAgentToolPreferences.PermissionLevel`** (5 cases: providerDefault/normal/acceptEdits/smart/fullApproval) already maps `sessionModeID` (ACP mode to send) separately from `cliPermissionMode`/`launchArguments` (the inert `--permission-mode` flag) and separately from `unattendedSessionModeID`/`unattendedCLIPermissionMode` (headless path). Compare against `OpenCodeAgentToolPreferences.PermissionLevel` (2 cases, `sessionModeID` only, no launch flag at all) as the simpler reference shape — decide whether Devin's `cliPermissionMode`/`launchArguments`/`isRecognizedCLIPermissionMode` plumbing (used only because the flag is inert for ACP and was believed to matter for the one-shot CLI and controller-reuse key) should be dropped from the interactive ACP path entirely (req: "decide whether the inert flag should be dropped from the interactive launch/reuse key"). Note `DevinCLIProvider` (one-shot, non-ACP path) legitimately still needs `--permission-mode` since that CLI mode is a different, non-ACP code path where the flag is NOT inert.
- **Live mode application bug, confirmed**: `AgentModeProviderBindingService.providerPreferenceChanged` has a working pattern for `.openCode, .antigravity` — call `controller.setSessionMode(runtime.acpSessionModeID)` live when the level changes mid-run. The `.devin` case does NOT do this; its comment claims "Devin's level is likewise a launch-time flag, so the running process cannot be re-flagged" and only settles a pending approval, never calls `setSessionMode`. This is wrong per the empirical facts (ACP mode IS live-mutable for Devin) and is the likely root cause of "permissions work correctly" failures. `AgentProviderPermissionProfile.acpSessionModeID(for:)` also returns `nil` for `.devin` — trace whether this needs to start returning Devin's `sessionModeID` so the `.devin` case in the binding service can mirror `.openCode`/`.antigravity`.
- **Auto-approval for RepoPrompt's own MCP tool calls**: `ACPAgentSessionController.autoApprovalSelection`/`preferredAllowOptionID` (slices ~3480-3720) and `ACPPermissionOptionPolicy` (`ACPProviderSupport.swift`, fully included) already run for Devin (no `providerID != .devin` guard currently found in this tree — confirm against origin/main whether that guard exists there and needs removing, or whether it was already removed by the old branch and should just be kept absent). `ACPPermissionOptionPolicy.isAutoSelectable`/`denylistedAutoSelectOptionIDs` contains Devin-specific `switch_*`/`plan_*`/`*_global`/`*_always` pattern rules — see `<avoid>` below on whether this open-ended denylist is proportionate or whether a narrower "select `allow_once` by exact optionId only, else decline" rule suffices for RepoPrompt's own strict MCP auto-approval (req #3 explicitly calls for optionId `allow_once` only, never kind-based, for Devin).
- **Headless/one-shot paths**: `DevinACPHeadlessAgentProvider.makeRunRequest` computes `sessionModeID`/`launchPermissionMode` from `unattendedSessionModeID`/`unattendedCLIPermissionMode`, applies model then mode in `beforePrompt` (already correctly ordered relative to the new effort requirement: model must still precede effort). `DevinCLIProvider` (true one-shot, no ACP) already resolves its flag via `DevinAgentToolPreferences.unattendedLaunchPermissionMode()` (already fixed relative to the old branch's claimed "hardcodes auto" bug — verify against origin/main whether that bug still exists there).
- `DevinModelDiscoveryService` runs a throwaway ACP session to discover models; unaffected by effort work except if `supportsParameterizedModelPicker` becomes true (check it still counts `options.count` correctly and doesn't need to also probe thought_level).
- `ACPAgentProviderFactory.makeProvider` constructs `DevinACPAgentProvider` — no permission input, per-run `ACPRunRequest.launchPermissionMode` is authoritative; unaffected by this plan except if the inert flag is dropped from `ACPRunRequest`/reuse key.
- `DevinHeadlessSessionModeBoundaryTests.swift` (full, included) is the existing scripted-Devin-ACP test harness (fakes `session/new`/`session/set_config_option`/`session/prompt` over stdio) — reuse this harness's pattern (`advertisedModes:` parameter, Python fake server) for new focused tests rather than inventing a new harness.
</current_state_in_selection>

<avoid>
Things the discarded branch added that must NOT come back unless the plan proves a concrete failure requires them:
- Unicode option-label sanitizer + its tests.
- Open-ended `switch_*`/`plan_*` pattern denylists in `ACPPermissionOptionPolicy` (current form in `ACPProviderSupport.swift`) — re-justify against the narrower "optionId `allow_once` only" rule from req #3 before keeping any of this.
- Long duplicated doc-comment essays (visible throughout `ACPAgentSessionController.swift`, `DevinAgentToolPreferences.swift` in this selection) — new code should be commented proportionately, not at this density.
- One-caller wrappers, many `#if DEBUG test_*` seams beyond what's needed to reuse the existing seams shown in the `ACPAgentSessionController.swift` slice (~4390-4433) and `DevinHeadlessSessionModeBoundaryTests.swift`.
- A large bespoke scripted-ACP test harness — reuse `DevinHeadlessSessionModeBoundaryTests.swift`'s existing harness/pattern instead of writing a new one.
- Unrelated MCP client-identity normalization work, resume-guard complexity, and `DevinPermissionLevelTests.swift`'s scale (1542 lines — NOT included here; too large, and its size itself is a symptom of the branch's bloat) — a rewrite's Devin permission tests should be far smaller and targeted, added to (or alongside) that file's existing `Level` unit tests, not a wholesale replacement.
- Assuming Devin's model ids encode effort ("combined model-and-effort variants") — empirically false; delete every comment/guard built on that assumption (`DevinACPAgentProvider`, `ACPModelParameterResolver.supportsModelParameters` doc comment, `AgentMCPModelParameterSupport.unsupportedModelParametersMessage`).
</avoid>

<not_yet_read_but_possibly_relevant>
- `AgentModelsSettingsViewModel.swift`, `AgentModeViewModel+MCPModelParameters.swift`, `AgentInputBar.swift`/`AgentModelsPopoverView.swift` (UI layer consuming `ACPModelParameterSelection`/`.thinkingPin`) — only needed if the plan decides Devin's effort picker needs UI wiring beyond what OpenCode's already does generically; check whether OpenCode's UI path is already provider-agnostic enough that Devin opting in via `supportsParameterizedModelPicker` is sufficient with zero UI changes.
- `DevinPermissionLevelTests.swift` (1542 lines) and `DevinACPParameterBindingTests`-equivalent for Devin (does not yet exist; `CursorACPParameterBindingTests.swift` is the pattern for Cursor/OpenCode) — read the relevant existing test slices directly before writing new tests.
- `AgentACPModelRegistry` (referenced by `publishDiscoveredSessionModelsIfGloballyAuthoritative`) — the warm-registry path for providers that do NOT support the parameterized picker; confirm this stops being hit for Devin once it opts in (mirrors Cursor/OpenCode already skipping it).
</not_yet_read_but_possibly_relevant>

<deliverable>
Produce, as your response, NOT code:
1. An ordered list of small, independently-reviewable commits (5-10 commits expected), each with exact files/functions touched.
2. What gets deleted vs. kept from the current tree (main) for each touched file.
3. A test list (which existing test files gain cases vs. which new small test file(s), if any) reusing `DevinHeadlessSessionModeBoundaryTests.swift`'s harness pattern.
4. Estimated diff size per commit and total (target: well under ~500 lines including tests).
5. Explicit decisions (with justification) for the two open design questions the empirical facts raise: (a) what "Full Approval" means when `bypass`/`autonomous` are policy-forbidden and not advertised, (b) whether to drop the inert `--permission-mode` flag from the interactive ACP launch/controller-reuse key (`isCompatibleWith`, `normalizedLaunchPermissionMode`) while keeping it for the genuinely-non-ACP `DevinCLIProvider` one-shot path.
6. Open risks / unknowns that should be verified live against `devin acp` before or during implementation (e.g. exact Devin `configOptions` id/category strings for `thought_level`, exact error shape for policy-refused modes beyond the -32602 message already captured).
</deliverable>


## Selection
- Files: 24 total (18 full, 2 slice, 4 codemap)
- Total tokens: 75647 (Auto view)
- Token breakdown: full 48617, slice 21312, codemap 5718
- Token accounting: fresh from active_tab_published

### Files
### Selected Files
├── Sources/
│   └── RepoPrompt/
│       ├── Features/
│       │   └── AgentMode/
│       │       ├── Models/
│       │       │   └── ModelSelection/
│       │       │       └── AgentModelParameter.swift — 2,777 tokens (full)
│       │       ├── Providers/
│       │       │   └── ACP/
│       │       │       └── ACPAgentProvider.swift — 3,617 tokens (full)
│       │       └── Runtime/
│       │           └── ProviderBindings/
│       │               ├── AgentModeProviderBindingService.swift — 3,872 tokens (full)
│       │               ├── AgentProviderBindingModels.swift — 3,236 tokens (full)
│       │               └── AgentProviderPermissionProfile.swift — 1,712 tokens (full)
│       └── Infrastructure/
│           ├── AI/
│           │   ├── ACP/
│           │   │   ├── ACPAgentProviderFactory.swift — 739 tokens (full)
│           │   │   ├── ACPAgentSessionController.swift — 18,504 tokens (lines 190-450 (AutoApprovalSelection struct decl; isCompatibleWith() controller-reuse key incl. Devin launch-permission-mode comparison; normalizedLaunchPermissionMode() — central to deciding whether to drop the inert --permission-mode from the reuse key), 530-580 (ACP initialize handshake: sends _meta.parameterizedModelPicker capability flag gated on provider.supportsParameterizedModelPicker — Devin must opt in here for req #1), 740-1420 (Core model/mode mutation pipeline: setSessionModel/setSessionModelViaConfigOptionsRPC, discoverSessionModelParameters, applySessionModelParameterSelections (generic model-parameter apply flow used by Cursor/OpenCode — Devin should reuse this for thought_level), setSessionMode/setSessionModeSerialized (generic session/set_config_option mode mutation against advertised snapshot), and respondToPermissionRequest (calls preferredAllowOptionID for accept decisions)), 2140-2260 (validateResumedSessionPermissionPolicy (Devin-specific bypass-resume guard) and validatePromptModelParameterSelections (live-authority re-check before every prompt) — both prompt-time guards that must be re-derived for the new plan), 2960-3060 (parseModernModelSnapshot/parseModelParameterSets — parses ACP configOptions (category=model/mode/thought_level) into ACPDiscoveredSessionModels/ACPModelParameterSet; this is where Devin's thought_level config option becomes visible to the generic mechanism once supportsParameterizedModelPicker=true), 3480-3720 (preferredAllowOptionID (session-scoped vs accept fallback selection, delegates to ACPPermissionOptionPolicy in ACPProviderSupport.swift) and autoApprovalSelection (matches RepoPromptPermissionAutoApprovalMatch against options) — req #3 (strict auto-approval via optionId allow_once for Devin) lives here), 4390-4433 (#if DEBUG test seams (test_autoApprovalSelection, test_preferredAllowOptionID) — existing seams the new focused tests should reuse rather than adding new ones))
│           │   │   └── ACPProviderSupport.swift — 6,954 tokens (full)
│           │   └── Providers/
│           │       ├── Cursor/
│           │       │   └── CursorACPAgentProvider.swift — 2,458 tokens (full)
│           │       ├── Devin/
│           │       │   ├── DevinACPAgentProvider.swift — 1,943 tokens (full)
│           │       │   ├── DevinACPHeadlessAgentProvider.swift — 1,365 tokens (full)
│           │       │   ├── DevinAgentConfig.swift — 280 tokens (full)
│           │       │   ├── DevinAgentToolPreferences.swift — 2,800 tokens (full)
│           │       │   ├── DevinCLIProvider.swift — 2,968 tokens (full)
│           │       │   └── DevinModelDiscoveryService.swift — 1,247 tokens (full)
│           │       └── OpenCode/
│           │           ├── OpenCodeACPAgentProvider.swift — 1,605 tokens (full)
│           │           └── OpenCodeAgentToolPreferences.swift — 1,123 tokens (full)
│           └── MCP/
│               ├── Agent/
│               │   └── AgentMCPModelParameterSupport.swift — 4,216 tokens (full)
│               └── MCPIntegrationHelper.swift — 2,808 tokens (lines 85-340 (RepoPromptPermissionAutoApprovalMatch struct, isRepoPromptServerIdentifier(), repoPromptPermissionAutoApprovalMatch() — shared auto-approval matching logic consumed by ACPAgentSessionController.autoApprovalSelection(); req #3 needs Devin's optionId-only (allow_once) selection through this path))
└── Tests/
    └── RepoPromptTests/
        └── AgentMode/
            └── DevinHeadlessSessionModeBoundaryTests.swift — 5,705 tokens (full)

### Codemaps
Sources/
└── RepoPrompt/
    ├── Features/
    │   └── AgentMode/
    │       └── Runtime/
    │           └── ProviderBindings/
    │               ├── AgentPermissionSecureStore.swift — 3,984 tokens (manual)
    │               ├── AgentProviderBindingID.swift — 95 tokens (manual)
    │               └── AgentProviderPreferenceSnapshotStore.swift — 1,312 tokens (manual)
    └── Infrastructure/
        └── AI/
            └── Providers/
                └── ACPHeadlessAgentProviderBridge.swift — 327 tokens (manual)


---

## Generated Plan
- Oracle group status: failed
- Oracle group: `654DCE3F-6D3F-4578-8AD0-FAF5D5399BDB`

### Oracle
- Status: Failed
- Provider: `Custom`
- Model: `litellm-claude-fable-5-1-xhigh`
- Effective effort: Provider default / not specified
- Chat: `devin-acp-effort-permiss-A0AE94`

Error [provider_error]: status code 400 litellm.BadRequestError: Anthropic-oauthException - Anthropic OAuth upstream HTTP 400: {"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 200000 > 128000, which is the maximum allowed number of output tokens for claude-fable-5-1"},"request_id":"req_011CfLGjBzuHTmZP9mqD2tXs"}

### Oracle 2
- Status: Completed
- Provider: `devin`
- Model: `gpt-6-astra-medium`
- Effective effort: Provider default / not specified
- Chat: `devin-acp-effort-permiss-5D98DE`

# Devin ACP effort and permissions: minimal rewrite plan

## 1. Summary

Build a fresh change against `origin/main`, using `4232fc4ba6` only to establish branch provenance—not by reverting or cherry-picking the oversized branch. Reuse ACP’s existing configuration parser, serialized mutations, parameter selections, and prompt-time validation. Add Devin’s independent reasoning-effort support; make ACP session modes the sole permission-setting mechanism; and restrict automatic RepoPrompt MCP approval to the exact option ID `allow_once`. **Full Approval will require advertised, successfully confirmed `bypass`; it will fail clearly where enterprise policy prohibits it.** Do not generate broader allow-rules or silently substitute another mode. Retain `--permission-mode` exclusively for the non-ACP one-shot path.

**Evidence boundary:** The supplied source is the discarded branch’s working tree, not clean `origin/main`. No tools were used. Consequently, baseline attribution, omitted UI call sites, and the final line count cannot be certified here. The plan below fixes the behavioral decisions and identifies the missing-source checks; it does not pretend those checks have already passed.

## 2. Current-state analysis

### Evidence ledger

References below are relative to `/Users/daniels/dev/repoprompt-ce`. “Observation” means directly visible in the supplied source, not independently tested.

| ID | Classification | Evidence |
|---|---|---|
| **O1** | Direct observation | ACP initialization advertises `_meta.parameterizedModelPicker` only when the provider opts in. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:530-580` |
| **O2** | Direct observation | Model, parameter, and mode mutations already use `configurationMutationMutex`; parameters are validated as a complete batch before mutation; mutations use advertised configuration identities and verified responses. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:740-1420` |
| **O3** | Direct observation | Parsed parameter definitions belong to the current model. Opting into parameterized picking also suppresses the controller’s automatic global model-registry publication. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:2960-3060` |
| **O4** | Direct observation | Before prompting, explicit parameter selections are checked against live session authority. A separate Devin-specific guard currently handles inherited bypass on resumed sessions. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:2140-2260` |
| **O5** | Direct observation | Devin automatic approval currently permits aliases and kind-based matching. User accept/session-accept decisions have separate selection paths. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:3480-3720` |
| **O6** | Direct observation | Existing debug seams expose automatic approval and user-decision option selection. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:4390-4433` |
| **O7** | Direct observation | Devin currently prefixes ACP launch arguments with permission flags derived from the request. `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift:30-74` |
| **O8** | Direct observation | The controller records and compares a normalized launch permission mode when deciding reuse. `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift:190-450` |
| **O9** | Direct observation | Headless Devin resolves permissions per request and applies model before mode through `beforePrompt`. `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift:10-100` |
| **O10** | Direct observation | The boundary suite drives the actual headless stream through a scripted ACP process, including ordering and rejected-mode cases. `Tests/RepoPromptTests/AgentMode/DevinHeadlessSessionModeBoundaryTests.swift:1-140` |

Clickable source references:
[ACPAgentSessionController.swift:740-1420](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift)
[ACPAgentSessionController.swift:2960-3060](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift)
[DevinACPHeadlessAgentProvider.swift:10-100](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift)
[DevinHeadlessSessionModeBoundaryTests.swift:1-140](file:///Users/daniels/dev/repoprompt-ce/Tests/RepoPromptTests/AgentMode/DevinHeadlessSessionModeBoundaryTests.swift)

**E1 — supplied empirical observation, without a source-file citation:** The live-probe facts establish independent `thought_level`, model-triggered effort reset, inert ACP permission flags, enterprise mode restrictions, and effective `--config` allow-rules. These facts override contradictory comments. The frozen material contains no raw probe artifact with a `path:start-end`; one must not be invented.

### Responsibility and data flow

**Reasoning effort**

```text
Devin configOptions
  → ACPAgentProvider.modelParameterKind
  → controller’s current-model ACPModelParameterSet
  → discovery/UI/MCP definition readers
  → ACPModelParameterSelection
  → ACPRunRequest.modelParameterSelections
  → model selection
  → parameter application
  → mode application
  → live prompt-time validation
  → session/prompt
```

- **Observation:** Parsing, selection representation, mutation serialization, and validation already exist. **[O1–O4]**
- **Inference:** Devin needs an adapter and metadata plumbing, not a second parameter engine. **[O1–O4, E1]**
- **Inference:** Merely enabling `supportsParameterizedModelPicker` is insufficient: it changes registry publication, while the supplied resolver and MCP code exclude Devin. Discovery and consumers must land with the capability change. **[O3]** See also:
  - `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift:175-272`
  - `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift:1-100`

[AgentModelParameter.swift:175-272](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift)
[AgentMCPModelParameterSupport.swift:1-100](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift)

**Permissions**

```text
secure preference / subagent override
  → AgentProviderPermissionProfile
  → AgentProviderPreferenceSnapshotStore.runtimePermission
  → ACPRunRequest.sessionModeID
  → controller.setSessionMode
  → live advertised mode validation
  → verified session/set_config_option response
```

Preference changes enter through the main-actor `AgentModeProviderBindingService`. Its supplied Devin branch settles a pending approval but does not apply the new session mode, unlike OpenCode/Antigravity.

- **Observation:** The profile maps Safe Managed to `.normal`; the compatibility accessor currently returns no Devin mode.
  `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift:146-167`
- **Observation:** The working-tree launch and reuse mechanisms treat the permission flag as significant. **[O7, O8]**
- **Inference:** That launch identity is invalid for ACP because the flag is inert; the session configuration must own effective permission state. **[O2, O7, O8, E1]**

[AgentProviderPermissionProfile.swift:146-167](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift)

### Scope decision

**Targeted change, not a broader ACP refactor.** Keep the existing controller, permission profiles, secure store, request type, and parameter types. Do not generalize OpenCode polling, rewrite permission storage, introduce a new permission state machine, or implement `--config` permission overlays. Existing ACP seams already own the difficult protocol work. **[O1–O4]**

## 3. Design

### A. Independent Devin reasoning effort

#### Provider adapter

In `DevinACPAgentProvider`:

- Return `true` from `supportsParameterizedModelPicker`.
- Implement `modelParameterKind(for:)`:
  - Classify the normalized category `thought_level` as `.thinking`.
  - Do not infer effort from model IDs, option labels, or suffixes.
  - Do not hardcode the configuration ID; preserve the advertised ID.
  - Return `nil` for `speed` and other categories. Speed is outside this task.
- Remove the false “complete model-and-effort variants” assumption.

**Decision:** Classify by the observed category rather than requiring `configID == "thought_level"`. The generic parser already preserves the exact ID for mutation. **[O3, E1]**

Keep choices dynamic. The observed six values are test fixtures, not an application-wide enum or allowlist.

#### Demand-scoped metadata

Extend the existing `DevinModelDiscoveryService`; do not create another polling actor.

Add one asynchronous, throwing operation with this interface shape:

> `discoverModelParametersOnce(workspacePath:modelRaw:) → DevinModelParameterSnapshot`

Add a small immutable value type in the same file:

| Property | Shape |
|---|---|
| `workspacePath` | Standardized effective working-directory path |
| `modelRaw` | Canonical model identity using `ACPModelParameterIdentity` |
| `parameterSet` | Optional `ACPModelParameterSet` |

Its owner is the requesting UI/MCP operation. It is neither persisted nor globally authoritative.

Operation:

1. Construct a no-MCP Devin provider for the requested workspace.
2. Bootstrap a throwaway session.
3. Call existing `discoverSessionModelParameters(for:)`, which forces the model RPC.
4. Return only the parameter set matching the confirmed requested model.
5. Shut down the controller on success, failure, and cancellation.

Reuse `runThrowawaySession`’s bootstrap/shutdown lifecycle by changing that private helper to return `ACPDiscoveredSessionModels?` and accept the requested workspace/model. Its two callers are ordinary model discovery and this new parameter query. Do not duplicate the session lifecycle.

**No timer, retained parameter cache, or shared parameter acquisition task.** UI queries occur when the selected workspace/model changes; MCP explicit requests query once per resolution. This deliberately trades discovery latency for a smaller, unambiguous implementation.

Because parameterized providers no longer publish through the controller:

- Ordinary `discoverIfNeeded` explicitly publishes the discovered **model catalogue** through `AgentACPModelRegistry`.
- Publish no `modelParameterSets` into that provider-global catalogue.
- A targeted parameter query never updates the provider-global catalogue.

**Inference:** Explicit catalogue publication is necessary to avoid losing Devin model discovery after opting in. **[O3]** The registry’s actual update signature must be checked before implementation.

#### Resolver and MCP readers

In `ACPModelParameterResolver`:

- Include `.devin` in `supportsModelParameters`.
- Add defaulted `devinParameters: DevinModelParameterSnapshot? = nil` inputs to `resolve` and `parameterSet`.
- Accept the snapshot only when its normalized workspace and model equal the requested context.
- Return no definitions for missing or mismatched snapshots; never substitute provider-global metadata.
- For a saved but unsupported Devin choice, preserve visible saved intent as OpenCode does rather than displaying an unrelated default.

In `AgentMCPModelParameterSupport`:

- Remove the Devin “combined variants” error.
- Add a per-call injectable Devin observation closure, following the existing OpenCode testing pattern.
- Route Devin through the asynchronous `definitions`, `definitionValues`, and `resolve` overloads.
- Keep synchronous overloads Cursor-only.
- Read failure: empty definitions; cancellation propagates.
- Explicit selection failure: existing invalid-parameters error; cancellation propagates.
- Preserve existing exact configuration-ID validation and advertised-choice canonicalization.

No changes to the MCP request or serialized selection shapes.

#### UI ownership and call-site boundary

The selected workspace/model owner must retain the latest `DevinModelParameterSnapshot` and pass it to the resolver. Reuse its existing model-parameter refresh mechanism:

- Clear old definitions immediately when workspace/model changes.
- Cancel the previous query.
- Before accepting a result, check both request generation and workspace/model identity.
- Cancellation is not an empty successful result.
- Persist the user’s selection through existing `ACPModelParameterSelection` storage.

**Missing-source gate:** The supplied material omits the bodies and exact paths of `AgentModeViewModel+MCPModelParameters.swift`, `AgentModelsSettingsViewModel.swift`, and the relevant picker views. Therefore, it does not establish that zero UI changes are sufficient, nor permit honest naming of their exact methods.

The implementation must identify the existing owner and its resolver call sites before committing the effort change. **Do not invent a second view model or scatter discovery tasks through views.** If those consumers are not already parameter-driven, the sub-500-line estimate below must be revised rather than silently omitting UI support.

#### Application order and failures

For interactive and headless runs:

1. Select the model.
2. Apply the effective parameter selections.
3. Require `validateNoSkippedSelections()`.
4. Apply the requested mode.
5. Revalidate the explicit model/effort and mode immediately before sending the prompt.

A model RPC must always precede effort application, including when a reused session needs to reassert effort. The existing parameter application may skip only when fresh authority confirms the requested value. **[O2, O4, E1]**

Do not derive or strip any model suffix. A persisted model ID remains an opaque model ID.

No explicit effort selection means **leave the runtime’s current effort alone after configuration**. It does not mean “force medium.”

On a rejected or ambiguous configuration operation, abort that turn before prompting; retain saved intent for retry. Do not implement multi-RPC rollback.

### B. ACP permission modes

#### Exact mapping

Use one ACP mapping for both interactive and headless requests:

| Stored level | Requested ACP mode | Behavior |
|---|---|---|
| `providerDefault` | `nil` | Leave the session’s existing/provider-selected mode untouched |
| `normal` | `ask` | Require advertised and confirmed `ask` |
| `acceptEdits` | `accept-edits` | Require advertised and confirmed `accept-edits` |
| `smart` | `smart` | Require advertised and confirmed `smart` |
| `fullApproval` | `bypass` | Require advertised and confirmed `bypass` |

**Decision:** Normal now maps to observed `ask`, not “send nothing.” This gives Safe Managed an explicit requested mode instead of inheriting a potentially broader session mode. If a runtime lacks `ask`, fail; do not guess an equivalent. **[E1]**

Provider Default remains intentional delegation, including on resumed sessions. Its detail text must explicitly say it does not lower an existing session mode.

#### Full Approval in enterprise environments

**Fail clearly; no automatic fallback.**

- Unadvertised `bypass`: reject before sending the mutation.
- Advertised but policy-refused `bypass`: surface the policy error and do not prompt.
- Never attempt `autonomous`.
- Never fall back to `smart`, Provider Default, or RepoPrompt blanket approval.

The error should explain:

> Full Approval requires Devin’s `bypass` mode, which this runtime does not permit. Select an advertised mode such as Smart, or use administrator-managed Devin allow-rules with an appropriate permitted mode.

Preserve the provider’s error detail where available. Do not equate every `-32602` with an organization-policy refusal.

**Rationale:** Only `permissions.allow: ["exec"]` has been proven in the supplied evidence. It does not establish a correct “all tools” vocabulary, lifecycle, policy interaction, or revocation mechanism. Generating a broad allow-rules overlay would be a separate feature, not a minimal fix. **[E1]**

Externally configured allow-rules remain effective; this plan does not edit, remove, or guarantee them. In particular, requesting `ask` is not a sandbox guarantee against separately configured allow-rules.

#### Remove ACP launch-flag authority

In `DevinACPAgentProvider.makeLaunchConfiguration`:

- Stop reading `request.launchPermissionMode`.
- Stop validating or prefixing `--permission-mode`.
- Preserve executable validation, environment isolation, MCP injection, and cleanup.

In `ACPAgentSessionController.isCompatibleWith`:

- Devin compatibility depends on existing provider/workspace boundaries, not an inert launch permission flag.
- Remove Devin-specific normalization/reuse machinery.
- Do not remove launch semantics belonging to another provider.
- Do not reintroduce branch-only request fields on clean main.

In `DevinCLIProvider`, retain the non-ACP flag and its current unattended mapping. This task does not change one-shot CLI permissions. **[O7, O8, E1]**

#### Live changes

`AgentModeProviderBindingService.providerPreferenceChanged` must apply Devin’s effective `runtime.acpSessionModeID` to the active controller.

- Use the profile-aware runtime binding, never the global preference directly.
- Explicit mode changes call `setSessionMode`.
- Provider Default performs no mutation.
- Do not automatically resolve a pending approval merely because Full Approval was selected.
- Surface a mutation failure through the existing visible session-error mechanism—not debug logging alone.
- Stored preference remains requested intent; a failed live mutation must not be represented as confirmed runtime state.

Serialize Devin preference-change tasks per tab in the binding service so rapid changes are applied in selection order. Each queued operation verifies the session still owns the captured controller before mutating it. Remove completed queue entries without removing a newer entry for the same tab. Controller RPC serialization remains owned by its existing mutex. **[O2]**

**Missing-source gate:** The supplied `AgentTabSession` interface does not expose its user-visible error sink. Identify the existing runner/session error API before implementation; do not add a public controller reporting wrapper solely for this call.

#### Prompt-time mode validation

Replace, rather than extend, the branch’s Devin resumed-bypass guard.

For every Devin prompt with an explicit requested mode:

- Require a usable live mode snapshot.
- Require its current value to match the requested advertised value.
- Otherwise fail before prompting.

For Provider Default, perform no mode assertion. The same rule covers fresh, reused, resumed, and load-fallback sessions; no special resume state is needed. **Recommendation grounded in O2, O4.**

Keep the existing parameter guard: the final mode response could invalidate an earlier effort selection. **[O4]**

### C. Permission-option selection

Keep RepoPrompt tool matching unchanged. Change only Devin option selection after the existing match succeeds.

| Decision | Eligible exact IDs, in order |
|---|---|
| Automatic RepoPrompt MCP approval | `allow_once` only |
| User Accept | `allow_once` only |
| User Accept for Session | `allow_session`, then `allow_once` |

No kind-based matching, aliases, persistent grants, or mode-switch fallback for Devin.

If the required option is absent:

- Automatic path returns no selection: interactive mode surfaces the request; headless uses its existing unsupported-approval decline behavior.
- Explicit user accept returns cancelled, following existing controller behavior.

Retain other providers’ selection rules.

**Decision:** Remove the discarded branch’s Devin open-ended denylist machinery. A closed exact-ID selection rule excludes unknown and broader grants without maintaining a vocabulary blacklist. **[O5, E1]**

Reuse the existing test seams; do not add option-label sanitizers or new label tests. **[O6]**

## 4. File-by-file impact

Paths below are relative to `Sources/RepoPrompt/`, except tests.

| File | Functions/types changed; kept versus removed | Dependency |
|---|---|---|
| `Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift` | Add capability/classifier overrides. Remove inert ACP permission arguments and false effort assumption. Keep all launch isolation, authentication, prompt, event, and cleanup behavior. | Effort readers must land with capability |
| `Infrastructure/AI/Providers/Devin/DevinModelDiscoveryService.swift` | Add `DevinModelParameterSnapshot` and targeted discovery operation; adjust `runThrowawaySession`; explicitly publish catalogue-only discovery. Keep existing ordinary discovery coalescing. | Provider opt-in |
| `Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift` | Extend `supportsModelParameters`, `resolve`, `parameterSet`; add contextual Devin snapshot validation and saved-intent display behavior. Keep selection identity/serialization. | Snapshot type |
| `Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift` | Add Devin per-call observation dependency; extend async definition/resolution paths; remove combined-variant error. Keep parsing/merging and Cursor synchronous behavior. | Discovery/resolver |
| `Infrastructure/AI/Providers/Devin/DevinAgentToolPreferences.swift` | Change ACP mapping and detail text. Unify unattended ACP mapping with it. Keep stored raw values and non-ACP CLI mapping. Do not port unused branch-only launch/reverse-mapping helpers. | None |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift` | Update `.devin` in `runtimePermission`; retain profile-aware resolution; stop emitting an ACP launch permission flag. | New mapping |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift` | Make Devin compatibility accessor agree with effective ACP mapping if it has active callers. Preserve preference source/injection; do not create another global-preference read path. | Runtime binding |
| `Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift` | Replace pending-approval-only Devin branch with serialized live mode application and visible failure reporting. | Runtime binding; existing error sink |
| `Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift` | Use ACP mapping without launch flag; carry effective effort selections and apply model → effort → mode in `beforePrompt`. Preserve per-run preference resolution and bridge lifecycle. | Parameter request caller verified |
| `Infrastructure/AI/ACP/ACPAgentSessionController.swift` | Remove Devin flag reuse authority; replace resumed-only policy guard with explicit-mode prompt validation; use exact Devin option IDs. Keep generic parser, mutex, mutation verification, and parameter guard. | Mapping |
| `Infrastructure/AI/ACP/ACPProviderSupport.swift` | Do not port branch-only Devin denylist/pattern helpers; remove them only if actually present in clean main and unused after exact-ID selection. Keep other providers’ policies. | Exact-ID controller path |
| `Tests/RepoPromptTests/AgentMode/DevinHeadlessSessionModeBoundaryTests.swift` | Compact/extend existing main fixture if present; otherwise introduce a small fixture using this pattern, not the whole discarded suite. | Production changes |
| Existing `DevinPermissionLevelTests.swift` | Add table-driven mapping cases only; determine its clean-main path before editing. | Mapping |
| **Existing UI parameter owner and request-construction call sites** | Pass contextual Devin metadata and effective selections through existing picker/request paths. Exact files/functions are omitted from the evidence and must be located before the effort commit. | Discovery/resolver |

No planned production changes to:

- `AgentPermissionSecureStore.swift` or its schemas.
- `AgentProviderBindingModels.swift` permission enum cases.
- `ACPAgentProviderFactory.swift`.
- `DevinCLIProvider.swift`.
- `MCPIntegrationHelper.swift`.
- OpenCode/Cursor providers or polling services.
- `ACPHeadlessAgentProviderBridge.swift`, unless clean main lacks the supplied `beforePrompt` seam.

**Important:** The last table row is a genuine completeness gap in the supplied evidence. Claiming an exact, exhaustive file list without those sources would be misleading.

## 5. Risks and migration

### Compatibility

No permission raw-value or model-parameter schema migration is planned.

- Existing `.normal` now requests `ask`.
- Existing unattended intermediate levels now use their selected ACP mode instead of silently sending none.
- Existing Full Approval fails on enterprise runtimes that prohibit bypass.
- Provider Default intentionally preserves existing mode, including a resumed mode.
- Saved model IDs are not rewritten; unsupported old IDs fail through existing model validation.

Rollback reads the same stored preference and selection fields, but restores the old runtime behavior. Do not claim security-equivalent rollback.

### Required validation gates

1. **Baseline provenance:** Compare merge-base → `origin/main` and merge-base → discarded branch. Do not count omitted branch code as deletions from main.
2. **Metadata wiring:** Verify all UI/MCP/headless callers carry independent selections; the supplied headless constructor alone has no effort-selection input.
3. **Catalogue publication:** Confirm Devin model discovery still refreshes the registry after capability opt-in. **[O3]**
4. **Error detail:** Verify how JSON-RPC `error.data` reaches `localizedDescription`; preserve the organization-policy text without adding a new error taxonomy.
5. **Live semantics:** Confirm advertised `ask`, model/effort ordering, mode mutation while a prompt is active, and behavior of pending approvals during a mode change.
6. **External configuration:** Verify existing `--config` handling survives launch cleanup unchanged. This plan does not synthesize permissions.
7. **Budget:** If clean main lacks the generic seams or compact fixture assumed here, stop and report the revised scope. Do not hide missing functionality to meet a line-count target.

### Focused test list

**Existing permission-level unit tests**

- Table-driven mapping for all five ACP levels.
- Safe Managed and mismatched provider overrides resolve to `ask`.
- Existing non-ACP unattended CLI mapping remains unchanged.

**Existing controller approval seams**

- Strict RepoPrompt match plus exact `allow_once` selects it.
- Only `allow_session`, persistent IDs, `switch_*`, or arbitrary `kind: allow_once` yields no automatic selection.
- Alias IDs `once` and `allow-once` are not accepted for Devin.
- User session approval prefers `allow_session`, then `allow_once`; never persistent scope.
- Non-RepoPrompt request remains unapproved.

**Compact scripted-ACP boundary suite**

- Handshake advertises parameterized picker.
- Advertised selector with category `thought_level` and a non-assumed ID is parsed/applied using that exact ID.
- Model mutation resets effort; captured RPC order proves effort is restored afterwards.
- Mode response changing effort causes prompt-time rejection.
- Missing/unsupported explicit effort sends no prompt.
- `ask`, `accept-edits`, and `smart` apply before prompting.
- Missing bypass sends neither bypass mutation nor prompt.
- Advertised bypass rejected by policy yields a visible error and no prompt.
- Bypass → Normal on a loaded session sends `ask` and then prompts.
- Preference change applies mode without relaunch; failed change is visible.
- Cancellation shuts down discovery/run processes.

Use table-driven cases rather than separate large fixtures.

**Real application proof**

Select Devin, choose a model and High effort, send a turn, change model, and send another turn. Capture configuration RPCs proving effort is applied after each model mutation. Change permissions live to Smart and verify the confirmed session mode. On the enterprise account, select Full Approval and verify an actionable error with no subsequent prompt. Scripted tests prove client behavior; only this run proves compatibility with the actual runtime.

## 6. Implementation order and diff budget

Estimates are **additions plus deletions against clean `origin/main`, including tests**, not net growth. They exclude discarded-branch code that is never brought forward.

| Commit | Scope | Estimated changed lines |
|---|---|---:|
| **1. Restrict Devin approval selection to exact scoped IDs** | Controller approval helpers; omit/remove Devin denylist additions; small cases using existing seams. Independently testable. | 25–40 |
| **2. Make advertised ACP modes authoritative for Devin runs** | Preference mapping, runtime/profile bindings, ACP launch arguments, reuse compatibility, prompt-mode guard, headless permission mapping; table-driven tests. **Atomic:** mapping and enforcement land together. | 65–85 |
| **3. Apply Devin permission changes to the active session** | Binding service’s live-change path, bounded per-tab sequencing, existing visible error reporting; focused live-change test. | 30–45 |
| **4. Enable independent Devin effort end to end** | Provider capability/classification, discovery snapshot/lifecycle, resolver, MCP routes, UI/request consumers, headless model → effort → mode. **Atomic:** do not land capability without readers and catalogue publication. | 115–150 |
| **5. Pin effort and enterprise-mode behavior at the stream boundary** | Reuse/compact the supplied scripted-server pattern; add the boundary cases above without importing the old suite. | 65–90 |
| **6. Validate the real runtime and remove residual false assumptions** | Live application verification; only change missed false assumptions or change-caused failures. No production expansion, no generated review document. | 0–10 |
| **Total planning envelope** | | **300–420** |

Before commit 1, resolve the baseline and missing-source gates. Those are inspection steps, not an excuse to port the discarded branch.

**Budget confidence: conditional, not measured.** The largest uncertainty is existing UI/headless selection plumbing and whether clean main already contains the reusable boundary fixture. If either requires substantial new machinery, an honest complete implementation may exceed this envelope. The prescribed response is to expose that conflict—not to claim that provider opt-in alone delivers reasoning effort.



> 💡 The Oracle group returned ordered, independent lane results. Check each result against the task and report unresolved disagreements.

Optional later follow-up: Continue this plan conversation with ask_oracle(chat_id: "devin-acp-effort-permiss-A0AE94", new_chat: false)