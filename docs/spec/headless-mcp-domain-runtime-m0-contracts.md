# Headless MCP domain runtime — M0 contract freeze

Date: 2026-07-26

Base: `main` at `664252ebc85e`
Machine-readable authority: `Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json`

## Scope

This is Milestone 0 of the eight-PR headless runtime plan. It records current authorities, closes bounded evidence questions, and establishes drift guards. It deliberately does **not** add a runtime target, move providers, define a production `DomainRunLaunchToken`, change persistence, or launch a child process.

The normalized catalog fixture contains all 27 public tools. Fifteen tools expose 86 schema-discriminated actions; the other 12 tools are actionless and instead freeze their top-level required properties. M0 does **not** claim that every action was invoked or that a universal success/error envelope exists.

Missing-discriminator behavior is frozen per action-bearing tool from implementation source:

- defaults are preserved for `manage_selection` (`get`), `workspace_context` (`snapshot`), `prompt` (`get`), `git` (`status`), `agent_run` (`wait`), and `agent_manage` (`list_sessions`);
- `history` returns the typed `HistoryToolReply.error(HistoryErrorReply)` value;
- the remaining action-bearing tools have source branches that declare their typed invalid-parameter error for a missing discriminator.

Each row carries a source path, behavior marker, and typed-error marker checked by XCTest; default markers must contain the frozen default value. M0 does not infer mutation ordering beyond what these source branches state. Exact per-action result and JSON-RPC envelope parity is explicitly unmeasured in M0 and must be covered by executable migration fixtures when a tool family moves.

`ToolCatalogSnapshotTests` remains the detailed description/schema-hash golden for the 24 window tools. The M0 manifest adds the three global tools, action coverage, policy normalization, and dependency accounting rather than creating a second schema-hash authority.

## Canonical inventories

### Tool policy and parity ledger

Capability names below are from the domain-runtime `MCPDomainToolCatalog`; every public tool has one explicit capability classification. Owner is the current app-side authority. “Headless” is the frozen expectation for the later family migration, not an M0 implementation claim.

| Tool | Capability | Admission / execution | Current owner | Schema/action fixture | Denied/cancel/lifecycle contract | App / headless expectation |
|---|---|---|---|---|---|---|
| `app_settings` | app_settings | exclusive / bounded | `AppSettingsMCPService` | manifest + service schema | invalid params; connection cancellation | app authoritative / exact later parity |
| `bind_context` | workspace_mutate | exclusive / workspace lifecycle | `WindowRoutingService` | manifest + service schema | invalid context; bind lifecycle | app authoritative / exact later parity |
| `manage_workspaces` | workspace_mutate | exclusive / workspace lifecycle | `WindowRoutingService` | manifest + service schema | approval/invalid target; workspace lifecycle | app authoritative / exact later parity |
| `manage_selection` | selection_mutate | exclusive / bounded | `MCPSelectionToolProvider` | manifest + catalog golden | artifact fence/invalid params; request cancellation | app authoritative / exact later parity |
| `file_actions` | file_management | exclusive / bounded | `MCPFileToolProvider` | manifest + catalog golden | mutation/approval errors; request cancellation | app authoritative / exact later parity |
| `get_code_structure` | structural_explore | small_read / bounded | `MCPDomainReadToolProvider` → `MCPFileToolProvider` backend | manifest + catalog golden | lookup/invalid params; bounded cleanup | shared app/headless provider; app physical backend |
| `get_file_tree` | structural_explore | small_read / bounded | `MCPDomainReadToolProvider` → `MCPFileToolProvider` backend | manifest + catalog golden | lookup/invalid params; bounded cleanup | shared app/headless provider; app physical backend |
| `read_file` | file_read | small_read / bounded | `MCPDomainReadToolProvider` → `MCPFileToolProvider` backend | manifest + catalog golden | authorization/lookup; bounded cleanup | shared app/headless provider; revisioned app side effect |
| `file_search` | file_search | file_search / long synchronous | `MCPDomainReadToolProvider` → `MCPFileToolProvider` backend | manifest + catalog golden | lookup/overload; cooperative cancellation | shared app/headless provider; revisioned app side effect |
| `workspace_context` | workspace_read | exclusive / bounded | `MCPDomainReadToolProvider` → `MCPPromptContextToolProvider` backend | manifest + catalog golden | export/selector errors; request cancellation | shared app/headless provider; app physical backend |
| `prompt` | prompt_mutate | exclusive / bounded | `MCPDomainReadToolProvider` → `MCPPromptContextToolProvider` compatibility backend | manifest + catalog golden | export/selector errors; request cancellation | read ops migrated; mutation ops remain app passthrough |
| `apply_edits` | file_content_edit | exclusive / interactive | `MCPApplyEditsToolProvider` | manifest + catalog golden | approval/rebase/invalid mode; interactive lifecycle | app authoritative / exact later parity |
| `oracle_utils` | conversation_helper | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | chat/model errors; cooperative cancellation | app authoritative / exact later parity |
| `ask_oracle` | agent_conversation_send | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `oracle_send` | conversation_send | control / long synchronous | `MCPOracleToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `oracle_chat_log` | conversation_log | small_read / long synchronous | `MCPDomainReadToolProvider` → `MCPOracleToolProvider` backend | manifest + catalog golden | chat/invalid params; cooperative cancellation | shared app/headless provider; app physical backend |
| `git` | git_read | git_read / workspace lifecycle | `MCPDomainReadToolProvider` → `MCPGitToolProvider` backend | manifest + catalog golden | repo/operation errors; process cleanup | shared app/headless provider; revisioned artifact advertisement |
| `manage_worktree` | worktree_manage | exclusive / workspace lifecycle | `MCPWorktreeToolProvider` | manifest + catalog golden | preview/approval/conflict; merge lifecycle | app authoritative / exact later parity |
| `context_builder` | discovery | control / long synchronous | `MCPContextBuilderToolProvider` | manifest + catalog golden | policy/provider errors; cooperative cancellation | app authoritative / exact later parity |
| `ask_user` | user_interaction | control / interactive | `MCPAskUserToolProvider` | manifest + catalog golden | denied/timeout/cancel; interactive lifecycle | app authoritative / exact later parity |
| `agent_explore` | agent_explore_control | control / lifecycle managed | `MCPAgentControlToolProvider` | manifest + catalog golden | policy/provider errors; session lifecycle | app authoritative / exact later parity |
| `agent_run` | agent_external_control | control / lifecycle managed | `MCPAgentControlToolProvider` | manifest + catalog golden | policy/provider errors; session lifecycle | app authoritative / exact later parity |
| `agent_manage` | agent_external_control | control / bounded | `MCPAgentControlToolProvider` | manifest + catalog golden | ownership/invalid session; bounded cleanup | app authoritative / exact later parity |
| `share_thoughts` | agent_reasoning_control | control / bounded | `MCPAgentSessionControlToolProvider` | manifest + catalog golden | policy/identity errors; request cancellation | app authoritative / exact later parity |
| `set_status` | status_publication (`agent_session_control` serialized compatibility name) | control / bounded | `MCPAgentSessionControlToolProvider` | manifest + catalog golden + `list_agents` capability fixture | policy/identity errors; request cancellation | app authoritative / exact later parity |
| `wait_for_next_user_instruction` | agent_reasoning_control | control / interactive | `MCPAgentSessionControlToolProvider` | manifest + catalog golden | terminal/cancel; interactive lifecycle | app authoritative / exact later parity |
| `history` | history_read | control / bounded | `MCPDomainReadToolProvider` → `MCPHistoryToolProvider` / `HistoryMCPToolService` backend | manifest + catalog golden | scan budget/invalid params; request cancellation | shared app/headless provider; app scanner backend |

The manifest freezes the complete tool-to-capability map, including deliberate empty mappings, and explicit per-client annotation profiles. It also freezes a resolved **production-policy projection**—after restricted-tool filtering, policy-gated grants, and role advertisement—for direct, discovery, generic explore, generic engineer, orchestrator engineer, Claude, Codex, OpenCode, and Cursor profiles. XCTest derives every projection from `MCPToolCapabilities`, `DiscoverMCPToolPolicy`, `AgentModeMCPToolPolicy`, `MCPPolicyGatedTools`, and `AgentModeMCPToolAdvertisementPolicy`; the JSON is not an independent prose assertion. This is deliberately not described as actual runtime `tools/list` registry evidence because M0 does not exercise service registration, user-disabled tools, duplicate suppression, readiness, or connection routing. Admission and execution partitions remain exhaustive and fail closed.

### Dependency and MainActor boundary

`MCPWindowToolDependencies` is the constructor-time seam. The manifest freezes all 84 top-level stored `let`/`var` fields. The guard finds the struct by declaration, balances its braces, and inspects only depth-one stored properties, so moving the first field, adding a `var`, using an underscore/backticked identifier, or appending another top-level declaration cannot silently weaken the inventory. This is an inventory, not approval to carry the entire app graph into the future runtime.

The migration denominator is every type-level `@MainActor` declaration under `Infrastructure/MCP`: 42 declaration sites, including nested MCPServerViewModel support types, `MCPServerViewModel` itself, every window provider, `MCPWindowToolRuntime`, `WindowRoutingService`, `ToolAvailabilityStore`, Oracle/Agent services, and the worktree merge extension. `DomainWorkspacePresentationBridge` remains inside that denominator and is classified at the actor boundary as presentation-only: it projects immutable snapshots and may submit the revisioned first-run default-bootstrap command, but it owns no mutable domain state and is not an executable per-tool hop. The test enumerates this set programmatically, compares exact path/kind/symbol triples, enforces the classification fields, and scans every Swift file under `Infrastructure/MCP` except the bridge declaration file for bridge references. Eight external MainActor collaborators on the window-tool hot path are separately frozen (`WindowState`, `WindowStatesManager`, `WorkspaceManagerViewModel`, `PromptViewModel`, `ContextBuilderAgentViewModel`, `GlobalSettingsStore`, `WindowSettingsManager`, and `WorkspaceSelectionCoordinator`).

The manifest records a source-guarded per-tool actor prefix. Unmigrated window tools include `MCPServerViewModel → MCPWindowToolRuntime → provider`; M3 read/discovery tools instead include `MCPServerViewModel → MCPWindowToolRuntime → MCPDomainReadToolProvider → app backend`, with `DomainReadSideEffectCoordinator` present for revisioned selection/artifact effects. Its M3 addendum freezes zero MainActor authority captures for workspace-independent history/log reads, one routing capture for scoped reads, an invocation-scoped app execution snapshot with terminal release, required-handle fail-closed behavior, registered domain handles for direct/test fallback, domain-actor refresh rather than MainActor routing recapture, only exact post-drain selection/revision refresh for selection consumers, and no presentation-descriptor mutation from read resolution. It also freezes workspace-independent, optional, and required tool families. The test requires each migrated schema in the shared definition source and rejects duplicate registration markers in the app backends. Global tools record `GlobalSettingsStore` or `WindowRoutingService`. Notable current ownership examples are `git → MCPDomainReadToolProvider → MCPGitToolProvider`, `manage_worktree → MCPWorktreeToolProvider`, and `history → MCPDomainReadToolProvider → MCPHistoryToolProvider`. Delegated Oracle/Agent/context-builder service hops are kept separately as `reviewed_non_executable_inventory`: their actor declarations are guarded, but M0 does not claim the complete call graph is mechanically derived. This is the denominator later PRs must reduce or deliberately update, not a claim that M0 moved isolation.

The joined EditFlowPerf request timeline separately freezes `MainActorScheduled → MainActorEntered → MainActorExited`, provider execution, persistence, and response delivery as observable boundaries. `MCPBootstrapLease`, `MCPReplayState`, and `BootstrapSocketMCPTransport` remain non-MainActor actors.

### Approval

`WorkspaceApprovalManager` currently owns `create_workspace`, `delete_workspace`, `add_folder`, and `remove_folder`. Terminal results are approved (including always-allow), denied, and timeout. Cancellation settles as denied exactly once, guarded by `WorkspaceApprovalCancellationTests`.

## Evidence dispositions

### Pinned SDK stdio

`Package.swift` pins `repoprompt/swift-sdk` at `85dec2fc7a27252bc33dc7728be6af6b3bd398c0`. Inspection of that revision's `StdioTransport` found:

1. clean EOF finishes the message stream normally;
2. a read error is logged and then also finishes the stream normally;
3. incomplete trailing frame data is discarded at EOF;
4. therefore the server observes `connectionClosed` for all three and receives no terminal provenance.

This gate is closed by a negative assessment: keep the pin, but M6B must use a bounded RepoPromptMCP-owned stdio adapter if it needs the app-owned clean-EOF/truncation/read-error distinction. No SDK fork is required by M0. Existing socket-reader and bridge-ledger tests are the fallback behavior reference.

The same SDK revision exposes `elicitation/create` with accept, decline, and cancel actions. That is recorded as **SDK-supported, client-negotiated**, never assumed.

### Packaged CLI credentials — carried forward before M5

`Scripts/package_app.sh` places `repoprompt-mcp` in `RepoPrompt.app/Contents/MacOS` and signs it before the outer app. No Keychain or security command was run for M0. The preserved `item0_measurement_record.json` is an unresolved procedure record—not empirical evidence—and explicitly says authorization-UI behavior is unmeasured and `startup_scan_approved` is false.

No empirical credential-access result exists: the measurement is classified `not_run_approval_required`, not as an observed Keychain rejection. The design gate is fail-closed, while the empirical gate remains explicitly unresolved:

- direct packaged-child Keychain access is **not proven and prohibited as an architectural assumption**;
- the prescribed fallback is parent-owned secure storage plus a minimum-scope, in-memory credential handoff;
- debug alternate-in-memory storage is explicitly nonpersistent;
- the 23-account secure-storage catalog remains parent-owned and secrets/account identifiers are not copied into this evidence.

### Persistence and save semantics

The manifest classifies durable files, in-memory window overlays, runtime-policy UserDefaults, presentation defaults, and secure storage. It also exhaustively classifies every `WorkspaceSaveSource`:

- automatic poll: `pollTimer`, `pollAndSaveState`, `pollAndSaveStateAsync`;
- lifecycle: `workspaceSwitchSaveState`, `mcpTabContextEndOfRun`;
- debounced automatic: `workspaceFilesDebouncedSelectionSave`;
- explicit save API: `saveWorkspaceAsync`;
- mutation write-through: workspace/root/preset/prompt/normalization mutations listed in the fixture;
- legacy unattributed: `directUnknown`;
- DEBUG-only: `debugWorkspaceSelectionFixtureApply`.

`GlobalSettingsStore` is file-backed at `~/Library/Application Support/RepoPrompt CE/Settings/globalSettings.json`. `WindowSettingsManager` is an in-memory overlay that writes only on explicit commit or opt-in auto-persist. Approval, tool availability, apply-edits policy, and host admission UserDefaults are runtime-policy migration candidates, not presentation preferences. Working-journal rows freeze the later M2/M4 migration accounting without implementing it.

### EditFlowPerf deterministic contract-evidence index — carried forward before M2 no-regression decisions

`headless-mcp-domain-runtime-m0-editflowperf-baseline.json` records a checkout-size snapshot (2,341 tracked files; 1,654 source/test/script files; 42,426,964 bytes); those counts are not a representative-workspace or latency sample. The artifact is an informational index over deterministic executable contracts, not proof that those separate tests passed in the current run. Its M0 evidence floors require substantive queue aging/cancellation, correlated lifecycle, workload-matrix, durability, response-delivery, checkout-size, and historical work-count observations. Every executable citation declares its source file, and the M0 contract test verifies that the declared file contains the cited suite and test method. The artifact separately preserves the historical observed work-count blob `f2c2693e7956c561dced51fc51fa165676a7efbc` and validates its object-ID shape plus positive scenario counts.

No live command was attempted because the task prohibited visible app lifecycle actions. Therefore the live MCP round trip is `not_observed_task_prohibited`, not an observed failure or blocked execution. Before M2 makes no-regression decisions, use a separately authorized, already-running CE debug app and `make dev-smoke`; never infer live latency from XCTest timing.

### Private child endpoint and launch token

Current `MCPBootstrapLeaseSpec` has 14 frozen fields in the manifest. The future private endpoint contract is:

- per-runtime random Unix-domain socket, never the well-known app socket;
- private directory mode `0700`, socket mode `0600`;
- identity fenced by runtime ID, generation, and owner PID;
- listener descriptors never inherited by children;
- endpoint passed explicitly as `REPOPROMPT_MCP_PRIVATE_ENDPOINT` through a host-created launch-scoped environment boundary;
- one expected child/descendant admission, lasting only through terminal settlement;
- identity-fenced idempotent cleanup; admission failure revokes endpoint and token fail closed.

The future `DomainRunLaunchToken` child material is one opaque random capability; it does not expose or select policy. A host-only record binds its digest to runtime generation, child/descendant, context, principal, provider, purpose, and tool policy. The capability is single-use, short-lived, memory-only, never logged/persisted, and revoked on idempotent terminal cleanup. Its explicit child carrier is `REPOPROMPT_MCP_LAUNCH_TOKEN`. Codex, Claude, OpenCode, and Cursor launch paths already have environment/config carriers; M0 adds no launch wiring.

At M0, the guard confirmed that neither a production `DomainRunLaunchToken` type nor a headless runtime target existed. After M2, the token contract status records host-side issue, redeem, and revoke as implemented while explicitly retaining deferred private endpoint and provider-carrier wiring. The guard requires anchored Swift declarations for `DomainRunLaunchToken`, `DomainWorkspaceStore`, and `DomainContextStore` rather than accepting incidental text matches.

## M0 gate result

M0 is a **contract freeze complete with two carried-forward evidence gates**, not a declaration that all evidence was observed:

1. packaged-child credential access must be measured before M5 credential transport; until then direct access is excluded and the parent-owned, minimum-scope in-memory handoff is mandatory;
2. live EditFlowPerf latency must be measured before M2 no-regression decisions using a separately authorized, already-running CE debug app.

The SDK stdio assessment, catalog/actions/defaults/typed errors, capability and resolved policy projections, dependency/MainActor inventories, approval semantics, persistence/save classification, and private endpoint/token contract are guarded now. Later milestones must update the parity ledger, per-tool actor denominator, and migration rows deliberately as families move.

### Eight-PR boundary preserved

The first PR remains M0 only and added no runtime target, production token type, child listener, credential handoff, persistence journal, provider migration, command-surface change, or UI change.

Subsequent implementation status is recorded without changing this frozen baseline: M1 introduced the runtime/catalog foundation in PR #640; the stacked M2 workspace/context authority contract and parity ledger live in [`headless-mcp-domain-runtime-m2-context-authority.md`](headless-mcp-domain-runtime-m2-context-authority.md).
