# Headless MCP domain runtime M6 — host extraction evidence

Date: 2026-07-28

Branch: `feature/headless-runtime-m6-direct-backend`
Base: finalized local `feature/headless-runtime-m5-ai-agent`

## Gate 6A boundary

Gate 6A introduces `MCPDomainHost` in `RepoPromptDomainRuntime` as the protocol-neutral owner of:

- immutable canonical catalog snapshots;
- exact application/window binding resolution;
- registry-generation and connection-generation fencing immediately before invocation;
- authoritative `DomainToolInvocationSecurityContext` installation;
- active invocation ownership, per-connection cancellation, and bounded runtime drain.

The app remains a transport and presentation shell. `MCPDomainHost` owns canonical policy filtering, connection registrations and replacement generations, admission lanes, resource leases, progress state, watchdog execution, settlement, delivery accounting, terminal fencing, and bounded drain. `ServerNetworkManager` adapts app/window routing, tool-card publication, observer callbacks, result formatting, and physical transport delivery to those runtime capabilities. It obtains catalog snapshots and exact resolutions from `MCPDomainHost`; connection removal terminal-fences and cancels the exact host generation.

`MCPService` receives an injected host-bootstrap operation. The production default performs the existing one-time Codex tool-timeout migration before listener startup; tests and later standalone composition can supply a different bootstrap without duplicating lifecycle ownership.

## Compatibility invariants

Gate 6A does not change:

- the default CLI backend or bootstrap Unix socket;
- `MCPInitializeReplayState`, outstanding-request replay, or the JSON-RPC bridge ledger;
- listener/replacement, approval, retry, terminal, kill, or response-delivery contracts;
- tool schemas, policy visibility, wire envelopes, or app/window routing behavior;
- physical app provider composition.

The host does not infer windows, format MCP results, dispatch a second JSON-RPC loop, or access AppKit/MainActor state.

## Bounded drain contract

Host drain cancels all owned invocations and polls actor-owned settlement state only until the configured deadline. It deliberately does not use a structured task-group race, because exiting such a group waits for an uncooperative child and would make the deadline unbounded. A provider that ignores cancellation remains accounted as detached until its original invocation settles; new invocations fail closed once drain begins.

## Focused evidence

- `make dev-test FILTER=MCPDomainHostTests`
  - conductor ticket `8287f6dc-16d9-46bd-8ece-8e784772ee86`
  - 3 tests passed
- `make dev-swift-build PRODUCT=RepoPrompt`
  - conductor ticket `b222dfda-14b4-4b6b-b17f-2f68dd0450df`
  - passed
- `make dev-test FILTER=ToolCatalogSnapshotTests`
  - conductor ticket `788a78f0-3da2-4380-99bc-04e07446d66c`
  - 21 tests passed
- `make dev-test FILTER=MCPProtectedMutationInvocationIntegrationTests`
  - conductor ticket `6ad2e167-505a-47c7-a7f6-3baa1ef0cbe5`
  - 2 tests passed

- `make dev-test FILTER=PersistentMCPResponseDeliveryTests`
  - conductor ticket `85dce091-850d-4826-8c41-3fbd4ae8ea3c`
  - 24 tests passed, including outstanding replay and bounded delivery drain
- `make dev-test FILTER=MCPProxyTerminalRecordTests`
  - conductor ticket `60199ea8-0d14-4f30-8ddf-57859e629a8b`
  - 7 tests passed
- `make dev-test FILTER=DomainInteractionAppSeamTests`
  - conductor ticket `d7ceb0b1-152d-4f28-bec4-28b01d38e9ac`
  - 6 tests passed
- `make dev-test-list`
  - conductor ticket `66b89d8c-c9a3-48f5-bbfb-37b1929a3947`
  - passed
- `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv`
  - passed with 3,681 exact methods
- `make dev-lint`
  - conductor ticket `eed9515d-276d-43f9-bee3-4afe0f8bae36`
  - passed
- `make dev-swift-build PRODUCT=repoprompt-mcp`
  - conductor ticket `ceefa81f-a16f-4946-96f0-67584a4324d9`
  - passed
- `make dev-provider-test`
  - conductor ticket `d06ecb69-2f0f-4b7c-8f9a-b1ba76af0624`
  - passed
- `make guardrails`
  - source layout, contributor allowlist, legal inventory, and pinned Codex guardrails reported success
- `make dev-codex-schema-check`
  - conductor ticket `3abc1d06-8c1e-4e37-aa94-be031daf4e51`
  - environment blocked: installed Codex CLI `0.144.1` is below the repository floor `0.145.0`; no schema comparison ran

## Gate 6A corrective review closure

The review follow-up closes the host lifecycle blocker and shipping-lifecycle highs without changing proxy wire behavior:

- invocation validation may suspend, but the final lifecycle check and active-invocation insertion are now one actor-isolated, suspension-free admission step; `beginDrain` therefore cannot miss a late untracked invocation;
- drain observes caller cancellation explicitly, returns a distinct `callerCancelled` result, and never catches cancellation only to re-enter a hot polling loop;
- the host-created provider task is an explicitly owned operation: it is inserted before the actor yields, indexed by invocation and connection, cancelled by caller/connection/drain, and retained in detached accounting until terminal settlement;
- the shipping `AppDelegate` termination barrier now awaits `MCPDomainRuntime.shutdown()` after agent-session and MCP-server teardown;
- domain-host queue and execution timings flow through `DomainRuntimeMetricsSink` into the `EditFlow.MCPToolCall.DomainHost.QueueWait` and `EditFlow.MCPToolCall.DomainHost.Execution` stages with tool, outcome, and microsecond dimensions.

Corrective focused evidence:

- `make dev-test FILTER=MCPDomainHostTests`
  - conductor ticket `8affc9cf-5c22-48cc-b29d-c23378389ffb`
  - 5 tests passed, including the suspended-admission/drain race and cancelled-drain bounded-return regression
- `make dev-test FILTER=ToolCatalogSnapshotTests`
  - conductor ticket `381db41b-4029-4060-affd-d826ad253aba`
  - 22 tests passed, including the shipping termination shutdown seam
- `make dev-test FILTER=ServerControllerAdmissionTests`
  - conductor ticket `9cebdb0b-675a-464e-885b-b006476902e4`
  - 3 tests passed
- `make dev-test FILTER=MCPAgentPolicyAdmissionRaceTests`
  - conductor ticket `c536780d-7e92-4b11-8474-089ae0cc69d5`
  - 39 tests passed
- `make dev-test FILTER=MCPToolExecutionWatchdogIntegrationTests`
  - conductor ticket `9cfce974-0fa2-428e-a965-ae2e0ddca2c3`
  - 22 tests passed
- `make dev-test FILTER=BootstrapSocketOwnershipTests`
  - conductor ticket `7ed688fb-acaf-4c1a-bacf-e022d1ee1190`
  - 7 tests passed
- `make dev-test FILTER=MCPSocketDescriptorHardeningTests`
  - conductor ticket `2c35144b-ff3e-4948-86ff-5996db32a06b`
  - 30 tests passed, including listener replacement and kill/stop lifecycle fencing
- `make dev-test FILTER=UnixSocketMCPTerminalCleanupTests`
  - conductor ticket `48fa9b3f-8eb7-4df9-8f38-991d0bfa8afb`
  - 13 tests passed
- `make dev-test FILTER=PersistentMCPResponseDeliveryTests`
  - conductor ticket `eb362895-f49b-4916-b048-c620c4779a20`
  - 24 tests passed
- `make dev-test-list`
  - conductor ticket `7d68ad28-828e-4bcd-840f-cc51bf6c4384`
  - passed
- `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv`
  - passed with 3,684 exact methods; root/provider list tickets `75a31b9a-c4e6-4eba-b8d1-1441d34db65d` and `7bf553be-656b-4e0a-a4ff-36bc5fea0db3`
- `make dev-swift-build PRODUCT=RepoPrompt`
  - conductor ticket `c23f9540-6487-4034-83c8-f05f3c76777c`
  - passed
- `make dev-swift-build PRODUCT=repoprompt-mcp`
  - conductor ticket `3c82ba54-e85a-4a64-938c-3c80bdfb37b9`
  - passed
- `make dev-provider-test`
  - conductor ticket `3b8f01dc-4cf9-464f-84f6-49fdec227a84`
  - passed
- `make dev-lint`
  - conductor ticket `0b7a4f7d-a035-4762-9eab-42e417fe7ca1`
  - passed
- `make guardrails`
  - passed
- `make dev-codex-schema-check`
  - conductor ticket `3c6a91b0-05b4-4882-ba2f-7c91006d8c37`
  - environment blocked before comparison: installed Codex CLI `0.144.1` is below the required `0.145.0` floor

## Gate 6A protocol-neutral policy and resource admission ownership

The A3 extraction moves canonical `tools/list` filtering, two-stage `tools/call` policy decisions, admission classification, admission-limit constants, and keyed application/window resource admission into `RepoPromptDomainRuntime`:

- `MCPDomainHost.advertisedCatalog` owns disabled, restricted, explicit-grant, and role visibility ordering over one registry snapshot;
- `evaluateEarlyCallPolicy` and `evaluatePreAdmissionCallPolicy` preserve the existing early grant-denial versus later restricted/role/admission-class ordering, while `ServerNetworkManager` maps typed outcomes to the existing byte-identical user errors;
- `MCPDomainToolResourceAdmissionController` is the physical cancellation-safe FIFO lease authority, including repository resource identity for standalone composition;
- the host owns the mutation and small-read controllers; the app keeps only routing-to-resource selection, timing evidence, and the intentional explicit release boundary before formatter/observer tails;
- the app compatibility controller name is now only a typealias used by the existing focused tests;
- `MCPRequestProgressState`, its delivery result, and the transport-only actor capability live in the runtime; the host owns connection-generation-bound request handles, finish invalidation, connection-cancel invalidation, and drain invalidation, while the app adapter keeps the legacy RepoPrompt CLI control fallback and physical `MCP.Server.notify` write.

Evidence:

- `make dev-test FILTER=MCPDomainHostTests` — ticket `c38bf65b-d6f7-40b1-9e4d-2e3be79533c7`, 7 passed, including host-owned request progress finish/connection-cancel fencing
- `make dev-test FILTER=MCPControlMessagesTests` — ticket `328fb87b-5948-400e-90f7-4699794bb8ed`, passed with standard-progress coalescing/finalization and legacy control fallback preserved
- `make dev-test FILTER=MCPToolAdmissionPolicyTests` — ticket `5a5875b5-de96-4e75-a946-ab201f104fff`, passed
- `make dev-test FILTER=ToolCatalogSnapshotTests` — ticket `1aadf74a-4648-4948-8554-929d60afbd9e`, 22 passed
- `make dev-test FILTER=MCPAgentPolicyAdmissionRaceTests` — ticket `95bf4a7c-349c-4fd1-8703-45cb872e39f1`, 39 passed
- `make dev-test FILTER=MCPToolExecutionWatchdogIntegrationTests` — ticket `f675276f-eff8-4b95-9bc9-2c3d5b930d52`, 22 passed, including resource release timing
- `make dev-test FILTER=PersistentMCPResponseDeliveryTests` — ticket `04f7c112-e618-452e-9aa3-e2292451716b`, 24 passed
- `make dev-test FILTER=MCPProxyTerminalRecordTests` — ticket `1be5980a-9584-40ba-9992-edc36db01488`, 7 passed
- `make dev-swift-build PRODUCT=RepoPrompt` — ticket `6cbeb356-1958-47cd-aabe-3709609e7220`, passed
- `make dev-swift-build PRODUCT=repoprompt-mcp` — ticket `ac61444b-6d9a-4fdc-b7ea-d22970164828`, passed
- `make dev-lint` — ticket `03d1a701-6ee5-4850-9284-abec4ad906df`, passed
- ledger verification — 3,686 exact methods; root/provider list tickets `a843351d-3d8a-435b-aaf6-8067fd3a1b89` and `b413d7fe-aaf6-48f7-96f2-d42ac8eb4055`

### Review follow-up: final admission and drain closure

The branch-range Gate 6A review identified three additional reentrancy gaps, all closed before beginning Gate 6B:

- connection removal now terminal-fences the exact connection generation in the host before any cleanup suspension; final invocation admission and request-progress creation reject that generation;
- duplicate invocation IDs are rechecked in the same suspension-free final admission block as lifecycle and connection-terminal state, preventing task-ownership overwrite;
- host drain closes both host-owned resource controllers, fails queued acquisitions, waits for outstanding leases, and publishes admission counts in its snapshot.

Evidence:

- `make dev-test FILTER=MCPDomainHostTests` — ticket `ceb7af9d-d521-4b94-ae22-db670ff1e7e2`, 10 passed
- `make dev-test FILTER=MCPToolAdmissionPolicyTests` — ticket `91cc8793-e825-4671-b218-09d6a5d1c784`, 11 passed
- `make dev-test FILTER=PersistentMCPResponseDeliveryTests` — ticket `aa54db84-91e7-4fbb-9380-faa881b7e860`, 24 passed
- `make dev-test FILTER=MCPProxyTerminalRecordTests` — ticket `e5533c26-3f81-41cd-b2c9-3f40875642ed`, 7 passed
- `make dev-test FILTER=ToolCatalogSnapshotTests` — ticket `4b330dd1-7f33-4da7-9a80-8ad4c5e228c1`, 22 passed
- `make dev-swift-build PRODUCT=RepoPrompt` — ticket `4182be28-547b-42b5-b782-85b56c9c4f78`, passed
- `make dev-swift-build PRODUCT=repoprompt-mcp` — ticket `30fa3e0d-9fcd-4d1d-b30e-d707cc96358f`, passed
- `make dev-lint` — ticket `49363f7e-4039-4ddf-aa31-72555dc5ba2f`, passed
- `make guardrails` — passed
- `make dev-provider-test` — ticket `fcb0084e-a489-442a-8e0b-9573227c0d22`, passed
- ledger verification — 3,689 exact methods; root/provider list tickets `d5d91c33-0234-46fc-b1b2-39ecd5222b83` and `a761b7c1-ce83-48df-973d-7d6a7b2c9c85`

## Gate 6B — standalone preview

Gate 6B exposes only the explicit `--backend headless` preview. The parser still defaults to
`app`, rejects headless interactive/exec combinations, and leaves automatic selection to M7.

The production direct composition:

- constructs `MCPDomainRuntime` in standalone mode with an isolated profile and
  `DomainPersistenceCoordinator` storage;
- registers a real `.standalone` scope rather than a synthetic window;
- installs all 27 Swift-owned canonical definitions and applies the long-running and
  protected-mutation decorators;
- reuses `MCPDomainReadToolProvider` for the nine migrated reads and the extracted production
  apply-edits/diff substrate for operation-ID, revision, retry, and path-fence semantics;
- adapts physical capability families through Foundation/Sendable protocols without importing
  AppKit, SwiftUI, or `MCPServerViewModel`;
- installs one MCP SDK server over the terminal-aware `MCPStdioServerTransport`, with one-hop
  delivery accounting and explicit EOF/read/poll/PPID/broken-pipe/cancellation provenance;
- carries nested Agent/Context Builder calls through an owner-only, inode-fenced Unix endpoint
  and a single-use runtime-generation/peer-identity launch token;
- cancels and awaits provider, endpoint, and reader tasks before bounded runtime drain.

`MCPFoundationStandaloneBackend`, generated schema manifests/recorders, and live-window schema
authorities are absent. `Scripts/headless_runtime_guardrails.sh` enforces those constraints.

Focused evidence:

- `make dev-swift-build PRODUCT=repoprompt-mcp` — ticket
  `21d62d24-8d50-436d-9cf7-6168eb47f466`, passed
- `make dev-test FILTER=DirectHeadless` — ticket
  `85613910-335d-4d71-8b82-759644c61864`, 9 passed
- `make dev-test FILTER=DomainAgentWorktreeBindingStoreTests` — ticket
  `bde7ba65-c1dd-4a21-8b1f-4dba19b6d7f3`, 2 passed
- `make dev-test FILTER=DomainCredentialAndChildLaunchTests` — ticket
  `a5354120-4f93-4602-bdd5-7c56fab4570c`, 2 passed, including token replay,
  foreign-runtime rejection without consumption, and expiry
- canonical app/direct schema fingerprint — ticket
  `d6247ccb-d6b7-4954-bddc-7370ef41d5be`, passed for all 27 tools and globals
- M0 contract relocation/parity inventory — ticket
  `33071c7f-cfe0-45c9-ac13-31174d382b82`, 3 passed

Final bounded validation:

- `make dev-test FILTER=DirectHeadless` — ticket `56e2a405-5409-41d0-a758-d07517039a35`, passed after the final nonblocking-frame, child-policy, and terminal-category hardening;
- `ALLOW_ADHOC_SIGNING=1 make dev-build` — ticket `ec3e28af-8130-44af-ab02-30f72e90a623`, passed both products, packaged the app/helper, verified architectures/layout/signatures, and ran the embedded-helper smoke without launching the app;
- `make dev-lint` — tickets `6464e35e-06cf-4f11-acf7-dc4812f398ec` and final transport follow-up `1d43fe74-0549-479d-9c8a-bca0e07d9705`, passed;
- `make guardrails` — passed, including headless-runtime/source-layout/contributor/legal/Codex guards;
- ledger verification — 3,757 exact root/provider methods; final list tickets `c0e940e8-f493-48b2-b929-69902e829f32` and `9da7de5d-0f49-4939-a8c4-b35a32cec3ac`;
- provider package — ticket `47b04d4e-466b-4e00-b243-2687bbc5cadf`, passed;
- `make dev-codex-schema-check` — ticket `f9b2e28f-6703-41a7-bf5c-c98408b14837`, environment-blocked before comparison because the installed Codex CLI is `0.144.1` and the repository floor is `0.145.0`;
- one bounded full `make dev-test` — ticket `35672252-0786-453b-b562-6a9a859cbf16`, completed with unrelated lower-stack/environment failures in codemap scheduler-priority timing, goal-feature defaults, and a bootstrap socket-lock cascade; no M6-focused suite failed, and the focused M6 rerun above is clean. Per the bounded verification policy this root run was not repeated;
- final design-review stdio closure — `make dev-test FILTER=DirectHeadlessStdioTransportTests`, ticket `2e1ff4c0-8bca-4abd-9df6-bfa2ef7603c6`, 6 passed, including bounded valid-frame backpressure with no drops.
