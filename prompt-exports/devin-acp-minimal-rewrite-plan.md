# Devin ACP: minimal rewrite plan (reasoning effort + permissions)

Status: plan only (no production code). Base: `origin/main` 30f28427. No `origin/main` commit since
merge-base 4232fc4ba6 touched the files below. Replaces `fix/devin-acp-permission-gaps`
(+1678/−110, 13 commits), which is discarded. Nothing is cherry-picked from it.

Supporting artifacts (this PR):
- `prompt-exports/devin-acp-probe-evidence.md` — raw live-probe results
- `prompt-exports/devin-acp-probe.py` — rerunnable raw JSON-RPC probe for `devin acp`

## 1. Ground truth (live probes, Devin CLI 3000.11.1, enterprise macOS + no-policy Linux Docker)

| # | Fact | Consequence |
|---|---|---|
| F1 | `configOptions` = `mode`, `model`, `thought_level` (effort), `speed` (category `model_config`, only on some models). Effort is independent of the model id. | Effort is a real ACP parameter. The "combined model+effort variants" assumption was wrong. |
| F2 | Choices and default of `thought_level` vary per model (69 models; 53 have it, 10 distinct choice sets incl. `minimal`, `none`). Switching `model` resets effort to that model's default. 16 older IDs (claude-4-6*, `MODEL_*`, swe-1-6*) switch fine but have no `thought_level`. | Per-model parameter sets; always apply effort **after** model. |
| F3 | Enumerating all 69 models in one session: ~9 s total, median 13 ms/model. | One-shot enumeration in discovery is cheap. |
| F4 | `initialize` with `clientCapabilities._meta.parameterizedModelPicker: true` is accepted; catalogue unchanged. | Opting Devin in is safe. |
| F5 | Modes are account-dependent: enterprise `[accept-edits, smart, ask, plan]`, `bypass` → `-32602 … restricted by your organization's policy`; no-policy `[accept-edits, ask, plan, bypass]` (no `smart`). `autonomous` only with an active sandbox. | `smart` and `bypass` are optional; drive from the advertised list. |
| F6 | `ask` = "Answer questions without code changes", `plan` = planning. Task modes, not permission levels. There is no prompt-for-edits "Normal" mode; `accept-edits` ("Code") is the default of every fresh session. | Never map a permission level to `ask`/`plan`. |
| F7 | `session/load` returns full `configOptions`; the mode **persists** across load (smart → load → smart). | Resumed sessions keep their previous mode. An explicit mode is needed to lower it. |
| F8 | Mode change mid-turn (`set_config_option mode=smart` during a running prompt) succeeds; the turn completes normally. | Live preference changes are safe to apply immediately. |
| F9 | `--permission-mode`, `DEVIN_PERMISSION_MODE`, `--sandbox` are inert for `devin acp`; `--config` / `XDG_CONFIG_HOME` config **is** honored (`permissions.allow` suppresses prompts). | Drop the inert launch flag for ACP. The one-shot CLI keeps it. |
| F10 | Permission options (shell): `allow_once`(allow_once), `allow_session`(**kind allow_always**), `allow_always`, `allow_always_global`, `reject_once`. For MCP tools: additionally `allow_server_session`, `allow_server_always`. | Select by exact optionId only. Never by kind. |
| F11 | For a RepoPrompt MCP tool call, `session/request_permission.toolCall` contains **only `toolCallId`** (no title/kind/rawInput). The preceding `session/update` `tool_call` has `title: "Calling windows from RepoPromptCE"`, `rawInput`, `_meta["cognition.ai/toolName"]: "mcp__RepoPromptCE__windows"`. | Main derives `requestToolName` only from `toolCall.title` and keeps no tool-call registry, so strict auto-approval can **never** match for Devin without correlating by `toolCallId`. |

## 2. Code facts on origin/main (verified with file:line by two read-only probes)

- A1 Devin uses `genericAllowOptionPreferences`. With F10 options, "Allow for session" submits **`allow_always`** (a persistent workspace grant). "Allow" submits `allow_once`. (`ACPAgentSessionController.swift:3400-3478`, `1214-1219`)
- A2 `preferredAllowOptionID` falls back to `first?.optionID ?? ""`, so an accept can submit `reject_once` or `""`. (`:3406-3407`)
- A3 `autoApprovalSelection` begins with `guard provider.providerID != .devin`. The matcher accepts server `RepoPromptCE` and prefix `mcp__repopromptce__`. (`:3481-3497`, `MCPIntegrationHelper.swift:159-253`)
- A4 `setSessionModeSerialized` rejects unadvertised modes before any RPC ("Available modes: …"). `responseErrorMessage` appends string `error.data`, so policy text reaches the user. (`:1164-1178`, `2651-2669`, `3112-3119`)
- A5 `launchPermissionMode` / `acpLaunchPermissionMode` are **set only by Devin** (`AgentProviderPreferenceSnapshotStore.swift:163`, `DevinACPHeadlessAgentProvider.swift:56`). The generic controller only compares them, so full deletion is behaviour-neutral for other providers.
- A6 `AgentModeProviderBindingService` has `case .grokBuild, .devin: break`. The `.openCode, .antigravity` case applies `setSessionMode` live and auto-accepts pending approvals only when `acceptsPendingACPApprovalWhenActivated`. (`:202-247`)
- C1 Parameterized providers skip global registry publication (`ACPAgentSessionController.swift:2919-2921`). After opt-in, **nothing publishes Devin models** unless discovery publishes explicitly.
- C2 `AgentACPModelRegistry.updateDiscoveredModels` persists `modelParameterSets` (canonicalized). Read via `resolvedSnapshot(for:)`, or `resolvedSnapshotAfterWarmingStandardStore(for:)` at cold async boundaries.
- C3 `DevinModelDiscoveryService.discoverIfNeeded` is called only from `APISettingsViewModel` (window composition init + Settings refresh). Discovery therefore runs at launch.
- C4 The runner's explicit-model gate excludes `.devin` (`ACPIntegratedAgentModeRunner.swift:978-983`). Sequence: model → parameters → `validateNoSkippedSelections` → mode → prompt. `sessionModeID` flows generically.
- C5 `ACPModelParameterResolver.parameterSet` handles only `.cursor`/`.openCode`. UI readers (`AgentModeViewModel+ComposerUI.swift:86`, `AgentModeViewModel.swift:1598`) are generic, so no UI changes are needed.
- C6 `discoverSessionModelParameters(for:)` exists (`forceRPC`, verifies confirmed model).

## 3. Decisions

| Level | ACP mode | Behaviour |
|---|---|---|
| providerDefault | none | Leave the session mode untouched (a resumed session keeps its mode, per F7). |
| normal | `accept-edits` | Honest detail text: Devin ACP has no prompt-for-edits mode. Lowers a resumed `smart`/`bypass`, so no resume guard is needed. |
| acceptEdits | `accept-edits` | Same as Normal over ACP. Keep both stored cases (no secure-store migration). |
| smart | `smart` | Only if advertised. Otherwise the existing "Available modes" error, and no prompt. |
| fullApproval | `bypass` | Only if advertised/accepted. Otherwise fail before prompt with the policy text. No fallback, no synthesized allow-rules. |

- Effort: enumerate every advertised model once in `DevinModelDiscoveryService`'s throwaway session and publish
  bootstrap options + current model + per-model sets through `AgentACPModelRegistry` (Cursor-style catalogue). No OpenCode-style polling.
- Approval IDs (Devin, exact, case-sensitive): auto (RepoPrompt MCP) = `allow_once`; Accept = `allow_once`;
  Accept for session = `allow_session` → `allow_once`. Never `allow_always*`/`allow_server_*`. No eligible ID → `cancelled`.
- Other providers: fallback only to an allow-kind option (never first-arbitrary / empty).
- One-shot `DevinCLIProvider` (non-ACP) unchanged (`--permission-mode auto`).

## 4. Commits (against origin/main)

1. **Exact Devin approval selection + safe accept fallback** (~40 src / ~40 test)
   `ACPAgentSessionController`: `preferredAllowOptionID -> String?`, `devinAllowOptionPreferences`, allow-kind fallback for others,
   merged accept cases → nil = `cancelled`. Fixes A1/A2.
2. **Devin RepoPrompt MCP auto-approval via tool-call correlation** (~30 src / ~35 test)
   Remember `tool_call` updates by `toolCallId` (title, rawInput, `_meta["cognition.ai/toolName"]`), bounded and cleared on
   terminal `tool_call_update`/turn end. In `handlePermissionRequest`, fill missing title/rawInput from it. Use `_meta` toolName as
   `requestToolName` when present. Remove the Devin guard. Auto option = exact `allow_once`. Fixes F11/A3.
3. **Devin permission level is an ACP session mode** (~40 src / ~60 test)
   `DevinAgentToolPreferences.PermissionLevel.sessionModeID` + detail text; snapshot store emits `acpSessionModeID`;
   binding service adds `.devin` to the `.openCode, .antigravity` live case (no auto-accept); headless applies mode last.
4. **Delete the inert launch flag plumbing** (~110–130, deletions only)
   `ACPRunRequest.launchPermissionMode`, `acpLaunchPermissionMode`, `launchedPermissionMode`, `normalizedLaunchPermissionMode`,
   Devin `cliPermissionMode` (ACP use)/`launchArguments`/`from(cliPermissionMode:)`/`isRecognizedCLIPermissionMode`, the provider arg prefix.
   Safe per A5. Can be split into its own PR.
5. **Devin reasoning effort** (~65 src / ~55 test)
   `DevinACPAgentProvider`: `supportsParameterizedModelPicker = true`, `modelParameterKind` (`thought_level` → `.thinking`; optional `speed`).
   `DevinModelDiscoveryService`: enumerate + explicit publish (sole publisher, C1). No partial publish on failure/cancel.
   Resolver `.devin` branch. Runner gate adds `.devin`. `DevinAgentConfig.modelParameterSelections` passed from
   `AgentRuntimeProviderService.swift:349`. Headless order is model → effort → validate → mode.
6. **Optional: MCP `model_parameters` for Devin** (~10) — `AgentMCPModelParameterSupport` catalogue-backed paths.

Budget ≈ 330–420 changed lines excluding commit 4 (≈ 450–550 with it). Tests reuse `GrokBuildACPHeadlessAgentProviderTests`
(scripted process harness), `CursorACPParameterBindingTests`, `DevinPermissionLevelTests`. No bespoke 200-line harness.

### Tests
`testDevinACPModeMapping` · `testDevinRuntimeBindingRespectsPermissionProfile` · `testDevinExactApprovalScope` ·
`testAcceptWithoutAllowOptionCancels` · `testDevinMCPPermissionCorrelatesToolCallByID` (title-less request + prior `tool_call` → `allow_once`) ·
`testNativeToolPermissionNotAutoApproved` · `testUnavailableOrRefusedModePreventsPrompt` (missing smart / missing bypass / policy `-32602`) ·
`testNormalLowersResumedBypass` · `testDevinThoughtLevelClassification` · `testDiscoveryPublishesPerModelSets` (+ no partial publish) ·
`testModelThenEffortThenModeBeforePrompt` · `testStaleEffortFailsBeforePrompt`.

## 5. Risks
- Full Approval on enterprise now fails visibly instead of silently running at accept-edits (intended).
- Normal now actively lowers a resumed smart/bypass session (intended). Provider Default does not (documented).
- Devin level changes apply live instead of relaunching the process.
- Cached effort metadata can lag account changes. Live validation at run time fails rather than substituting.

## 6. Remaining unknowns
- Whether any Devin MCP permission request arrives **before** its `tool_call` update. In the probe the update came first.
  Fallback if not: surface the card (fail-safe, no auto-approval).
- Whether org policy can hide `accept-edits` (then Normal/Accept Edits fail before prompt; fail-closed).

## 7. Live verification (CE debug app)
1. Build and launch through conductor (`rpce-debug-build-validation` skill). Enable ACP raw logging via `rpce-cli-debug app_settings`.
2. Refresh Devin models, then check the registry has per-model `thought_level` sets (swe-2-high `[medium,high,max]`, gemini-3-8-flash `[low,medium,high]`).
3. `agent_run start` Devin with swe-2-high + `max`. The captured RPC order must be model → thought_level → mode(`accept-edits`) → prompt. Poll the exact session ID.
4. A RepoPrompt tool call is auto-approved with `allow_once` (no card). A shell command shows the card. "Allow for session" sends `allow_session`.
5. Change to Smart mid-run: a live `set_config_option mode=smart` on the same process.
6. Full Approval on enterprise: the policy error appears and there is no `session/prompt`. In the no-policy Docker runtime (`prompt-exports/devin-acp-probe.py`), `bypass` is applied.

## Out of scope / follow-ups
- Leaked UserDefaults suites from tests (~170 `DevinPermissionLevelTests.*` domains).
- MCP client-identity normalization (separate PR).
- Oracle preset: Fable lane requests `max_tokens` 200000 > 128000 (fails in the preset; works when invoked directly).
