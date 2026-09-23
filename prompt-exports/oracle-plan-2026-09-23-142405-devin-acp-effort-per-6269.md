# Oracle Plan

## Oracle group
- Group ID: `654DCE3F-6D3F-4578-8AD0-FAF5D5399BDB`
- Status: `failed`
- Oracle count: 2

## Oracle results

### Oracle (Primary)
- Lane index: 0
- Role: `primary`
- Chat ID: `devin-acp-effort-permiss-A0AE94`
- Provider: _Not specified._
- Model: `custom_provider_litellm-claude-fable-5-1-xhigh`
- Status: `failed`
- Execution provider: `Custom`
- Execution model: `litellm-claude-fable-5-1-xhigh`

#### Error
- Code: `provider_error`
- Message: status code 400 litellm.BadRequestError: Anthropic-oauthException - Anthropic OAuth upstream HTTP 400: {"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 200000 > 128000, which is the maximum allowed number of output tokens for claude-fable-5-1"},"request_id":"req_011CfLHM3onKUBJJRa95A77L"}

### Oracle 2
- Lane index: 1
- Role: `additional`
- Chat ID: `devin-acp-effort-permiss-5D98DE`
- Provider: _Not specified._
- Model: `devin_custom_gpt-6-astra-medium`
- Status: `completed`
- Execution provider: `devin`
- Execution model: `gpt-6-astra-medium`

#### Response

# Final minimal rewrite plan

## 1. Summary

Make a targeted rewrite against **current `origin/main`**, not a cleanup of the discarded branch. Reuse the existing ACP configuration machinery; discover Devin’s model-specific effort choices by enumerating models in the existing disposable discovery session; apply effort **after** model selection; and make advertised ACP session modes—not launch flags—control permissions. Keep Normal and Accept Edits as stored choices, both mapping to `accept-edits`, with honest descriptions. Unsupported or policy-refused Smart/Full Approval **fails without sending a prompt**. Do not synthesize allow-rules, add polling infrastructure, or change the non-ACP Oracle CLI’s existing permission behavior.

**Budget:** approximately **360–445 changed lines, including tests**, subject to the narrowly identified missing call-site evidence below.

## 2. Current-state analysis

### Evidence and baseline corrections

“Observation” below means directly present in the supplied frozen evidence. Recommendations and deductions are labeled separately.

| ID | Classification | Finding and evidence |
|---|---|---|
| **O1** | Direct observation | `thought_level` is a separate selector; model changes reset it, and choices/defaults differ by model. Consequently, neither suffix parsing nor a universal six-choice catalogue is correct. [devin-acp-probe-evidence.md:7-103](file:///Users/daniels/dev/repoprompt-ce/prompt-exports/devin-acp-probe-evidence.md) |
| **O2** | Direct observation | `ask` means “Answer questions without code changes.” It is not Normal permissions. Enterprise and Docker advertise different mode sets; forbidden bypass returns `"Invalid params"` with the useful policy explanation in `error.data`. [devin-acp-probe-evidence.md](file:///Users/daniels/dev/repoprompt-ce/prompt-exports/devin-acp-probe-evidence.md) |
| **O3** | Direct observation | Main already has the generic parameter parser, serialized configuration mutations, parameter application reports, and prompt-time effort validation. Parameterized providers do not automatically publish their session snapshots globally. [ACPAgentSessionController.swift:740-1420](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift) [ACPAgentSessionController.swift:2960-3060](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift) |
| **O4** | Direct observation | `setSessionModeSerialized` validates against the advertised selector before mutation and verifies the response. The supplied boundary test expects the unavailable-mode error to include `Available modes: accept-edits, smart, ask, plan`. The full formatter is outside the controller slices. [ACPAgentSessionController.swift:1050-1240](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift) [DevinHeadlessSessionModeBoundaryTests.swift](file:///Users/daniels/dev/repoprompt-ce/Tests/RepoPromptTests/AgentMode/DevinHeadlessSessionModeBoundaryTests.swift) |
| **O5** | Direct observation | The patch establishes that main excludes Devin from strict MCP auto-approval, has the unsafe first-option/empty-string accept fallback, and excludes Devin from the runner’s explicit-model guard. These require actual main-relative changes. [discarded-branch-source-diff-vs-main.patch](file:///Users/daniels/dev/repoprompt-ce/prompt-exports/discarded-branch-source-diff-vs-main.patch) |
| **O6** | Direct observation | The capability predicate, false combined-variant guards, resumed-bypass guard, label sanitizer, Devin denylist expansions, and four debug seams are discarded-branch additions—not main code to delete. The one-shot CLI preference-based escalation is also branch-only; main passes `--permission-mode auto`. [discarded-branch-source-diff-vs-main.patch](file:///Users/daniels/dev/repoprompt-ce/prompt-exports/discarded-branch-source-diff-vs-main.patch) |
| **O7** | Direct observation | Existing catalogue serialization already supports optional `modelParameterSets`; Devin’s model list already reads from `AgentACPModelRegistry`. No schema extension is needed for catalogue-backed effort metadata. [ACPAIModelCatalog.swift](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/ModelCatalog/Providers/ACPAIModelCatalog.swift) |
| **O8** | Direct observation | The headless bridge bootstraps, awaits `beforePrompt`, then prompts; errors abort and shut down the controller. Unsupported approvals are declined. [ACPHeadlessAgentProviderBridge.swift](file:///Users/daniels/dev/repoprompt-ce/Sources/RepoPrompt/Infrastructure/AI/Providers/ACPHeadlessAgentProviderBridge.swift) |

### Relevant ownership and flow

**Effort**

```text
DevinModelDiscoveryService disposable session
  → bootstrap model catalogue
  → select each advertised model
  → read that model’s thought_level definition
  → publish one complete catalogue with parameter sets
  → resolver / existing parameter controls / MCP
  → persisted ACPModelParameterSelection
  → ACPRunRequest.modelParameterSelections
  → select model → apply effort → select mode → validate → prompt
```

The discovery actor owns acquisition and cancellation. The registry owns cached picker metadata. The controller actor owns **live execution authority**. Cached choices are suggestions for selection, never permission to bypass live validation. **Inference from O1, O3, O7.**

**Permissions**

```text
stored level + permission profile
  → AgentProviderPreferenceSnapshotStore.runtimePermission
  → ACPRunRequest.sessionModeID
  → advertised-mode validation
  → session/set_config_option
  → confirmed mode
```

The main-actor binding service applies preference changes to an existing controller. The controller’s existing mutex serializes wire mutations. The bridge owns headless cleanup. **Observation:** these responsibilities already exist; only Devin’s routing is wrong or absent. **[O3, O4, O8]**

## 3. Design

### A. Use catalogue enumeration, not another polling system

**Choose option (b): enumerate every advertised model once per discovery refresh.**

Option (a) would require workspace/model snapshot types, observation ownership, asynchronous resolver inputs, and subscriptions across picker/MCP consumers. Option (b) fits the existing Devin discovery and persisted catalogue interfaces and needs no new service or observation type. **Inference from O1, O7 and the supplied OpenCode polling implementation.**

#### `DevinACPAgentProvider`

Add:

- `supportsParameterizedModelPicker == true`.
- `modelParameterKind(for:)` returning `.thinking` for normalized category `thought_level`; otherwise `nil`.

Preserve the advertised configuration ID and choice values. Do not classify by model suffix. Do not expose `speed` in this change.

#### `DevinModelDiscoveryService.runThrowawaySession(_:)`

Keep its existing `async throws -> Int?` signature and `SessionRunner` injection.

After bootstrap:

1. Capture the bootstrap `ACPDiscoveredSessionModels`.
2. For each unique advertised model option, sequentially call `discoverSessionModelParameters(for:)`.
3. Extract only the parameter set matching the confirmed requested model.
4. Accumulate these sets locally.
5. Publish **once**, using bootstrap `options` and `currentModelRaw`, plus the collected sets.
6. Return bootstrap `options.count`; shut down as today.

Important details:

- Preserve bootstrap current model; the last model interrogated is not the provider default.
- A verified model with no usable effort selector contributes no set.
- RPC failure, malformed confirmation, or cancellation aborts the refresh. Do not publish a partial catalogue or erase the previous one.
- Check cancellation between iterations and before publication.
- Reuse existing discovery coalescing and force-refresh behavior.
- Do not restore the probe’s initial model: the session is disposable.
- Complexity: **O(M)** sequential model RPCs and **O(M + C)** stored metadata, where `C` is the total advertised parameter choices.

Catalogue metadata is account/runtime-scoped picker information, not a claim that every workspace will accept it. The real session revalidates before execution. This avoids introducing workspace cache machinery solely to improve advisory metadata.

#### `ACPModelParameterResolver`

In `parameterSet(providerID:selectedModelRaw:workspacePath:openCodeParameters:)`, add `.devin`:

- Read `.devin` from `AgentACPModelRegistry`.
- Match `baseModelRaw` using existing canonical identity.
- Return a set only for one unambiguous matching model.

In private `resolve(parameterSet:providerID:persistedSelections:)`, include Devin in the existing unsupported-saved-choice display behavior. A stale saved High selection must not appear as Medium while execution still requests High.

**Do not introduce the discarded `supportsModelParameters` predicate or its selection-filter guards.** Main’s existing generic selection identity and normalization already support Devin. **[O6]**

#### MCP

Extend the existing catalogue-backed paths:

- Synchronous `definitions(agent:modelRaw:)`: permit Cursor and Devin, resolving through their respective `parameterSet` branches.
- Synchronous `resolve(value:agent:modelRaw:)`: likewise permit Devin.
- Async `definitions` and `resolve`: route Devin to those catalogue-backed paths.
- `definitionValues` requires no new signature; it already delegates.
- Keep existing `selection`, exact `config_id` validation, merge precedence, and serialization.

Missing metadata produces empty definition reads but rejects explicit parameter requests with the existing metadata-unavailable error. No new per-call discovery dependency.

#### Application order

For both ACP runners:

1. Select the explicit model.
2. Apply effective `modelParameterSelections`.
3. Call `validateNoSkippedSelections()`.
4. Apply the requested mode.
5. Retain existing prompt-time parameter validation.
6. Send `session/prompt`.

Do not send effort before the model. Do not force a model RPC merely to change effort when the live model is already confirmed; the existing no-op optimization is valid. If a model RPC does occur, its refreshed snapshot must determine whether effort needs reapplication.

No saved effort means **use the runtime’s resulting effort**, not “force Medium.” **[O1, O3]**

### B. Make ACP modes authoritative

#### Mapping

Keep all five stored enum cases; merging them would add migration and UI work for no protocol benefit.

| Existing level | ACP mode | Honest meaning |
|---|---|---|
| `providerDefault` | none | Leave the session’s current mode unchanged, including on resume |
| `normal` | `accept-edits` | Devin Code mode; edits may run without approval |
| `acceptEdits` | `accept-edits` | Same ACP behavior as Normal |
| `smart` | `smart` | Available only when advertised |
| `fullApproval` | `bypass` | Available only when advertised and accepted |

Normal’s detail text must explicitly state that Devin ACP has no separate prompt-for-edits Normal mode. Accept Edits’ detail text must identify the equivalence. Do not relabel either as Ask. **Recommendation grounded in O2.**

This mapping actively lowers resumed Smart/Bypass sessions to Code for Normal. **Do not port the discarded resume guard or introduce another one.**

Apply the same mapping to headless ACP runs. Discovery continues to request no mode.

#### Unavailable and policy-refused modes

**No automatic fallback.**

- Unadvertised Smart or Bypass: existing advertised-mode validation rejects before RPC and before prompt.
- Policy refusal after advertisement: propagate failure and do not prompt.
- Never try `autonomous`, `ask`, or `plan` as substitutes.
- Never compensate with blanket RepoPrompt approval.

Keep the existing unavailable-mode message and its available-mode list; add no error taxonomy. Full Approval’s detail text supplies the actionable explanation that Bypass may be unavailable.

Ensure a JSON-RPC rejection preserves its string `error.data` in the user-visible error. `"Invalid params"` alone is insufficient. This belongs in the controller’s existing JSON-RPC error construction, not string matching in Devin’s provider. The precise handler name is not included in the supplied slices; see the evidence gaps below.

**Full Approval without Bypass:** it is unavailable through this RepoPrompt setting. Users may separately configure administrator-permitted Devin allow-rules and choose an advertised mode. RepoPrompt does not generate rules or promise that `permissions.allow: ["exec"]` means unrestricted access. **[O2]**

**Oracle distinction:** ACP headless Full Approval fails as above. The genuinely non-ACP `DevinCLIProvider` retains main’s `--permission-mode auto`; do not import the discarded preference-based `dangerous` behavior. **[O6]**

#### Drop the inert ACP launch/reuse behavior

- `DevinACPAgentProvider.makeLaunchConfiguration`: remove permission-carrier validation and the permission-argument prefix.
- `ACPAgentSessionController.isCompatibleWith`: ignore `launchPermissionMode` for Devin.
- Remove `normalizedLaunchPermissionMode`; retain raw launch comparison for other providers if they still use it.
- Stop populating `acpLaunchPermissionMode` for Devin.

Keep the generic optional request/binding fields in this bounded rewrite rather than remove them and change unrelated callers. They no longer affect Devin launch or compatibility. Keep CLI token generation untouched.

#### Live preference changes

In `providerPreferenceChanged`:

- Route Devin through live `setSessionMode`, using the profile-resolved runtime binding.
- Leave Provider Default as no mutation.
- Keep `autoApproveAllACPToolPermissions` and `acceptsPendingACPApprovalWhenActivated` false for Devin.
- Never resolve a pending approval solely because Full Approval was selected.

Serialize Devin preference-update tasks per tab in this service: each waits for its predecessor, then verifies that the tab still owns the captured controller. This avoids older tasks applying after newer selections. Completed entries are removed only if still the latest entry.

For visible failures, extend the existing controller interface with a defaulted argument:

> `setSessionMode(_:reportFailure: Bool = false) async throws`

The live binding call passes `true`; initial configuration callers retain the default. On failure, the controller emits its existing `.stream` error event and rethrows. Cancellation is not reported as a configuration error. This uses the established transcript event path without inventing a session error API.

A failed live change does not undo already executed tools or silently assert success. Saved preference remains requested intent; the next turn attempts it again and fails before prompting if still unavailable.

### C. Exact permission-option IDs and safe accept fallback

After the existing strict RepoPrompt match succeeds:

| Action | Devin IDs permitted |
|---|---|
| Automatic MCP approval | exact `allow_once` only |
| User Accept | exact `allow_once` only |
| User Accept for Session / amendment | exact `allow_session`, otherwise exact `allow_once` |

Use raw, case-sensitive ID equality. Do not use the generic normalized matcher, aliases, labels, or `kind` for Devin.

If no eligible option exists:

- Automatic approval returns nil.
- Explicit accept responds `cancelled`.

Main still has the unsafe fallback. Change:

> `preferredAllowOptionID(...) -> String` → `String?`

Update the accept-family cases in `respondToPermissionRequest` to handle nil. For other providers, retain their preference lists, but allow fallback only to an allow-kind option after existing safety filtering—not the first arbitrary option or an empty ID. **[O5]**

No changes to `MCPIntegrationHelper` or main’s `ACPPermissionOptionPolicy`. Do not import Devin denylists or label sanitization.

## 4. Ordered commits and file-by-file impact

Paths below are relative to the repository root. Estimates count additions **plus** deletions against main.

### Commit 1 — Discover and resolve Devin effort through the existing catalogue
**85–100 lines**

- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift`
  - Add capability and classifier.
  - Keep all launch behavior until commit 4.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinModelDiscoveryService.swift`
  - Extend `runThrowawaySession(_:)` with sequential enumeration and single publication.
  - Keep `SessionRunner`, `Outcome`, coalescing, and cleanup.
- `Sources/RepoPrompt/Features/AgentMode/Models/ModelSelection/AgentModelParameter.swift`
  - Extend `parameterSet` and saved-intent handling in `resolve`.
- `Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentMCPModelParameterSupport.swift`
  - Extend synchronous and asynchronous `definitions`/`resolve`; no signature changes.

**Atomic:** opt-in, catalogue publication, and readers land together.

**Do not port:** capability-exclusion guards, combined-variant error strings, new polling/snapshot types.

### Commit 2 — Carry effort through actual ACP runs
**25–40 lines**

- `Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift`
  - Add Devin to the explicit-model guard at **main lines 979–986**, identified by the patch.
  - Ensure existing model → parameters → mode sequence includes Devin.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinAgentConfig.swift`
  - Add immutable `modelParameterSelections: [ACPModelParameterSelection]`, default `[]`, for headless configuration.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift`
  - `makeRunRequest`: carry those selections.
  - `beforePrompt`: apply and validate them after model selection.

Keep main’s provider-agnostic MCP staging/rollback code unchanged. No schema changes.

**Evidence gap:** the selected material does not identify the headless configuration producer that owns role/preset effort selections, nor all picker readers. Those call sites must pass existing effective selections rather than leave the new field permanently empty. Their allowance is included here, but their exact names cannot be truthfully supplied from this selection.

### Commit 3 — Use one honest ACP permission mapping
**40–50 lines**

- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinAgentToolPreferences.swift`
  - Add `PermissionLevel.sessionModeID`.
  - Update `detailText`; preserve stored cases.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPreferenceSnapshotStore.swift`
  - `.devin` in `runtimePermission`: emit session mode, not launch mode; both approval booleans remain false.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentProviderPermissionProfile.swift`
  - `.devin` in `acpSessionModeID(for:)`: resolve profile through `devinPermissionLevel(userConfigured:)`, then its session mode.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPHeadlessAgentProvider.swift`
  - Resolve stored level per request, retain the compact injected-level test override.
  - Apply mode after effort in `beforePrompt`.

**Do not port:** separate unattended ACP mapping, bypass-resume guard, CLI escalation helper.

### Commit 4 — Remove inert launch authority and apply modes live
**55–70 lines**

- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinACPAgentProvider.swift`
  - Simplify `makeLaunchConfiguration`.
- `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift`
  - Adjust initializer/reuse comparison and remove normalization helper.
  - Extend `setSessionMode` with opt-in failure reporting.
  - Preserve string RPC `error.data` if the existing error constructor drops it.
- `Sources/RepoPrompt/Features/AgentMode/Runtime/ProviderBindings/AgentModeProviderBindingService.swift`
  - Split Devin from main’s Grok launch-only case.
  - Add live-mode application and bounded per-tab sequencing.
- `Sources/RepoPrompt/Infrastructure/AI/Providers/Devin/DevinAgentConfig.swift`
- `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentProviderFactory.swift`
  - Correct existing comments that name the removed launch authority; no functional factory change.

Keep `DevinCLIProvider.swift` unchanged at main.

### Commit 5 — Make Devin approval scope exact and fix unsafe accept fallback
**35–45 lines**

- `Sources/RepoPrompt/Infrastructure/AI/ACP/ACPAgentSessionController.swift`
  - `autoApprovalSelection`: remove main’s Devin exclusion; exact `allow_once`.
  - `preferredAllowOptionID`: optional result and exact Devin branches.
  - `respondToPermissionRequest`: nil means cancelled.
  - Add only the two small approval-selection debug seams from the supplied pattern if needed.

Keep `ACPProviderSupport.swift` and `MCPIntegrationHelper.swift` unchanged.

### Commit 6 — Add compact regression coverage and run live acceptance
**120–140 lines**

- `Tests/RepoPromptTests/AgentMode/DevinHeadlessSessionModeBoundaryTests.swift`
  - Reuse the supplied Python-stdio pattern, but not its obsolete assertions or comment volume.
  - Extend the provider wrapper to forward `supportsParameterizedModelPicker`, `modelParameterKind`, and `cleanupLaunchArtifacts`; otherwise the wrapper disables the feature and leaks launch artifacts.
- Existing `DevinPermissionLevelTests.swift`
  - Add compact table-driven mapping/approval cases alongside main’s existing level tests.
- Add `Tests/RepoPromptTests/AgentMode/DevinACPParameterBindingTests.swift` only if no existing parameter suite can hold the small catalogue/resolver cases.

**Total: 360–445 changed lines.** The supplied patch covers Sources only; whether the boundary harness exists on main must be checked. If it is absent, its compact implementation counts in the estimate—none of its discarded test lines are “free.”

### Test names and assertions

| Test | Required assertion |
|---|---|
| `testDevinACPModeMapping` | Five-level table; Normal and Accept Edits both Code; no Ask/Plan |
| `testDevinRuntimeBindingRespectsPermissionProfile` | Safe Managed and override resolution; no launch flag or blanket approval |
| `testDevinThoughtLevelClassification` | Category classification preserves arbitrary advertised ID; speed ignored |
| `testDevinCatalogueParametersAreModelSpecific` | SWE and Gemini retain different choices/defaults; missing model returns nil |
| `testModelResetReappliesEffortBeforePrompt` | Fake model mutation resets effort; recorded sequence is model → effort → mode → prompt |
| `testUnsupportedEffortPreventsPrompt` | Model-specific invalid value produces no prompt |
| `testUnavailableOrRefusedModePreventsPrompt` | Table: missing Smart, missing Bypass, policy refusal with explanation in `data` |
| `testNormalLowersResumedBypassToCode` | `accept-edits` applied before prompt; no resume-only logic |
| `testDevinExactApprovalScope` | Exact IDs only; persistent/alias/kind-only candidates not selected |
| `testAcceptWithoutAllowOptionCancels` | Reject-only and empty options never become selected accept responses |
| `testDevinLiveModeChangeReusesController` | Ordered live updates, same controller, no automatic pending approval |
| `testDiscoveryFailureDoesNotPublishPartialCatalogue` | Failed/cancelled enumeration preserves previous snapshot and shuts down |

Use table-driven cases and existing process helpers; do not create another general ACP test framework.

## 5. Risks and migration

- **No persisted schema migration:** catalogue parameter fields and selection representation already exist. Old model-only records remain valid; refresh fills definitions. Old binaries may ignore new Devin selections.
- **Normal now explicitly means Code:** this preserves fresh-session behavior but deliberately downgrades resumed Smart/Bypass. Detail text must not promise approval before edits.
- **Provider Default is not a downgrade:** it leaves the current mode unchanged.
- **Cached definitions can become stale:** UI/MCP metadata may lag account policy; execution always checks live definitions and fails rather than substituting effort.
- **Discovery now performs approximately one RPC per model:** retain existing timeout and cancellation behavior; measure actual refresh latency before adding optimization.
- **No automatic recovery after rejected configuration:** preserve requested selections and show the error. Users select a supported value or refresh and retry.

### Remaining genuine evidence gaps

1. **Picker and headless producer call sites:** the selected Settings/composer implementations are still absent. The patch proves their *write guards* on main are generic; it does not prove all definition readers are. Verify their calls to `ACPModelParameterResolver` and headless `DevinAgentConfig` construction. Do not claim zero UI changes without this check.
2. **Exact runner helper/error-handler names:** the patch exposes the runner guard but omits its declaration name; controller slices omit RPC error construction.
3. **Debug-app build and CLI invocation syntax:** the verification skill body, conductor configuration, and `rpce-cli-debug` help are not supplied.
4. **Test baseline:** only the Sources diff is supplied.

These are source-resolution gaps, not unresolved behavioral decisions. An exhaustive function-level plan or copy-paste executable CE verification script cannot honestly be certified until they are inspected.

## 6. Live verification procedure

Use the **CE debug app**, never the release app. Do not publish or upload results.

### A. Raw ACP probe — executable commands

Run the supplied probe in a disposable workspace, using the authenticated enterprise account:

```sh
python3 prompt-exports/devin-acp-probe.py \
  --cwd /tmp/rpce-devin-rewrite-proof \
  --cfg model=swe-2-high thought_level=max

python3 prompt-exports/devin-acp-probe.py \
  --cwd /tmp/rpce-devin-rewrite-proof \
  --cfg model=gemini-3-8-flash-medium thought_level=high

python3 prompt-exports/devin-acp-probe.py \
  --cwd /tmp/rpce-devin-rewrite-proof \
  --set-mode smart bypass
```

Expected:

- SWE exposes `[medium, high, max]`; Gemini exposes `[low, medium, high]`.
- Effort changes do not rewrite model IDs.
- Smart succeeds on the enterprise account; Bypass refusal includes policy detail.

Use separate probe invocations when testing repeated assignments: its `out["cfg"]` dictionary overwrites duplicate keys. The probe also calls both `set_mode` and `set_config_option`; application proof must specifically show the latter.

### B. CE debug app + `rpce-cli-debug` acceptance script

The following is an **ordered CLI test specification**, not invented shell syntax:

1. Build and launch the packaged CE debug app using the repository’s `rpce-debug-build-validation` workflow.
2. Health-check `rpce-cli-debug`; assert it is connected to that debug app.
3. Select the disposable workspace and create a Devin Agent Mode session. Record the returned tab/session IDs.
4. Refresh Devin models. Assert the catalogue exposes model-specific `thought_level` definitions for SWE and Gemini.
5. Configure SWE plus `thought_level=max`, permission Normal; submit “Reply with READY without tools.” Poll the exact session to terminal completion.
6. Inspect captured ACP traffic: model precedes effort, mode is `accept-edits`, and prompt follows successful configuration.
7. Configure Gemini plus High and repeat. Assert there is no synthesized High-suffixed model ID.
8. While a controllable run is active, select Smart. Confirm a live mode mutation on the same controller/process, not a relaunch.
9. Select Full Approval on the enterprise account and submit another turn. Assert an actionable failure and **no subsequent `session/prompt`**.
10. Run the headless ACP case with Full Approval. Assert the same failure—not a generated allow-rule or automatic approval.
11. Separately exercise a harmless command with user-managed `permissions.allow: ["exec"]` in a permitted mode. Verify its observable output and absence of permission requests; do not describe this as Bypass.
12. Dispose only sessions/processes created by this verification.

For permission-card UI actions unavailable through `rpce-cli-debug`, use background Cua Driver delivery.

**Completion criterion:** recorded CE-app RPCs and resulting session state prove effort ordering, model-specific validation, live permission changes, and enterprise refusal. Unit tests or the raw probe alone do not prove the integration.
