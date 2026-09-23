# Oracle Plan

## Oracle group
- Group ID: `A77043E3-E1E4-47B9-A706-9C46682CDCE8`
- Status: `completed`
- Oracle count: 2

## Oracle results

### Oracle (Primary)
- Lane index: 0
- Role: `primary`
- Chat ID: `new-chat-7BBCF9`
- Provider: _Not specified._
- Model: `custom_provider_litellm-claude-fable-5-1-xhigh`
- Status: `completed`
- Execution provider: `Custom`
- Execution model: `litellm-claude-fable-5-1-xhigh`

#### Response



# Devin ACP: minimal rewrite plan (effort + permissions) against origin/main

## 1. Summary

Replace the inert `--permission-mode` launch flag with an ACP `mode` config-option carrier for Devin, make Devin's approval-option selection exact-ID (never widening past the pending call / session), enable strict RepoPrompt-MCP auto-approval for Devin, and expose Devin's `thought_level` (and `speed`) config options through the existing parameterized-model-picker mechanism by enumerating every advertised model once during `DevinModelDiscoveryService`'s throwaway session and persisting the per-model sets into the existing `AgentACPModelRegistry`/`ACPDynamicModelStore` catalogue. This is a targeted change, not a refactor: every mechanism needed already exists for OpenCode/Cursor/Antigravity (session-mode carrier, live mode change, `applySessionModelParameterSelections`, `validateNoSkippedSelections`, registry-persisted `modelParameterSets`); Devin only needs to opt in and have its two provider-specific vocabularies (modes, option IDs) declared. Five small commits, ~400 lines of additions/modifications plus ~120 lines of pure deletions of the flag machinery, versus the discarded branch's +1678/−110.

---

## 2. Current-state analysis (origin/main = selected files minus the patch)

### 2.1 Permission path today (broken)

| Component (main) | Behaviour |
|---|---|
| `DevinAgentToolPreferences.PermissionLevel` | 5 levels; `cliPermissionMode` (`nil/auto/accept-edits/smart/dangerous`), `launchArguments`, `from(cliPermissionMode:)`, `isRecognizedCLIPermissionMode`. No ACP mode mapping. |
| `AgentProviderPreferenceSnapshotStore.runtimePermission(.devin)` | `AgentProviderRuntimePermissionBinding(acpLaunchPermissionMode: level.cliPermissionMode)` only. |
| `ACPIntegratedAgentModeRunner` | Copies `runtime.acpLaunchPermissionMode` → `ACPRunRequest.launchPermissionMode`; passes `runtime.acpSessionModeID` generically (nil for Devin). |
| `DevinACPAgentProvider.makeLaunchConfiguration` | Validates carrier, prepends `--permission-mode X` before `acp`. **Inert** (evidence: `mode.currentValue == "accept-edits"` regardless). |
| `ACPAgentSessionController.isCompatibleWith` | Devin-special-cased `isRecognizedCLIPermissionMode` guard + `launchedPermissionMode` compare via `normalizedLaunchPermissionMode` → a level change forces a **new process** that then behaves identically. |
| `AgentModeProviderBindingService.providerPreferenceChanged` | `case .grokBuild, .devin: break` — no live change. |
| `ACPAgentSessionController.preferredAllowOptionID` | Returns non-optional `String`; Devin uses `genericAllowOptionPreferences`; fallback `?? filteredOptions.first?.optionID ?? ""`. |
| `autoApprovalSelection` | `guard provider.providerID != .devin` — Devin never auto-approves RepoPrompt MCP tools, so **every headless Devin run that touches a RepoPrompt tool fails** (`ACPHeadlessAgentProviderBridge` declines). |
| `DevinACPHeadlessAgentProvider` | `launchPermissionMode: includeRepoPromptMCPServer ? "auto" : nil`; `beforePrompt` sets model only. |

Concrete main bug worth stating as evidence for commit 1: Devin advertises `allow_session` with **`kind: allow_always`**. `genericAllowOptionPreferences(sessionScoped: true)` = `[.optionID("always"), .optionID("allow_always"), .kind("allow_always"), …]`, so a user's "Allow for session" on Devin today submits `allow_always` — a **persistent per-tool grant in the workspace**, one tier wider than asked.

### 2.2 Effort path today (absent)

- `DevinACPAgentProvider.supportsParameterizedModelPicker == false` → controller's `parseModelParameterSets` returns `[]`, `applySessionModelParameterSelections` skips everything, `discoverSessionModelParameters` throws.
- `ACPModelParameterResolver.parameterSet` is `switch { .cursor, .openCode, default: nil }` → UI readers (`AgentModeViewModel+ComposerUI:86`, `AgentModeViewModel:1598`) get nil → no chip. There is **no `supportsModelParameters` predicate on main** (the patch added it to exclude Devin; we do the opposite, so it is not needed).
- `DevinModelDiscoveryService.runThrowawaySession` bootstraps once and reads `currentDiscoveredSessionModels()?.options.count`; registry publication happens **implicitly inside the controller** via `publishDiscoveredSessionModelsIfGloballyAuthoritative`, which is guarded by `!provider.supportsParameterizedModelPicker`.
- `ACPDynamicProviderRecord.modelParameterSets` / `ACPDynamicModelStore.canonicalParameterSets` already persist per-model parameter sets (Cursor-style shape). No current consumer round-trips them through the registry (Cursor is static, OpenCode is demand-scoped) — see unknown U2.
- The discarded diff reveals main's `ACPIntegratedAgentModeRunner` ~L979 model gate is `openCode || cursor || grokBuild || antigravity` — **`.devin` excluded**. `ACPAgentProviderFactory.makeProvider(.devin)` also ignores `modelString`. If that gate is the pre-prompt `setSessionModel` gate, interactive Devin model selection never reaches the wire on main; effort depends on model being set first.

### 2.3 Critical trap the candidate design does not mention

Opting Devin into `supportsParameterizedModelPicker` **stops the controller from publishing Devin models to the registry** (`publishDiscoveredSessionModelsIfGloballyAuthoritative` guard). That guard is correct — a live run's snapshot carries only the current model's parameter set and `ACPDynamicModelStore.save` replaces the whole record — so `DevinModelDiscoveryService` must become Devin's sole catalogue publisher (exactly as `OpenCodeACPModelPollingService.publishCatalog` is for OpenCode).

### 2.4 Reusable, unchanged

`setSessionMode`/`setSessionModeSerialized` (validates against advertised list, throws with "Available modes: …"; `responseErrorMessage` appends `error.data` so org-policy text surfaces), `applySessionModelParameterSelections`, `ACPModelParameterApplicationReport.validateNoSkippedSelections`, `discoverSessionModelParameters`, `validatePromptModelParameterSelections`, `ACPPermissionOptionPolicy` (Devin denylist is `[]` on main and stays so), `MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch`, `ACPHeadlessAgentProviderBridge`, `ACPDynamicModelStore`, the `.openCode, .antigravity` live-mode case, `DevinCLIProvider` (one-shot, keeps hardcoded `--permission-mode auto`).

---

## 3. Critique of the candidate design

| Candidate point | Verdict | Reason |
|---|---|---|
| providerDefault→none; normal→accept-edits; acceptEdits→accept-edits; smart→smart; fullApproval→bypass | **Keep**, with honest `detailText` | Devin ACP has no prompt-for-edits mode; `ask`/`plan` are task modes. `normal` and `acceptEdits` become indistinguishable over ACP — do **not** collapse them now: `.normal` is the fail-closed default in `from(rawValue:)`, `SecureDevinPermissionDocument`, `subagentDefault`, `mcpSafeDefaults`; collapsing touches the secure-store schema. Say so in the picker text. `providerDefault` leaves a resumed `bypass` session at `bypass` — acceptable because that level explicitly means "don't touch"; document it. |
| Unadvertised/refused → fail before prompt, no fallback, no synthesized allow-rules | **Keep** | `--config permissions.allow` would circumvent org policy and persist config; the existing `setSessionMode` already fails closed with the advertised list, and refusals carry `error.data`. |
| No resume guard | **Keep** | Normal/Accept Edits/Smart actively lower a resumed `bypass`; only `providerDefault` doesn't, by definition. Deletes ~45 lines + 6 tests from the discarded branch. |
| Effort: enumerate in discovery vs OpenCode-style polling | **Keep enumeration** (~30 lines) | Generalising `OpenCodeACPModelPollingService` is 700 lines of OpenCode-specific actor state. But enumeration **requires** discovery to publish (see 2.3) — candidate omitted this. Also skip the bootstrap model (its set is already in the bootstrap snapshot) and placeholder-default options. |
| Order model → effort → validateNoSkipped → mode → prompt | **Keep** | Devin does **not** need OpenCode's `forceRPC: true` (thought_level is advertised at bootstrap and after every model set). |
| Drop flag from launch + reuse key; `.devin` joins `.openCode, .antigravity` case | **Keep** | Requires `acceptsPendingACPApprovalWhenActivated` to stay `false` for Devin so the shared case does not auto-accept — candidate is consistent. |
| Auto-approval exact `allow_once`; accept `allow_once`; accept-for-session `allow_session`→`allow_once`; `String?`, nil→cancelled | **Keep, refine** | Devin: exact IDs **only**, no kind fallback (its `allow_session.kind == allow_always`). Other providers: replace `first?.optionID ?? ""` with a fallback restricted to `kind.hasPrefix("allow")` so Grok/OpenCode session-scoped accepts don't regress to `cancelled`. No `ACPPermissionOptionPolicy` changes. |
| Not in candidate | **Add** | `speed` (`model_config`) classifies to the existing `.speed` kind for free. Main's runner `.devin` model-gate exclusion. `session/load` configOptions presence is unverified and gates whether resumed runs work at all (U1). |
| From discarded branch | **Drop** | `PermissionOption.name`/label sanitiser, `unattended*` mappings, `bypassSessionModeID`, `unattendedLaunchPermissionMode`, `DevinCLIProvider` change, `supportsModelParameters` predicate, `unsupportedModelParametersMessage`, `AgentModelsSettingsViewModel` guards. |

---

## 4. Design

### 4.1 Permission level → ACP session mode

**`DevinAgentToolPreferences.PermissionLevel`** (`Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinAgentToolPreferences.swift`)

Add (C2):

```swift
/// ACP `mode` config-option value applied over `session/set_config_option`.
/// Verified 3000.11.1: enterprise advertises [accept-edits, smart, ask, plan];
/// no-policy hosts [accept-edits, ask, plan, bypass]. `ask`/`plan` are task modes,
/// never permission levels. nil = send nothing (a resumed session keeps its mode).
var sessionModeID: String? {
    .providerDefault → nil
    .normal, .acceptEdits → "accept-edits"     // Devin's default "Code" mode; no prompt-for-edits mode exists
    .smart → "smart"
    .fullApproval → "bypass"
}
```

Rewrite the five `detailText` strings to describe ACP behaviour (Normal must state it is identical to Accept Edits for Agent Mode and only differs for the one-shot CLI; Full Approval must state it fails before prompting when the host doesn't advertise `bypass` or policy forbids it; Provider Default must state a resumed session keeps its last mode).

Delete (C3): `permissionModeArgumentName`, `cliPermissionMode`, `launchArguments`, `from(cliPermissionMode:)`, `isRecognizedCLIPermissionMode`. Keep `from(rawValue:)`, `iconName`, `isWarning`, `permissionLevel(...)`, `setPermissionLevel(...)`.

**`AgentProviderPreferenceSnapshotStore.runtimePermission(.devin)`**

C2: `AgentProviderRuntimePermissionBinding(acpLaunchPermissionMode: level.cliPermissionMode, acpSessionModeID: level.sessionModeID)` with a two-line comment ("`devin acp` ignores `--permission-mode`; the level is a session mode; never auto-accept a pending approval on level change"). C3: drop the `acpLaunchPermissionMode:` argument. `acceptsPendingACPApprovalWhenActivated` stays default `false`.

**`AgentModeProviderBindingService.providerPreferenceChanged`**

Split main's `case .grokBuild, .devin:` into `case .openCode, .antigravity, .devin:` (existing body unchanged — `setAutoApproveAllToolPermissions(false)`, `setSessionMode`, pending-approval branch skipped because the flag is false) and `case .grokBuild: break`. Guard `runtime.acpSessionModeID` already `continue`s for `providerDefault`.

**Data flow (interactive):** user picks level → `setPermissionLevel(.devin(level))` → `bumpRevision` → `providerPreferenceChanged` → for active Devin sessions: `Task { @MainActor … controller.setSessionMode(id) }` (actor hop into the controller; failure logged only, as for OpenCode). Next run: runner builds `ACPRunRequest(sessionModeID: runtime.acpSessionModeID)` → `setSessionMode` before prompt (no-op RPC when current == requested). Out-of-order/duplicate: idempotent by value; last write wins.

**Data flow (MCP-originated):** `permissionProfileForMCPActivation` → `.mcpSafeDefaults` → `devinPermissionLevel` `.normal` → `accept-edits` explicitly sent (never nil). Safe Managed for Devin therefore means "Devin default; edits auto-approved; other actions ask" — the least permissive ACP mode that still lets an agent edit.

**`AgentProviderPermissionProfile.acpSessionModeID(for:)`** — leave unchanged; verify (grep) that no Devin runtime path reads it (the snapshot store binding is the single source). If a caller drives Devin, add the `.devin` arm (3 lines).

### 4.2 Remove the inert launch flag (C3, atomic)

Delete end-to-end: `ACPRunRequest.launchPermissionMode` (field, init param/assignment, doc), `AgentProviderRuntimePermissionBinding.acpLaunchPermissionMode` (same), controller `launchedPermissionMode` field, its init assignment, `normalizedLaunchPermissionMode`, and the two Devin/launch blocks in `isCompatibleWith` (Devin then reuses on provider+workspace like OpenCode). `DevinACPAgentProvider.makeLaunchConfiguration`: remove the carrier guard/derivation, `arguments: resolvedLaunch.arguments`, replace the doc comment ("`devin acp` ignores `--permission-mode`; permissions are applied over ACP as the `mode` config option"). Runner: delete the `launchPermissionMode:` argument at request construction (compiler-driven). `DevinAgentConfig` doc paragraph and `ACPAgentProviderFactory` `.devin` comment: rewrite to reference the session mode. `DevinCLIProvider`: untouched.

### 4.3 Approval option selection (C1)

`ACPAgentSessionController` (`Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift`):

```swift
private func preferredAllowOptionID(for options: [PermissionOption], sessionScoped: Bool) -> String? {
    prefs = switch providerID {
        .openCode, .cursor, .antigravity → genericAllowOptionPreferences(sessionScoped)
        .devin → devinAllowOptionPreferences(sessionScoped)
        .grokBuild → grokBuildAllowOptionPreferences(sessionScoped)
    }
    filtered = safePermissionOptionsForAutoSelection(options)
    if let m = optionID(for: filtered, preferences: prefs) { return m }
    guard providerID != .devin else { return nil }          // exact-ID only: allow_session is typed allow_always
    return filtered.first { normalizedKind($0).hasPrefix("allow") }?.optionID   // replaces `first ?? ""`
}

private func devinAllowOptionPreferences(sessionScoped: Bool) -> [PermissionOptionPreference] {
    sessionScoped ? [.optionID("allow_session"), .optionID("allow_once")] : [.optionID("allow_once")]
}
```

`respondToPermissionRequest`: merge `.accept, .acceptForSession, .acceptWithExecpolicyAmendment` into one case with `sessionScoped: decision != .accept`; nil → `["outcome": ["outcome": "cancelled"]]` plus a `log(...)` line. `autoApprovalSelection`: remove `provider.providerID != .devin` from the guard; `.devin → [.optionID("allow_once")]`. `fullAccessAutoApprovalOptionID`: keep `nil` for Devin, fix comment (no blank-check; per-request auto-approval via `autoApprovalSelection`). Add `#if DEBUG` seams `test_preferredAllowOptionID(options:sessionScoped:)` and `test_autoApprovalOptionID(requestToolName:requestPayload:options:)` building `PermissionOption(optionID:kind:)` (main's two-field shape).

Invariants: an automatic path never selects `allow_always`/`allow_always_global`/`switch_*`/`plan_*` for Devin because only two exact IDs are ever matched; a session-scoped decision degrades to `allow_once`, never upward; no decision ever submits a reject ID or `""` for an accept.

### 4.4 Effort via `thought_level` (C4)

**`DevinACPAgentProvider`**

```swift
var supportsParameterizedModelPicker: Bool { true }
func modelParameterKind(for input) -> ACPModelParameterKind? {
    token(category) == "thought_level" || token(configID) == "thought_level" → .thinking
    token(category) == "model_config" && token(configID) == "speed"          → .speed
    else → nil
}
```
`token` = trim + lowercase. Keep it this tight (don't copy Cursor's heuristics).

**`DevinModelDiscoveryService.runThrowawaySession`** (drop `private`; add `publish` param)

```swift
typealias CatalogPublisher = @Sendable (ACPDiscoveredSessionModels) -> Void
static let publishToRegistry: CatalogPublisher = { _ = AgentACPModelRegistry.shared.updateDiscoveredModels($0, for: .devin) }

static func runThrowawaySession(_ config, publish: CatalogPublisher = publishToRegistry) async throws -> Int? {
    … bootstrap …
    guard let boot = currentDiscoveredSessionModels(), !boot.options.isEmpty else { shutdown; return 0 }
    var sets = boot.modelParameterSets                       // current model already parsed at session/new
    for option in boot.options where !option.isPlaceholderDefault
                                  && canonical(option.rawValue) != canonical(boot.currentModelRaw) {
        try Task.checkCancellation()
        do {
            let snap = try await controller.discoverSessionModelParameters(for: option.rawValue)
            sets += snap.modelParameterSets.filter { canonical($0.baseModelRaw) == canonical(option.rawValue) }
        } catch is CancellationError { throw } catch { continue }   // refused/unknown model: publish without its set
    }
    publish(ACPDiscoveredSessionModels(options: boot.options, currentModelRaw: boot.currentModelRaw, modelParameterSets: sets))
    shutdown; return boot.options.count
}
```
`canonical` = `ACPModelParameterIdentity.canonicalBaseModelRaw(_, providerID: .devin)`. Publishing bootstrap `options`/`currentModelRaw` (not the last-set model) mirrors OpenCode's rationale. `discoverSessionModelParameters` already asserts the confirmed model equals the requested one, serialises on `configurationMutationMutex`, and applies `requestTimeouts`. Complexity: N−1 RPCs at discovery time, none at run time. `Outcome.discovered` is returned only after `publish`.

**`ACPModelParameterResolver.parameterSet`** (`AgentModelParameter.swift`): add

```swift
case .devin:
    AgentACPModelRegistry.shared.resolvedSnapshot(for: .devin)?
        .modelParameterSets.first { canonical($0.baseModelRaw) == canonical(selectedModelRaw) }
```
Sync, callable from MainActor UI and MCP (the registry is already read this way from `ACPAIModelCatalog` statics and from the controller actor). Fallback if U2 fails: `ACPDynamicModelStore.load(providerID: .devin)?.modelParameterSets`.

**Runtime (interactive):** runner builds `modelParameterSelections` generically → `setSessionModel(model)` (response re-parses configOptions → live set for the new model with that model's default as `currentValueRaw`) → `applySessionModelParameterSelections` (validates against the **live** set; stale/unadvertised value → `skipped`) → `validateNoSkippedSelections()` throws `ACPModelParameterSelectionError.skipped` (user sees "stale or unsupported… Refresh") → `setSessionMode` → `prompt` (`validatePromptModelParameterSelections` re-checks live authority). Selections are keyed `(devin, lowercased model, .thinking)` so a pin never leaks across models.

**Headless:** `DevinAgentConfig` gains `modelParameterSelections: [ACPModelParameterSelection] = []`; `makeRunRequest` passes it; `beforePrompt` final order:

```
1. model (non-empty, non-"default") → setSessionModel
2. selections non-empty → report = applySessionModelParameterSelections; report.validateNoSkippedSelections()
3. mode non-empty → setSessionMode
```
`AgentRuntimeProviderService.swift:349`: pass selections into `DevinAgentConfig` the same way the adjacent OpenCode construction does.

**Runner edits (must verify by reading):** (a) ~L979 gate: add `|| agentKind == .devin`; (b) confirm the pre-prompt sequence is model → parameters → `validateNoSkippedSelections` → mode → prompt and not provider-gated (if gated, add `.devin`; if OpenCode's `forceRPC` is passed generically it is a harmless extra RPC for Devin); (c) confirm `sessionModeID: runtime.acpSessionModeID` is passed generically (it must be, for OpenCode).

**MCP `model_parameters` (C5, optional):** `AgentMCPModelParameterSupport`: sync `definitions` guard `providerID == .cursor || .devin` using `parameterSet(providerID:…)`; async `definitions` `case .cursor, .devin`; sync `resolve` guard `agent == .cursor || .devin` → `resolve(requests:providerID:…)`; async `resolve` `case .cursor, .devin`. Existing "metadata unavailable" errors cover "discovery not yet run".

### 4.5 Error handling / edge cases

- Host lacks the requested mode → `setSessionMode` throws `requestFailed("… Available modes: …")` before prompt; run fails; session untouched.
- Host advertises but refuses (`-32602` + `error.data`) → `responseErrorMessage` surfaces policy text; run fails before prompt.
- `session/load` with no `configOptions` → `sessionModeSnapshot == nil` → every non-nil mode throws "does not advertise a modern session mode configOptions selector" → **all resumed runs except Provider Default fail** (see U1; decision deferred to live verification).
- Live mode change while prompt running: error logged (debug) and swallowed, same as OpenCode.
- Enumeration: a model whose set fails is skipped; user sees no chip for it and runs proceed with Devin's default effort. Empty model list (not logged in) → `noModelsAdvertised`, nothing published.
- Accept decision with no `allow_once`/`allow_session` offered → `cancelled` outcome; the approval card still shows the raw options JSON.

---

## 5. File-by-file impact

| File | Change | Commit |
|---|---|---|
| `Infrastructure/AI/ACP/ACPAgentSessionController.swift` | `preferredAllowOptionID → String?` + Devin exact-ID prefs + allow-kind fallback; `respondToPermissionRequest` merged accept cases, nil→cancelled; `autoApprovalSelection` Devin enabled; `fullAccessAutoApprovalOptionID` comment; 2 DEBUG seams | C1 |
| same | delete `launchedPermissionMode`, init assignment, Devin/launch blocks in `isCompatibleWith`, `normalizedLaunchPermissionMode` | C3 |
| `Infrastructure/AI/Providers/Devin/DevinAgentToolPreferences.swift` | add `sessionModeID`; rewrite 5 `detailText` | C2 |
| same | delete `permissionModeArgumentName`, `cliPermissionMode`, `launchArguments`, `from(cliPermissionMode:)`, `isRecognizedCLIPermissionMode` | C3 |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift` | `.devin` binding adds `acpSessionModeID` | C2; drop launch arg C3 |
| `Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift` | `.devin` joins `.openCode, .antigravity`; `.grokBuild` alone | C2 |
| `Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift` | `permissionLevel` closure param; `makeRunRequest(…, permissionLevel:)` → `sessionModeID`, no `launchPermissionMode`; `beforePrompt` mode step | C2 |
| same | selections into request; `beforePrompt` step 2 | C4 |
| `Features/AgentMode/Providers/ACP/ACPAgentProvider.swift` | delete `ACPRunRequest.launchPermissionMode` | C3 |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderBindingModels.swift` | delete `acpLaunchPermissionMode` | C3 |
| `Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift` | remove carrier guard + `launchArguments`, doc | C3 |
| same | `supportsParameterizedModelPicker`, `modelParameterKind` | C4 |
| `Infrastructure/AI/Providers/Devin/DevinAgentConfig.swift` | doc rewrite | C3 |
| same | `modelParameterSelections` | C4 |
| `Infrastructure/AI/ACP/ACPAgentProviderFactory.swift` | `.devin` comment | C3 |
| `Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift` | delete `launchPermissionMode:` arg | C3 |
| same | `.devin` in model gate (~L979); verify param order/gating | C4 |
| `Infrastructure/AI/Providers/Devin/DevinModelDiscoveryService.swift` | enumeration + `publish` injection; sole Devin catalogue publisher | C4 |
| `Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift` | `.devin` case in `parameterSet` | C4 |
| `Features/AgentMode/Services/AgentRuntimeProviderService.swift` (~L349) | pass selections into `DevinAgentConfig` | C4 |
| `Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift` | Devin in 4 switch/guard sites | C5 |
| `Tests/RepoPromptTests/AgentMode/DevinACPPermissionOptionSelectionTests.swift` (new) | seam tests | C1 |
| `Tests/RepoPromptTests/AgentMode/DevinACPHeadlessAgentProviderTests.swift` (new) | scripted `devin` harness + mode/permission tests | C2 |
| same | order/stale/discovery/classification tests | C4 |
| `Tests/…/DevinPermissionLevelTests.swift` | add `sessionModeID` assertions | C2; delete flag assertions C3 |
| any test referencing `launchPermissionMode`/`acpLaunchPermissionMode`/`launchArguments` | delete assertions | C3 |

Untouched: `ACPProviderSupport.swift`, `MCPIntegrationHelper.swift`, `DevinCLIProvider.swift`, `OpenCode*`, `Cursor*`, `AgentProviderPermissionProfile.swift` (unless U-caller check says otherwise), `AgentModeViewModel+MCPModelParameters.swift`, `AgentModelsSettingsViewModel.swift`.

---

## 6. Risks and migration

- **Behaviour change:** Full Approval on enterprise now fails before prompt (previously ran silently at accept-edits with an inert flag). Intended.
- **Behaviour change:** Devin level changes no longer spawn a new process; applied live/before next prompt.
- **Behaviour change:** Devin model list is refreshed only by `DevinModelDiscoveryService` (previously every run). Verify trigger points (U8).
- **Internal API removal:** `ACPRunRequest.launchPermissionMode`, `AgentProviderRuntimePermissionBinding.acpLaunchPermissionMode` — internal only; compiler flags every site.
- **Persistence:** no schema change. Devin registry records gain `modelParameterSets` (already optional). Secure-store Devin document unchanged; `.normal` fail-closed semantics unchanged.
- **Rollback:** each commit reverts independently; C3 is pure deletion.

---

## 7. Implementation order (commits, tests, line estimates)

**C1 — Controller: Devin exact-ID approval selection; allow-selection returns `String?`** (~55 src / ~45 test)
`ACPAgentSessionController`: §4.3. Test `DevinACPPermissionOptionSelectionTests`: build a controller with real `DevinACPAgentProvider(config: DevinAgentConfig(commandName: "/usr/bin/true", includeRepoPromptMCPServer: false))` and a Devin `ACPRunRequest` (init doesn't spawn; if `DevinACPLaunchResolver.resolvedLaunch` probes `--help`, point `commandName` at the C2 script instead). Cases with the evidence option set `[allow_once/allow_once, allow_session/allow_always, allow_always/allow_always, allow_always_global/allow_always, reject_once/reject_once]`: `testAcceptSelectsAllowOnce`, `testAcceptForSessionSelectsAllowSessionThenAllowOnce`, `testNoAllowOnceOrSessionYieldsNilNeverAllowAlways`, `testRepoPromptToolAutoApprovesWithAllowOnceOnly` (`requestToolName: "mcp__RepoPrompt__read_file"`, and nil when `allow_once` absent or tool is `Bash`).

**C2 — Devin permission level is an ACP session mode** (~36 src / ~135 test)
`DevinAgentToolPreferences.sessionModeID` + `detailText`; snapshot store; binding service; headless `permissionLevel` closure, `makeRunRequest(permissionLevel:)`, `beforePrompt` mode step. `DevinPermissionLevelTests`: `testSessionModeIDMapping` (5 levels). New `DevinACPHeadlessAgentProviderTests` with a compact Python `devin` script (≈45 lines; parameters by string substitution: `ADVERTISED_MODES`, `STARTING_MODE`, `PERMISSION_TOOL none|mcp|shell`; two models with per-model `thought_level` defaults/choices; records inbound `{method, params}` and the client's `permission_response` to `<script dir>/requests.jsonl`; `--help` handled; `set_config_option` for an unadvertised mode returns `-32602` with the policy text) and Swift `Harness` (≈30 lines: `makeHarness(...)`, `makeProvider(level:modelString:selections:)` using the default provider factory and `includeRepoPromptMCPServer: false`, `recordedMethodOrder()`, `recordedParams(_:)`; reuse `makeTestDirectory(name:)` and the GrokBuild headless test's script conventions). Tests: `testFullApprovalFailsBeforePromptWhenBypassIsNotAdvertised` (enterprise list; asserts "Available modes: accept-edits, smart, ask, plan", no `session/prompt`), `testNormalLowersAResumedBypassSessionBeforePrompting` (`STARTING_MODE bypass`, resume → `mode=accept-edits` index < prompt index), `testProviderDefaultSendsNoMode`, `testRepoPromptMCPPermissionIsAutoApprovedWithAllowOnce` (`PERMISSION_TOOL mcp`, `toolCall.title "RepoPrompt: read_file"` → `permission_response.optionId == allow_once`, run completes), `testNativeToolPermissionIsRejectedOnceInHeadlessRuns` (`shell` → `reject_once`, run throws). Land after live gate U1.

**C3 — Delete the inert `--permission-mode` plumbing** (~110 src / ~20 test, all deletions) — §4.2. Atomic. Assert in `DevinACPAgentProvider` tests (if any) that `arguments == resolvedLaunch.arguments`.

**C4 — Devin reasoning effort via `thought_level`** (~60 src / ~55 test)
§4.4 provider/discovery/resolver/config/headless/runtime-service/runner. Tests in the C2 file: `testModelThoughtLevelThenModeAreAppliedInOrderBeforePrompt` (level `.smart`, model `gemini-3-8-flash-medium`, thinking pin `low` → `configId` sequence `[model, thought_level, mode]`, values as expected, all before `session/prompt`), `testStaleThoughtLevelSelectionFailsBeforePrompt` (pin `xhigh` for that model → throws `ACPModelParameterSelectionError`, no prompt), `testDiscoveryPublishesPerModelThoughtLevelSets` (call `DevinModelDiscoveryService.runThrowawaySession(config, publish: recorder)` → exactly one `model` set RPC (the non-current model), published `currentModelRaw` == bootstrap, 2 sets with per-model defaults), `testThoughtLevelAndSpeedClassification` (unit, `DevinACPAgentProvider.modelParameterKind`).

**C5 (optional) — MCP `model_parameters` for Devin** (~8 src) — §4.4 last paragraph; reuse `CursorACPParameterBindingTests`' shape for one `resolve` case if desired (+10).

**Totals:** ≈400 lines added/modified + ≈130 pure deletions (C3) ≈ 530 gross. If the ~420 gross cap is hard: land C3 as its own deletion-only PR (it is mandated by the candidate design but is zero-risk to review), fold C1's tests into the C2 harness file (−20), skip C5 and `speed` (−10) → ≈390 gross for C1+C2+C4.

---

## 8. Remaining genuine unknowns (validate before/while landing)

- **U1 (gates C2):** Does Devin's `session/load` response carry `configOptions` (or emit `config_option_update` during replay)? If not, resumed runs fail at every level except Provider Default. Decide then: keep fail-closed (recommended) or skip the mode step on load-without-metadata (reopens the inherited-bypass hole).
- **U2 (gates C4):** Does `AgentACPModelRegistry.resolvedSnapshot(for: .devin)?.modelParameterSets` round-trip what `updateDiscoveredModels` stored? Fallback: read `ACPDynamicModelStore.load`.
- **U3:** Shape of Devin's `session/request_permission` for an MCP tool call (`toolCall.title`, `_meta.cognition.ai/*`, `rawInput`) — determines whether `repoPromptPermissionAutoApprovalMatch` + strict check fire. Contingency: derive `requestToolName` from `_meta` for Devin in the permission handler (~10 lines).
- **U4:** Enumeration latency with 15–25 models; whether any model set is policy-refused (skipped by design).
- **U5:** `_meta.parameterizedModelPicker: true` in `initialize` must be ignored by Devin (spec-extensible; low risk).
- **U6:** Exact `ACPIntegratedAgentModeRunner` gating/order (~L979 and parameter application) — read and adjust ≤5 lines.
- **U7:** Whether `speed` is per-model and how the existing `.speed` UI renders for Devin; drop the classification line if it misbehaves.
- **U8:** Where `DevinModelDiscoveryService.discoverIfNeeded` is triggered besides Settings; after C4 it is the only model-list refresh path.
- **U9:** Can org policy hide `accept-edits`? Then Normal/Accept Edits fail before prompt (acceptable, fail-closed).
- **U10:** Whether Devin accepts `mode` changes mid-turn (live change while `promptRunning`); failure is logged only.
- **U11:** Any callers of `AgentProviderPermissionProfile.acpSessionModeID(for:)` on the Devin runtime path.

---

## 9. Live-verification procedure

**Setup:** `devin` 3000.11.x logged into the enterprise account; scratch workspace; debug CE build (rpce-debug-build-validation skill) with `AgentRuntimeProviderService.enableDebugLogging` on and the DEBUG raw ACP capture (`resolveRawACPCaptureURL` env) enabled; the probe in `prompt-exports/devin-acp-probe.py`.

**A. Probe (no app), resolves U1/U3/U4:**
1. Extend the probe with `--load <sessionId>`: run `session/new`, note `sessionId`, exit; rerun with `--load` and dump the full load response + any `session/update` with `config_option_update`/`current_mode_update`. Record whether `configOptions` is present.
2. Extend the probe to dump the full `toolCall` (incl. `_meta`, `rawInput`) of `permission_requests`; launch `--pre "--config <isolated config with the RepoPrompt MCP server>"` (generate it with the app's `DevinIntegrationConfiguration` output) and `--prompt "use the RepoPrompt read_file tool on README.md"`. Record the payload shape.
3. Time a loop of `--cfg model=<m>` over every advertised model (or watch step B1's log) to estimate enumeration cost.

**B. Interactive (debug app, Agent Mode → Devin):**
1. Settings → Devin → refresh models: `[ACP][devin]` log shows N−1 `session/set_config_option configId=model`; `defaults read … ACPDynamicModelProviders` contains Devin `modelParameterSets`.
2. Select `swe-2-high` → effort chip offers `[medium, high, max]` default `high`; select `max`; run; capture shows `model` → `thought_level=max` → (`mode`) → `session/prompt`. Switch to `gemini-3-8-flash-medium` → chip shows `[low, medium, high]`.
3. Levels: Full Approval → run fails before prompt with the org-policy text / "Available modes: accept-edits, smart, ask, plan"; Smart → `mode=smart` RPC; Normal → no mode RPC on a fresh session; change Normal→Smart mid-run → live `set_config_option mode=smart`.
4. Approvals at Normal: ask for a shell command → card; "Allow" → wire `optionId allow_once`; "Allow for session" → `allow_session`; confirm `allow_always` never appears in outbound.
5. RepoPrompt tool call at Normal → auto-approved `allow_once` without a card (depends on A2).
6. Resume: follow-up in the same conversation; then restart the app and continue → mode applied before prompt (depends on A1).

**C. MCP-originated (rpce-cli-debug against the debug app):** `agent_run.start` with Devin under Safe Managed → capture shows `mode=accept-edits`; with C5, `model_parameters: [{config_id: thought_level, value: max}]` → applied; an invalid value → `invalidParams`.

**D. Headless:** Context Builder delegate-edit with Devin → capture shows model → thought_level → mode → prompt and `allow_once` auto-approval for RepoPrompt tools; a native shell prompt → `reject_once` and run failure with the bridge's message.

**E. No-policy host (optional, Docker):** Full Approval → `mode=bypass` succeeds; Smart → fails before prompt with "Available modes: accept-edits, ask, plan, bypass".

### Oracle 2
- Lane index: 1
- Role: `additional`
- Chat ID: `new-chat-oracle-2-3D0358`
- Provider: _Not specified._
- Model: `devin_custom_gpt-6-astra-medium`
- Status: `completed`
- Execution provider: `devin`
- Execution model: `gpt-6-astra-medium`

#### Response



## 1. Summary

Reimplement this as a **targeted correction to the existing ACP integration**, not a provider-framework refactor: discover Devin’s per-model `thought_level` definitions through the existing disposable discovery session; reuse the existing parameter selection, persistence, and verification pipeline; carry permissions exclusively through ACP’s advertised mode selector; and select Devin approval options by exact identifier. Keep enterprise policy authoritative: unavailable or rejected `bypass` fails before prompting, rather than falling back or manufacturing allow-rules. Target **four commits, approximately 405 changed lines including tests**. That is a planning budget, not a measured diff: several relevant caller bodies and reusable test fixtures were not supplied.

## 2. Current-state analysis

### Baseline

The implementation starts from **current `origin/main`**, interpreted as the supplied sources minus the supplied discarded-branch patch.

Consequently, do **not** treat these as existing main behavior:

- Devin ACP session-mode mappings or headless mode application.
- Devin strict RepoPrompt MCP auto-approval.
- The optional-returning, safe approval fallback.
- The resumed-`bypass` guard.
- Devin-specific parameter rejection messaging and `supportsModelParameters` predicate.
- The new headless boundary harness or controller test seams.
- Preference-driven one-shot CLI permission flags.

Main’s one-shot `DevinCLIProvider` passes `"auto"` independently of ACP. **Leave that provider unchanged.**

### Model and effort flow

The reusable path is:

1. `DevinModelDiscoveryService.runThrowawaySession` opens a disposable ACP controller.
2. `ACPAgentSessionController` parses modern `configOptions`.
3. `ACPAIModelCatalog` exposes registry models; `ACPDynamicModelStore` already supports persisted `modelParameterSets`.
4. `ACPModelParameterResolver` resolves picker definitions and stored selections.
5. Agent Mode stores selections in `acpModelParameterSelections`; MCP staging already protects rollback with session identity and per-selection revisions.
6. The runner applies configuration and the controller rechecks explicit parameter selections immediately before `session/prompt`.

The blockers are Devin’s missing capability opt-in/classification, missing catalogue parameter collection/resolution, and missing headless selection forwarding.

Importantly, opting into `supportsParameterizedModelPicker` disables the controller’s automatic provider-global publication. **Discovery must explicitly publish the completed Devin catalogue.**

### Permission flow

Main resolves secure provider preferences through:

`AgentProviderPermissionProfile` → `AgentProviderPreferenceSnapshotStore.runtimePermission` → `ACPRunRequest` → provider launch/controller.

For Devin, main uses the inert launch flag and compares that carrier in controller reuse. The correct existing extension point is `setSessionMode`: it validates advertised values, sends `session/set_config_option`, and verifies the response. String `error.data` already reaches users; no error-parser change is needed.

The supplied evidence establishes:

- `normal` cannot mean “ask before edits” in ACP.
- `accept-edits` is Code mode, not a read-only boundary.
- `smart` and `bypass` availability varies by account.
- `ask` and `plan` must not become permission mappings.

### Approval flow

Main excludes Devin from strict RepoPrompt MCP auto-approval. Its user-approval fallback can select a rejection or empty identifier when no allow option matches.

The shared RepoPrompt request matcher remains reusable. Devin’s **option selection**, however, must not use kind matching: `allow_session` itself has kind `allow_always`.

## 3. Design

### A. Effort: use the existing catalogue, not another polling service

**Keep the catalogue-enumeration candidate.** OpenCode’s demand-scoped polling actor is unnecessary for this patch: Devin already has a disposable catalogue discovery session, and the verified variation is per model. Catalogue metadata is picker/request-validation data, **not runtime authority**.

#### Provider capability

In `DevinACPAgentProvider`:

- Return `true` from `supportsParameterizedModelPicker`.
- Classify the advertised `thought_level` category as `.thinking`.
- Preserve the advertised selector ID and raw choices.
- Do not classify `speed` in this change.
- Never strip effort-looking suffixes from model IDs or synthesize model variants.

The existing initialization handshake and generic parser do the remaining work.

#### Discovery algorithm

Extend `DevinModelDiscoveryService.runThrowawaySession`, retaining its existing signature and disposable-controller lifecycle:

1. Bootstrap and retain the original catalogue: model options and original current model.
2. Iterate its concrete advertised model options serially.
3. Before each iteration, check cancellation.
4. Call `discoverSessionModelParameters(for:)`; this forces the verified model-selector mutation.
5. Collect only parameter sets matching that advertised model’s canonical identity.
6. A model legitimately advertising no usable effort selector contributes no set.
7. A failed model mutation or malformed/mismatched response aborts discovery. Do not publish a partial sweep.
8. After a final cancellation check, publish **one** aggregate `ACPDiscoveredSessionModels`, containing:
   - Original bootstrap options.
   - Original bootstrap current model.
   - Collected per-model parameter sets.
9. Shut down on success, error, or cancellation.

Do not publish the final probed model as the provider default. Do not merge old parameter sets into a successful new sweep.

A failed refresh preserves the previously published catalogue; discovery reports failure and remains retryable through the existing `Outcome` rules. Cached choices may therefore be stale, but launch-time validation must reject stale intent.

**Cost:** one bootstrap plus one sequential model mutation per concrete model; space proportional to total advertised choices. No prompts, tool execution, parallel processes, or new timer.

#### Catalogue and MCP readers

Extend existing switches rather than adding the discarded capability predicate:

- `ACPModelParameterResolver.parameterSet`: for `.devin`, read the registry snapshot and require exactly one set matching the selected model.
- Preserve unsupported saved Devin effort in the picker, using the existing OpenCode treatment rather than displaying a misleading default.
- `AgentMCPModelParameterSupport.definitions` and synchronous `resolve`: permit Devin alongside Cursor, using the existing resolver.
- Async overloads delegate Devin to those synchronous catalogue paths.
- Keep OpenCode’s asynchronous freshness policy unchanged.
- Keep missing metadata and unsupported values as argument errors; never return successful empty selections for a nonempty explicit request.

No special Devin rejection string is needed.

#### Runtime and headless application

Add one immutable configuration property:

`DevinAgentConfig.modelParameterSelections: [ACPModelParameterSelection]`, default `[]`.

`AgentRuntimeProviderService` supplies it at the existing Devin headless construction site, next to OpenCode’s equivalent forwarding. `DevinACPHeadlessAgentProvider.makeRunRequest` places it in `ACPRunRequest.modelParameterSelections`.

Both launch paths use:

**model → effort → `validateNoSkippedSelections()` → mode → final checks → prompt**

For Devin with a concrete selected model, force the model RPC **on each turn**, including a reused session. This intentionally restores that model’s advertised defaults before reapplying explicit selections; otherwise clearing an effort pin could retain a previous turn’s effort.

For provider-default model selection with no explicit pin, do not invent a model or effort mutation.

The existing `validatePromptModelParameterSelections` remains the final authority: a later mode response that changes model or effort must prevent prompting.

### B. Permissions: explicit ACP modes, no launch-time fiction

#### Exact mapping

| Stored level | ACP mode | Behavior |
|---|---|---|
| `providerDefault` | None | Leave the session’s current mode unchanged, including on resume. |
| `normal` | `accept-edits` | Legacy Normal maps to Code; it does not promise approval before edits. |
| `acceptEdits` | `accept-edits` | Code mode. |
| `smart` | `smart` | Require advertised Smart support. |
| `fullApproval` | `bypass` | Require advertised Bypass support and successful confirmation. |

Keep persisted enum cases and raw values unchanged. Label `.normal` **“Normal (Code mode)”** and make its detail text explicitly disclose automatic edits. This avoids a schema migration or extra alias-normalization layer.

All permission detail text must say changes apply **on the next turn**. Full Approval must disclose that organization policy may make it unavailable.

Use this mapping for **all prompted headless ACP runs**, independently of MCP injection. Discovery creates its own no-prompt request and sends no mode.

Both ACP auto-approval flags remain false for Devin. Neither Full Approval nor changing preferences implicitly answers a pending permission request.

#### Shrink the live-change candidate

**Do not add Devin to the live `.openCode, .antigravity` branch.** Keep main’s next-turn behavior.

That branch launches untracked asynchronous mutations and exposes failures only through debug logging. Reusing it would add race and failure-reporting obligations unrelated to fixing per-turn permission application. The small, precise contract is:

- An active turn retains its existing mode.
- An already pending approval remains pending.
- The user may answer or cancel it.
- The next turn resolves preferences again and applies/verifies the requested mode.

No bespoke Devin branch, per-tab queue, preference task, or pending-approval auto-accept is needed.

#### Remove the inert ACP carrier

Remove the Devin-only ACP launch-permission plumbing as one atomic change:

- `ACPRunRequest.launchPermissionMode`.
- `AgentProviderRuntimePermissionBinding.acpLaunchPermissionMode`.
- Their initializer arguments and forwarding.
- Controller `launchedPermissionMode`, normalization, and reuse comparison.
- Devin ACP flag construction.
- Preference helpers used exclusively by that removed ACP carrier.

Retain provider/workspace compatibility and Grok’s existing launch-sensitive checks. Permission changes no longer require relaunching Devin; the next turn’s mode mutation establishes the new mode.

Do not change one-shot `DevinCLIProvider`, its `"auto"` flag, or its test API.

#### Final permission admission

Add a small synchronous controller check, `validatePromptSessionMode(_:)`, called immediately before prompt dispatch beside the existing parameter check.

For Devin:

- Nil/blank requested mode means no mode assertion.
- An explicit requested mode requires a usable live mode snapshot and a matching confirmed current value.
- Missing, malformed, unsupported, or mismatched mode state throws before sending `session/prompt`.

Other providers retain existing behavior.

This is **not** a resume-specific guard. Explicit `normal`/Code downgrades resumed `bypass` through the ordinary mode mutation. Explicit Provider Default deliberately preserves the loaded mode.

Do not claim this enforces a sandbox or cancels already-running tools. It verifies the mode at turn admission.

### C. Approval selection: exact Devin identifiers

Keep the shared RepoPrompt request-identity match and its strict ACP qualification unchanged.

After that qualification succeeds, Devin automatic approval selects only:

- Exact `optionId == "allow_once"`.

No aliases, kind fallback, prefix matching, mode switches, session grants, or persistent grants. If absent, surface the approval normally; the existing headless bridge declines unsupported requests.

For explicit user decisions:

| Decision | Devin option preference |
|---|---|
| `.accept` | Exact `allow_once` only |
| `.acceptForSession` | Exact `allow_session`, then exact `allow_once` |
| `.acceptWithExecpolicyAmendment` | Same session-scoped mapping already used by this ACP interface |
| No eligible allow option | Respond with `outcome: cancelled` |

Change `preferredAllowOptionID` from `String` to `String?`. Update its accept-family response construction accordingly.

For other providers, preserve established preference ordering but replace main’s arbitrary-first/empty fallback with an allow-kind-only fallback or nil. Keep Grok’s existing denylist.

**Do not port Devin’s large denylist from the discarded branch.** An exact allowlist already excludes every mode-switch and broader grant, including future identifiers.

### D. State, ownership, and compatibility

- Discovery remains actor-owned; no new actor or observation store.
- Session configuration remains controller-owned and serialized by `configurationMutationMutex`.
- UI/persistence remain owned by existing main-actor session/view-model paths.
- Parameter persistence uses the existing fields: `providerID`, `baseModelRaw`, `kind`, `configID`, `valueRaw`.
- Catalogue persistence already has optional `modelParameterSets`; no schema addition is required.
- Preserve MCP staging, revision checks, rollback, and save scheduling unchanged.
- Existing inbound configuration sequencing and final prompt checks handle late snapshots. Do not add another sequencing mechanism.
- Cancellation leaves discovery’s previous published catalogue intact and shuts down its disposable controller. A partially configured run that errors must not prompt; the next attempted turn reconfigures and verifies again.

## 4. File-by-file impact and commit budgets

Paths below are relative to `Sources/RepoPrompt/`, unless prefixed with `Tests/`. Counts mean **additions plus deletions**, not net additions.

### Commit 1 — Correct Devin ACP permission transport
**Budget: approximately 145 lines, including 30 test lines**

| File | Exact change |
|---|---|
| `Infrastructure/AI/Providers/Devin/DevinAgentToolPreferences.swift` | Add `PermissionLevel.sessionModeID`; revise `displayName`/`detailText`; remove ACP-only CLI mapping/reverse-mapping helpers made unused by this commit. Preserve stored cases and preference access. |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift` | In `runtimePermission`, return Devin’s `acpSessionModeID`; keep both automatic-approval flags false. |
| `Features/AgentMode/Runtime/ProviderBindings/AgentProviderBindingModels.swift` | Remove `acpLaunchPermissionMode` and its initializer argument. |
| `Features/AgentMode/Providers/ACP/ACPAgentProvider.swift` | Remove `ACPRunRequest.launchPermissionMode` and its initializer argument. |
| `Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift` | `makeLaunchConfiguration` uses resolved ACP arguments without permission flags. |
| `Infrastructure/AI/ACP/ACPAgentSessionController.swift` | Remove launch-carrier state/reuse checks; remove forwarding in `effectivePromptRunRequest`; add final `validatePromptSessionMode` admission check. |
| `Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift` | Remove launch-carrier forwarding; ensure Devin reaches the existing mode-application step. |
| `Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift` | `makeRunRequest` resolves the permission level per request; `beforePrompt` applies mode after model. |
| Existing `DevinPermissionLevelTests` source | Replace ACP argv/reuse expectations with mapping, profile-isolation, and unchanged stored-value tests. |

Named tests:

- `testDevinACPModesMapNormalToCode`
- `testDevinSafeManagedIgnoresGlobalFullApproval`
- `testDevinACPLaunchDoesNotContainPermissionMode`
- `testDevinPermissionChangeDoesNotInvalidateControllerReuse`

**Atomic:** carrier removal, all initializer/forwarding updates, and mode wiring must land together.

### Commit 2 — Publish and consume Devin effort metadata
**Budget: approximately 90 lines, including 25 test lines**

| File | Exact change |
|---|---|
| `Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift` | Add capability opt-in and `modelParameterKind(for:)`. |
| `Infrastructure/AI/Providers/Devin/DevinModelDiscoveryService.swift` | Extend `runThrowawaySession` with the serial sweep and single aggregate publication. |
| `Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift` | Extend `parameterSet` for Devin; preserve unsupported saved Devin intent in `resolve`. |
| `Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift` | Extend existing `definitions` and `resolve` overloads for registry-backed Devin definitions. |
| Existing `CursorACPParameterBindingTests` source | Reuse its parameter fixtures for Devin model-specific definitions, saved intent, and MCP resolution. |

Named tests:

- `testDevinThinkingUsesAdvertisedSelectorAndChoices`
- `testDevinEffortDefinitionsAreModelSpecific`
- `testDevinUnsupportedSavedEffortRemainsVisible`
- `testDevinMCPRejectsEffortOutsideSelectedModelsChoices`

The capability opt-in and explicit discovery publication must land together; otherwise discovery stops refreshing the global Devin catalogue.

### Commit 3 — Apply effort through both real ACP run paths
**Budget: approximately 100 lines, including 70 test/fixture lines**

| File | Exact change |
|---|---|
| `Infrastructure/AI/Providers/Devin/DevinAgentConfig.swift` | Add immutable `modelParameterSelections`, with an empty default. |
| `Features/AgentMode/Runtime/Providers/AgentRuntimeProviderService.swift` | At the supplied Devin construction site around line 349, forward selections as OpenCode already does. Confirm this file’s directory before editing; its full path was not supplied. |
| `Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift` | Forward selections in `makeRunRequest`; force concrete model, apply selections, validate report, then apply mode. |
| `Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift` | Include Devin in existing model-selection handling; force its concrete model RPC; retain common parameter application and mode-last order. |
| Existing `GrokBuildACPHeadlessAgentProviderTests` source | Reuse/parameterize its scripted ACP fixture for a compact Devin case matrix; do not copy the discarded headless harness. |
| Existing `CursorACPParameterBindingTests` source | Extend an existing ordered configuration fixture to verify Devin catalogue aggregation and final-admission rejection. |

Named tests:

- `testDevinDiscoveryPreservesBootstrapModelAndCollectsPerModelEffort`
- `testDevinModelEffortModePrecedePrompt`
- `testDevinClearedEffortPinRestoresModelDefault`
- `testDevinCodeDowngradesLoadedBypass`
- `testDevinUnavailableOrRejectedModePreventsPrompt`
- `testDevinLaterConfigurationDriftPreventsPrompt`

Use table-driven cases for missing mode metadata, unadvertised Smart/Bypass, RPC policy rejection, and effort drift. Assert outbound requests and absence of `session/prompt`, not just thrown errors.

### Commit 4 — Make Devin approval decisions request-scoped
**Budget: approximately 70 lines, including 35 test lines**

| File | Exact change |
|---|---|
| `Infrastructure/AI/ACP/ACPAgentSessionController.swift` | Remove the Devin exclusion in `autoApprovalSelection`; select exact `allow_once`; return optional allow selections; encode cancellation when none exists. |
| Existing `DevinPermissionLevelTests` source | Add a compact approval-selection matrix using existing controller fixtures. Add only the two small DEBUG seams from the supplied branch if no existing fixture exposes these decisions. |

Named tests:

- `testDevinRepoPromptAutoApprovalRequiresExactAllowOnce`
- `testDevinBareToolNameDoesNotAutoApprove`
- `testDevinAcceptForSessionUsesExactSessionThenOnce`
- `testAcceptWithoutEligibleAllowOptionCancels`

Include deceptive cases such as `allow_session` carrying kind `allow_once`, aliases `once`/`allow-once`, a mode-switch option, and reject-only options.

### Deliberately unchanged

- `DevinCLIProvider.swift`.
- `AgentModeProviderBindingService.swift`.
- `AgentProviderPermissionProfile.swift`.
- `AgentPermissionSecureStore.swift`.
- `AgentModeViewModel+MCPModelParameters.swift`.
- Generic composer readers.
- `ACPAIModelCatalog.swift` persistence structures.
- OpenCode polling and Cursor provider implementation.
- `ACPHeadlessAgentProviderBridge.swift`.
- `MCPIntegrationHelper.swift`.
- `ACPProviderSupport.swift`.
- The unrelated MCP tab-context changes in the discarded patch.

**Total target: approximately 405 changed lines, leaving roughly 15 lines of contingency.** Do not satisfy the target by dropping boundary checks or duplicating a fixture outside the count.

## 5. Risks and migration

### Intentional behavior changes

- Legacy Normal now explicitly selects Code. This can downgrade resumed Bypass, but **does not establish prompt-for-edits behavior**.
- Explicit unsupported modes fail rather than silently using the current mode.
- Provider Default may preserve resumed Bypass; its detail text must disclose that it does not reset the session.
- Permission changes apply next turn, not to an active turn.
- A concrete Devin model is reapplied each turn to make clearing an effort pin meaningful.

No permission-schema migration is required. Existing catalogue records without parameters remain readable; effort controls appear after successful discovery.

Rollback to main reads the same preference values and catalogue schema, but does not honor new Devin effort pins. This is behavioral rollback, not data corruption.

### Genuine implementation-validation gaps

1. **Unshown caller bodies and test fixtures.** The exact runner request-builder method names, full `AgentRuntimeProviderService` path, and test fixture APIs were not supplied. Validate these by targeted symbol searches before editing; do not invent a new harness to avoid inspecting them.
2. **Prompt admission atomicity.** Verify final validation and outbound request registration have no intervening suspension that admits another configuration mutation. Use the existing prompt-admission mechanism; this must not become a mutex held for the entire streaming turn.
3. **Discovery sweep behavior.** The probes establish per-model choices, not the latency or completeness of a full account catalogue sweep. Measure a full refresh; failure must remain retryable and must not publish partial parameter authority.
4. **Catalogue context.** Workspace/account invariance is not proven. The design remains safe by treating cached definitions as advisory and requiring live validation. If live testing finds materially different workspace choices, the static catalogue may be inconvenient; do not silently expand this patch into OpenCode-style polling.
5. **Shared server matching is broader than exact equality.** `MCPIntegrationHelper.isRepoPromptServerIdentifier` accepts substring matches. This plan fixes approval scope, not server-identity authentication; do not describe the unchanged matcher as a new security guarantee.

## 6. Implementation order and verification

1. **Establish main and baseline failures.** Start a fresh branch from current `origin/main`; do not revert the discarded branch into shape. Verify that the listed discarded additions are absent. Run the three named existing suites before modifying them.

2. **Land Commit 1 atomically.** Run permission mappings and controller reuse tests. Verify ACP argv omits the permission flag while the one-shot CLI test remains unchanged.

3. **Land Commit 2.** Run catalogue, resolver, and MCP parameter tests. Verify one aggregate publication, bootstrap-current preservation, distinct per-model choices, and no publication after a failed/cancelled sweep.

4. **Land Commit 3 atomically.** Exercise actual headless streams through the existing scripted-process fixture. Verify request order and final admission on fresh, resumed, and reused sessions. Always dispose providers on both success and failure.

5. **Land Commit 4.** Run approval-selection tests plus existing non-Devin approval tests. Inspect recorded permission responses for exact identifiers or cancellation.

6. **Prove the packaged CE debug application.**
   - Use the repository’s documented debug-build/conductor workflow and `rpce-cli-debug`. Exact command syntax is not present in the supplied material; obtain it from the debug-validation skill and CLI help rather than substituting guessed commands.
   - Launch the packaged **CE debug** app, health-check it, and confirm the CLI targets that instance and the intended workspace.
   - Refresh Devin models from Settings. Inspect definitions for `swe-2-high`, the advertised Gemini model, and the advertised Lightning model; verify their differing effort sets.
   - Through `rpce-cli-debug`, create a Devin session using `agent_manage.create_session` or `agent_run.start` with an advertised model and explicit `model_parameters`. Poll the exact returned session/run to terminal state.
   - Capture ACP traffic proving model → effort → mode → prompt. Inspect the confirmed values, not the assistant’s claim about its own settings.
   - Repeat after clearing the effort pin and after switching models. Confirm the model’s default is restored when no pin remains.
   - On the enterprise account, run Code and advertised Smart successfully. Request Full Approval and verify policy/unavailability error with **no prompt sent**.
   - While a turn is awaiting approval, change the preference. Verify the existing approval is not automatically answered; after cancellation or explicit resolution, verify the next turn uses the new mode.
   - Exercise a harmless RepoPrompt read tool and capture exact `allow_once`. Exercise a native command requiring approval and verify it is not automatically accepted merely because Devin is selected.
   - Exercise the real headless caller that constructs `DevinAgentConfig`, not only Agent Mode.

7. **Use the supplied probe as an independent comparison.**
   - In a disposable workspace and isolated empty configuration, record advertised modes and model-specific effort resets using the existing `--cfg` and `--set-mode` options.
   - Compare enterprise rejection with the no-policy Docker advertisement. Unauthenticated Docker proves mode availability/mutation only—not successful model execution.
   - For a real Bypass→Code resume proof, use an authenticated policy-permitting account. If unavailable, report that live case as **INCONCLUSIVE**; retain the scripted boundary proof.
   - Do not add `permissions.allow` rules, change organization policy, or approve probe permission requests.

8. **Review the final artifact and size.** Record the actual test/build commands, debug-app identity, run IDs, wire-order evidence, and `git diff --numstat`. Keep the branch near the 420-line target; if fixture reuse or a missing caller materially exceeds it, report the measured reason rather than claiming the estimate was verified.
