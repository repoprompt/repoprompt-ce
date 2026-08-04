# Headless MCP domain runtime — M5 AI, Agent, Context Builder, and interaction

Milestone 5 is PR 6/8, stacked on finalized M4B (`feature/headless-runtime-m4-protected-mutations`). It moves long-running AI/Agent lifecycle authority into `RepoPromptDomainRuntime` while retaining existing app providers as injected physical and presentation adapters. It does not add a direct stdio host or a real private child listener.

The machine-readable gate is frozen in `Scripts/Fixtures/headless_mcp_domain_runtime_m5_contract.json`.

## Authority and compatibility ledger

| Concern | M5 authority | Compatibility boundary |
|---|---|---|
| Agent sessions | `DomainAgentRunSessionStore` and neutral `DomainAgentRun*` DTOs | `AgentRunSessionStore` and `AgentRunMCPSnapshot` are app adapters; view models project/provider-drive state but do not own lifecycle |
| Oracle, Context Builder, Agent, and session-control invocation | `MCPDomainLongRunningToolProvider` wraps the canonical binding once | physical app providers retain public schemas, result envelopes, transcript/history behavior, and process implementation |
| interaction | `DomainInteractionBroker` | negotiated elicitation is installed per capable MCP connection; app UI is a cancellable presentation adapter; absent providers return immediately unavailable |
| child launch handoff | `DomainPrivateChildLaunchHarness`, `DomainChildLaunchCarrier`, and the M2 `DomainRunLaunchToken` issuer | injected tests prove carrier/token issuance; Claude/Codex/ACP launch boundaries consume the task-local carrier; real endpoint issuance/connectivity is M6B |
| credentials | `DomainCredentialEnvelopeStore` | unresolved M0 packaged-child Keychain evidence requires parent-owned, minimum-scope, memory-only, single-use envelopes |
| cost/process approval | M4 `DomainMutationPolicyStore` with `ai_cost` and `external_process` actions | verified app proxy remains compatible; run-scoped calls require authoritative routing plus an explicit grant and revalidate immediately before backend entry |
| observability | `DomainActivityCenter` | app UI may project snapshots; activity sequence and terminal settlement are runtime-owned |
| registration | `ServiceRegistry` composes long-running then protected wrappers | no second registration or schema implementation is introduced; typed policy failures are not flattened |

## Session lifecycle, shutdown, and recovery

Registrations carry runtime ID, runtime lifecycle generation, session ID, and registration generation. Turn epochs additionally carry activation ID, monotonic ordinal, continuity generation, and transition kind. Terminal publication requires an exact epoch plus commit ID: the same commit is idempotent, a different commit fails closed, and a stale epoch cannot replace the current epoch.

Parked waits own cancellable continuations and bounded timeout tasks. Replacement, TTL expiry, cleanup, caller cancellation, and runtime shutdown settle each exact waiter. Shutdown enters draining, atomically removes all records, cancellation handlers, TTL tasks, and waiter continuations before its first suspension, then resumes each waiter once. New waits and cancellation-handler installs fail closed throughout drain. Provider cancellation is deadline-bounded; unfinished sessions persist as interrupted metadata.

`AgentModeViewModel` installs one exact-registration cancellation handler after control activation and removes it during exact deactivation. The handler revalidates tab, session, activation, and registration before invoking physical provider teardown. The runtime store, not the view model, remains lifecycle authority.

Durable data is resumability metadata, never a claim that a process is alive. Metadata is a versioned, profile-scoped document written through `DomainPersistenceCoordinator` advisory locking, digest CAS, and atomic replacement. Corrupt, future-version, wrong-profile, and ownership-conflicting documents remain byte-preserved while the session store exposes degraded read-only health. Bootstrap retains the prior owning runtime identity and projects nonterminal records as dormant without reconstructing execution. A record last durably owned in `active` state is not claimable by another runtime; ownership transfer requires the prior runtime to have durably written an inactive, interrupted, or terminal state, followed by an explicit fenced claim.

Writes are dirty-session based and debounced. CAS merges distinct-session writers, rejects competing ownership changes, and retries only bounded conflicts. Metadata retains at most 512 prioritized records, prunes inactive entries older than 30 days, and reports omitted retention count. No transient execution is reconstructed.

## Interaction settlement

The broker selects one provider in this order:

1. negotiated MCP form elicitation installed for the exact connection after capability negotiation;
2. app UI when the current routed window/run can present;
3. immediate unavailable.

The app adapter resolves the default from the workspace `questionTimeoutSeconds` setting. Explicit positive caller timeouts remain supported; the broker adds only a one-second internal settlement grace. Agent Mode and Context Builder presenters install exact interaction/run cancellation, dismiss pending UI on timeout or caller cancellation, and ignore late answers.

Each request has an internal generation. Response, timeout, caller cancellation, provider failure, connection removal, and runtime shutdown race through one settlement path. The winning path removes the pending record, cancels provider/timeout work, dismisses presentation when needed, and resumes once. Connection removal also removes the per-client provider and rechecks after suspended availability so it cannot create a late waiter. Later responses are ignored and counted. MCP elicitation reuses the canonical `ask_user` parser, preserves optional per-question skip, converts the existing structured questions to a form schema, and converts accept/decline/cancel back to the unchanged `ask_user` result envelope. Because the current MCP SDK does not expose the outbound elicitation request ID, provider cancellation closes the exact owning MCP connection to guarantee dismissal and fail closed.

## Child launch and credential fallback

`DomainPrivateChildLaunchHarness` accepts an injected endpoint descriptor and launch-token issuer. It emits only:

- `REPOPROMPT_MCP_PRIVATE_ENDPOINT`
- `REPOPROMPT_MCP_LAUNCH_TOKEN`
- `REPOPROMPT_MCP_CREDENTIAL_ENVELOPE` when a credential is required

`DomainChildLaunchEnvironmentBridge` strips inherited copies of all three keys and merges only the current task-local carrier at the final Claude native, Codex app-server, and ACP process environments. This launch-configuration seam is live in M5. Production creation of the real identity-fenced private endpoint, issuance of a carrier for it, transport connection, and redemption protocol remain M6B; M5 does not publish a placeholder endpoint or claim end-to-end private connectivity.

The credential environment value is an opaque envelope identifier, not a secret. Secret bytes live in a uniquely owned manually allocated buffer rather than a Swift copy-on-write collection. The buffer is inspected directly in tests and zeroed in place on store consume, payload consume (including a throwing consumer), revoke, expiry, and shutdown. Scope binds runtime generation plus provider/run/principal/purpose; payload consumption is one shot; descriptions are redacted; bytes are never persisted.

## Long-running invocation and activity

The shared provider covers `oracle_utils`, `ask_oracle`, `oracle_send`, `context_builder`, `ask_user`, `agent_explore`, `agent_run`, `agent_manage`, `share_thoughts`, `set_status`, and `wait_for_next_user_instruction`.

AI sends and Agent operations that may invoke a model or process require `ai_cost` and/or `external_process` authorization. Run-scoped authorization requires authoritative routing; no M5 opt-out exists. Typed `DomainMutationPolicyError` categories propagate through the domain binding. The immutable authorization snapshot is revalidated immediately before physical execution. A specifically injected child carrier does not weaken routing; it only carries already-authorized launch state.

Every migrated call publishes runtime activity with a monotonic sequence. Active state cannot overwrite terminal state, terminal commit is exactly once, and shutdown converts remaining active activities to cancelled. `DomainRuntimeSnapshot` reports activity counts plus agent-session persistence health.

## Gate evidence

Focused evidence belongs to:

- `DomainAgentRunSessionStoreTests` including concurrent cancel/publish/ingest/wake/shutdown and persistence CAS/degraded/retention cases;
- `DomainInteractionBrokerTests` and `DomainInteractionAppSeamTests`;
- `DomainCredentialAndChildLaunchTests` with owned-byte inspection;
- `DomainActivityAndLongRunningProviderTests` including typed routing denial and configured interaction timeout;
- existing Agent run/manage/wait, Oracle, Context Builder, ask-user, catalog, and app-registration parity suites;
- both product builds, provider-package tests, lint, authoritative test list/ledger, contribution preflight, and source-layout guardrails.

## Explicit exclusions

M5 does not extract the MCP host, add direct stdio, open or publish a real private child listener, connect a child to that listener, change proxy routing, change the frozen 27-tool catalog, automatically select a backend, delete app adapters, or perform M7 cleanup.
