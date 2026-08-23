# Headless MCP domain runtime

The RepoPrompt CE MCP executable supports three session backends:

```bash
repoprompt-mcp --backend app
repoprompt-mcp --backend headless
repoprompt-mcp --backend auto
```

`app` remains the default for MCP stdio mode until explicit live and release validation supports a later cutover. `auto` is an explicit preview mode: it performs one bounded connect-only probe of the well-known app bootstrap socket before reading `initialize`, then fixes the selected backend for the process lifetime. It never probes private headless child endpoints and never switches an initialized session. `app` preserves proxy reconnect/replay behavior; `headless` composes the direct runtime. Interactive and exec modes are app-only and reject both `--backend headless` and `--backend auto`.

## Ownership

`RepoPromptDomainRuntime` owns the protocol-neutral MCP host and canonical 27-tool catalog. It owns connection generations, invocation admission, policy/resource lanes, progress, watchdogs, settlement, terminal fencing, response-delivery accounting, and bounded drain. The app's `ServerNetworkManager`, `ServerController`, and `MCPService` are transport, presentation, proxy, reconnect, replay, listener, and approval adapters.

App transport lifetime is process-owned from launch through termination. Opening or closing the last window does not start or stop MCP. Window identity is accepted only as an admission selector: public `window_id` binding captures that window's current logical tab as an explicit authoritative context, while hidden `_windowID` captures the same context for one call. Later active-tab changes do not redirect either admitted call or persistent binding. There is no active-tab execution fallback.

Canonical schemas are Swift definitions in `MCPDomainCanonicalToolDefinitions`. Both app and direct registration consume those definitions through `MCPDomainToolRegistry`; there is no legacy service registry, generated resource manifest, live-window recorder, or mixed catalog authority. Provider-built app tools already contain one `MCPAppToolBinder` execution envelope and are projected without wrapping them again; raw shared bindings receive exactly one envelope. Invalid, duplicate, or noncanonical catalogs fail by throwing during startup registration rather than trapping.

Standalone composition uses a `.standalone` registration scope and never creates a synthetic window. `bind_context` is global in headless mode and accepts domain `context_id` or working-directory selectors; window selectors fail closed. Direct workspace/read/search/tree/selection/prompt execution delegates to `MCPDomainCanonicalWorkspaceService`. The executable adapter supplies only physical snapshots, mutation persistence, and path resolution, avoiding a second implementation of canonical tool semantics.

The durable direct backend is bundle-private. The public `repoprompt-mcp` launcher reaches it through `RepoPromptHeadlessLaunchBridge`; the helper entry is `Packages/RepoPromptServer/Sources/RepoPromptMCPHeadlessExecutable` and is never installed or linked on `PATH`. Its direct service resolves the authority namespace and calls `RepoPromptAuthorityHostFactory.startDirectHeadless`. The helper must not acquire a namespace lease, open SQLite, or reconstruct provider/resource recovery itself. Host owns those actions and returns the leased runtime/mutation gate; the helper composes MCP only and never HTTP, TLS, portal, SSE, metrics, or a maintenance/migrating serving mode.

Server-mode HTTP composition is separate: `RepoPromptServerExecutable` is the only target that combines `RepoPromptServerHost`, `RepoPromptServiceHTTP`, and the state-free `RepoPromptMCPAdapter`. `RepoPromptServerHost` has no HTTP dependency or import. Both `server` and `directHeadless` serving paths use the same Host factory and refuse a nonempty pending migration before DDL, recovery, or other store mutation.

App-only physical operations are grouped in `MCPAppPhysicalCapabilityAdapters.Execution`, `.Context`, `.Selection`, `.Files`, and `.Prompt`. The composition root supplies these typed capability families; the retired flat closure dependency bag is not a runtime boundary. The standalone installer reuses `MCPDomainReadToolProvider` and applies both long-running and protected-mutation decorators to every canonical binding. File edits use the shared production apply-edits engine, including operation-ID correlation, revision validation, path fencing, approval, and retry classification.

## Direct transport and child calls

Direct mode installs one MCP SDK `Server` over `MCPStdioServerTransport`; it does not add a second JSON-RPC dispatcher. The transport records one accepted-request/delivered-response hop and distinguishes stdin EOF, truncated EOF, read/poll failure, PPID replacement, broken pipe, write failure, and cancellation. Terminal paths enter bounded host drain before runtime shutdown.

Long-running Agent and Context Builder providers receive an explicit run-scoped carrier. The carrier contains a private Unix endpoint, single-use launch token, verified principal/provider identity, and run ID. The endpoint directory is owner-only, the socket is identity-fenced, and token redemption checks runtime generation, peer PID, expiry, scope, and replay before registering a child connection. App-spawned provider children receive explicit `--backend app`; direct-runtime children use the private run-scoped endpoint and never auto-probe the app.

## State roots and security defaults

The default headless session reads the same canonical RepoPrompt CE application-support and workspace persistence roots as the app. It does not derive state from the process current working directory and does not silently create a foreign `Headless/default` profile. This preserves canonical workspace identities, selection persistence, and durable state across app and direct sessions.

When every `REPOPROMPT_MCP_WORKING_DIRS` entry is an existing Git worktree of exactly one saved workspace root, direct mode binds that canonical saved workspace and keeps an in-memory canonical-to-physical root map for the process lifetime. `agent_run` existing-worktree selectors replace one physical root in a session-local overlay; nested runs and provider-backed conversations inherit that overlay unless `inherit_worktree=false`. Physical tool execution and root fencing use the selected roots; mappings that carry worktree identity revalidate that Git identity before later use, while workspace documents retain their canonical roots. Direct mode never persists these overlays or a temporary workspace, never creates a worktree, and fails closed on unknown or ambiguous workspace, repository, root, or worktree identity. App-backed routing is unchanged.

`REPOPROMPT_MCP_HEADLESS_PROFILE_DIR` is an explicit isolation boundary for tests and automation. A nondefault `REPOPROMPT_MCP_HEADLESS_PROFILE` requires that directory instead of inventing storage. Explicit roots may bootstrap a synthetic workspace only inside such an isolated profile. Protected mutations default to deny until the selected persistence policy authorizes the verified principal; long-running provider costs remain decorated and auditable. Direct mode has no AppKit, SwiftUI, window, view-model, live-app, or UI-presentation dependency.

## Validation owners

- Backend-selection tests own the app default, explicit selection, one-shot auto probing, unavailable-app fallback, parser rejection, and no-protocol-bytes probe contract.
- Domain host tests own admission/drain/generation/watchdog/delivery invariants.
- Canonical catalog tests own all 27 fingerprints, single execution envelopes, fail-closed materialization, and headless `bind_context` semantics.
- Routing tests own exact presentation-to-context capture and rejection when no authoritative context exists.
- Standalone composition tests construct the real runtime without app composition and resolve every canonical tool.
- Direct process tests launch the built executable with no app, exercise canonical state roots and the advertised policy surface, verify denied mutations do not execute, and validate EOF drain.
- Direct worktree-routing tests use real linked Git worktrees and a saved workspace fixture to prove automatic canonical binding, exact existing-worktree selection, coordinator-level detached lifecycle reconciliation, child and provider-conversation inheritance and opt-out, use-time identity revalidation for mappings that carry worktree identity, physical root fencing, stable repository/worktree identities, and zero workspace or worktree-binding persistence. End-to-end `orchestrate` dispatch remains owned by the direct-headless workflow/tool-policy integration boundary rather than this routing fixture.
- Stdio and private-endpoint tests own terminal provenance, bounded broken-pipe behavior, half-close response drain, identity fencing, token redemption, replay, expiry, and foreign-runtime rejection.
- `Scripts/headless_runtime_guardrails.sh` rejects duplicate schema/backend/workspace authorities, flat dependency-bag storage, retired registry/window-tool compatibility types, and MainActor/UI dependencies in the domain runtime.
