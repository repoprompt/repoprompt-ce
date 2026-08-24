# Oracle groups architecture

Oracle groups run one request through an ordered roster of independent Oracle models. The feature preserves the existing single-Oracle path when the roster contains only the primary model.

[`oracle-groups-decisions.md`](oracle-groups-decisions.md) defines the cross-boundary contract. This document explains the current implementation and its ownership boundaries.

## Product contract

An Oracle roster contains one primary model and up to four additional models. The order is significant, and duplicate model identifiers are valid. Every lane receives the same user input.

A grouped result keeps every lane outcome separate and in roster order. The group status is derived from lane outcomes:

- `completed` means every lane completed and the result has no warnings.
- `partial_failure` means the primary lane completed but at least one additional lane failed, was cancelled, or produced a warning.
- `failed` means the primary lane did not complete.

Cancellation is a lane outcome. Provider errors are also lane outcomes. The coordinator does not combine, rank, vote on, or choose among lane answers.

The first version has these non-goals:

- No answer synthesis or arbitration.
- No hidden adviser or retry work.
- No automatic winner selection.
- No migration aliases for unshipped experimental pair contracts.
- No durable group record for a direct N=1 request.

## Domain ownership

`RepoPromptDomainRuntime` owns the group contract and runtime behavior.

`OracleGroupContracts.swift` defines:

- `OracleGroupID`, `OracleLaneID`, `OracleTurnID`, and member identity.
- `OracleRoster` and its one-to-five model limit.
- `OracleGroupDescriptor`, `OracleGroupDocument`, and ordered turns.
- `OracleLaneResult`, `OracleGroupResult`, statuses, warnings, and MCP encoding.
- `OracleFrozenContextPack` and canonical pack references.

`OracleGroupCoordinator.swift` accepts a group descriptor, a turn, one input, and one plan per lane. It runs lanes with a structured task group. Completion order does not affect result order. `OracleLaneProgressGate` assigns per-lane sequence numbers and rejects progress after a terminal event.

The coordinator handles rosters with two to five lanes. Callers bypass it for N=1.

## App execution

`OracleViewModel+Groups.swift` is the app adapter. `tool_chatSendWithConfiguredRoster` reads the effective model profile and chooses the route.

For N=1, the adapter calls the existing `tool_chatSend` implementation. It does not create a group document, acquire a group claim, or create lane projections.

For N>1, the adapter:

1. Resolves or creates the durable group.
2. Acquires the group claim.
3. Persists a prepared turn.
4. Restores or creates one `ChatSession` projection per lane.
5. Builds one `OracleLanePlan` per member.
6. Calls `OracleGroupCoordinator`.
7. Persists the terminal result with revision compare-and-swap.
8. Returns the primary compatibility fields and the ordered group result.

A named single-chat continuation is never promoted into a group. A group continuation uses the roster stored in the group document and rejects a configured roster mismatch.

`ContextBuilderAgentViewModel` uses the same app adapter for grouped follow-up requests. `ContextBuilderOracleGroupState` fences callbacks by generation, group, turn, lane, and sequence. The plan or review preview shows primary-lane progress, while the final reply retains every lane result.

## Direct headless execution

`DirectHeadlessOracleRosterResolver` reads `models.planning_model` and `models.additional_oracle_models` from direct settings. A start-only model override replaces the primary model. Continuations reject model overrides.

`DirectHeadlessOracleAdapter` resolves an immutable child launch plan before provider dispatch.

- N=1 uses the existing direct conversation backend and writes no group document.
- N>1 creates or continues a durable group and reserves one child launch carrier per lane.
- A continuation may use any member chat ID. The returned root chat ID is the primary member.
- A roster mismatch fails before provider dispatch.

Group ID, lane ID, and claim ID travel together through the credential scope, launch reservation, child environment, token redemption, and child handshake. Partial Oracle launch identity is invalid.

### Frozen Context Builder input

A direct grouped Context Builder request must use a persisted `context_pack_ref` in the canonical `oracle-pack:sha256:<digest>` form. Raw `instructions` remain available for N=1 only.

`MCPCommandRunner` accepts exactly one of `instructions` or `context_pack_ref`. The direct adapter verifies the pack schema, mode, content digest, and stored artifact before launching lanes. Invalid or missing packs fail with `context_pack_required` or the relevant pack validation error.

## Durability and claims

`DomainOracleConversationStore` stores one document per group. `OracleGroupDocument.currentSchemaVersion` is `2`. The document contains immutable group topology, the ordered roster, member chat IDs, a revision, and ordered turns.

A turn is prepared before provider work starts. A terminal turn contains one structural result for every lane. The store uses:

- Filesystem mutation locks across processes.
- Revision compare-and-swap for save, rename, and delete.
- A transaction journal for crash recovery.
- A member-to-group index for continuation lookup.
- SHA-256 verification for frozen artifacts.

`OracleGroupClaimManager` serializes continuation, rename, delete, retention, and recovery work. A claim binds the group owner, invocation, run, runtime, and claim ID. Claims release explicitly and on deinitialization.

If terminal persistence fails, the adapters retry the same canonical outcome. They do not invent a replacement result. Cancellation drains lane tasks and persists cancelled lane outcomes before the current wrapper returns cancellation where that contract applies.

## Settings and schema authority

The app and direct headless runtime use separate settings stores with the same semantic descriptors.

- `models.planning_model` stores the primary Oracle model.
- `models.additional_oracle_models` stores an ordered string array with at most four entries.

`OracleRosterSettingsDescriptor` is the shared descriptor authority. It preserves duplicates, trims identifiers at the settings boundary, and enforces the count and identifier length limits.

`GlobalSettingsStore` owns app settings. `DomainDirectSettingsStore` owns direct settings. `AppSettingsMCPService` and `DirectHeadlessGlobalBackend` adapt MCP values to their owning store. Both adapters use `DomainSettingValue` for string-array conversion and validation.

`GlobalSettingsFileStore` rejects the unshipped experimental Oracle schema versions. Unknown or experimental documents must not become migration authority or silently overwrite user settings.

`MCPDomainCanonicalToolDefinitions.swift` is the canonical MCP schema source. `docs/spec/mcp-domain-canonical-tool-definitions.generated.json` is a generated review copy. Regenerate the JSON with the command recorded in its provenance block. Do not edit it by hand.

## Presentation and export

`AgentOraclePill` displays one `Oracles · N` pill for a grouped result. Lane details remain available in roster order.

Context Builder tool cards show the primary preview and ordered lane summaries. The multi-Oracle follow-up hint states that lane results are independent. It does not tell the caller to combine, rank, vote on, or choose a winning lane.

`OracleLaneMarkdownFormatter` and `AgentOracleExport` write one section per lane in roster order. `MCPOracleToolService` decodes the canonical group result for export. The export does not modify lane text.

## Validation

Use the coordinated developer daemon. Do not launch the app for source-only validation.

Run the smallest filter that owns each changed boundary:

```sh
make dev-test FILTER=OracleGroup
make dev-test FILTER=OracleLane
make dev-test FILTER=DirectHeadlessOracleGroup
make dev-test FILTER=DirectHeadlessRuntimeConfigurationTests
make dev-test FILTER=ContextBuilderOracle
make dev-test FILTER=OracleGroupBoundaryTests
make dev-test FILTER=AgentOraclePill
make dev-test FILTER=SettingsJSONOnly
make dev-test FILTER=ToolCatalogSnapshotTests
```

The focused tests must prove these invariants:

- N=1 uses the existing app and direct paths.
- N>1 preserves roster order despite completion order.
- The primary lane determines `failed` versus `partial_failure`.
- Cancellation drains lanes and produces structural outcomes.
- Prepared and terminal group documents obey revision checks.
- Claims serialize destructive lifecycle work across processes.
- Direct launch authorization binds group, lane, and claim identity.
- Grouped direct Context Builder requires one verified frozen pack.
- Settings preserve ordered duplicates and reject more than four additions.
- UI and exports retain separate ordered lane results.
- The generated MCP review copy matches the canonical Swift definitions.

Run `make guardrails` and `git diff --check` before handoff.
