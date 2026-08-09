# Headless MCP domain runtime

The RepoPrompt CE MCP executable supports three session backends:

```bash
repoprompt-mcp --backend app
repoprompt-mcp --backend headless
repoprompt-mcp --backend auto
```

`app` remains the default for MCP stdio mode until explicit live and release validation supports a later cutover. `auto` is an explicit preview mode: it performs one bounded connect-only probe of the well-known app bootstrap socket before reading `initialize`, then fixes the selected backend for the process lifetime. It never probes private headless child endpoints and never switches an initialized session. `app` preserves proxy reconnect/replay behavior; `headless` composes the direct runtime. Interactive and exec modes are app-only and reject both `--backend headless` and `--backend auto`.

## Linux packaging

On Linux, the root SwiftPM manifest deliberately contains only the portable
domain/core targets and a focused `RepoPromptMCP` executable source set. That
source set compiles `DirectHeadlessMCPService`, its canonical capability
adapters, private child transport, and bounded stdio transport directly from
the same files used by macOS. There is no Linux-only tool catalog, filesystem
engine, configuration model, or parallel runtime target.

The Linux executable requires `--backend headless` (or
`--backend=headless`). It rejects the unavailable `app` and `auto` backends as
well as macOS-only interactive/exec arguments. Requiring explicit selection
keeps the upstream backend contract visible in process launch configuration and
prevents a Linux packaging default from silently changing macOS CLI semantics.

The default Linux state root is `$XDG_DATA_HOME/repoprompt-ce`, falling back to
`~/.local/share/repoprompt-ce`. Automation should use the existing
`REPOPROMPT_MCP_HEADLESS_PROFILE_DIR` isolation boundary and provide canonical
workspace roots through `REPOPROMPT_MCP_WORKING_DIRS`. The container fixes
these to `/data` and `/workspace`, runs as uid/gid 65532, disables networking in
the final contract harness, and invokes the same explicit backend flag.

`Scripts/test_linux_headless_native.sh` owns the native Swift build and domain
tests. `Scripts/test_linux_headless_mcp.py` owns the process-level MCP contract:
initialize, canonical tool listing, absence of window authority, a real
canonical `read_file`, protected-mutation fail-closed behavior, single- and
dual-Oracle provider execution, route-level overlap rejection, distinct
single-use child carriers, structured failure decoding, and bounded EOF drain.
`Scripts/test_linux_headless_docker.sh` repeats that contract against the final
image rather than only the build stage. Its launcher writes an expiring,
principal-bound test policy granting only the Oracle/Context Builder cost and
external-process operations plus the context bind used by the route-isolation
check; production defaults stay deny-by-default.

## Ownership

`RepoPromptDomainRuntime` owns the protocol-neutral MCP host and canonical 27-tool catalog. It owns connection generations, invocation admission, policy/resource lanes, progress, watchdogs, settlement, terminal fencing, response-delivery accounting, and bounded drain. The app's `ServerNetworkManager`, `ServerController`, and `MCPService` are transport, presentation, proxy, reconnect, replay, listener, and approval adapters.

App transport lifetime is process-owned from launch through termination. Opening or closing the last window does not start or stop MCP. Window identity is accepted only as an admission selector: public `window_id` binding captures that window's current logical tab as an explicit authoritative context, while hidden `_windowID` captures the same context for one call. Later active-tab changes do not redirect either admitted call or persistent binding. There is no active-tab execution fallback.

Canonical schemas are Swift definitions in `MCPDomainCanonicalToolDefinitions`. Both app and direct registration consume those definitions through `MCPDomainToolRegistry`; there is no legacy service registry, generated resource manifest, live-window recorder, or mixed catalog authority. Provider-built app tools already contain one `MCPAppToolBinder` execution envelope and are projected without wrapping them again; raw shared bindings receive exactly one envelope. Invalid, duplicate, or noncanonical catalogs fail by throwing during startup registration rather than trapping.

Standalone composition uses a `.standalone` registration scope and never creates a synthetic window. `bind_context` is global in headless mode and accepts domain `context_id` or working-directory selectors; window selectors fail closed. Direct workspace/read/search/tree/selection/prompt execution delegates to `MCPDomainCanonicalWorkspaceService`. The executable adapter supplies only physical snapshots, mutation persistence, and path resolution, avoiding a second implementation of canonical tool semantics.

App-only physical operations are grouped in `MCPAppPhysicalCapabilityAdapters.Execution`, `.Context`, `.Selection`, `.Files`, and `.Prompt`. The composition root supplies these typed capability families; the retired flat closure dependency bag is not a runtime boundary. The standalone installer reuses `MCPDomainReadToolProvider` and applies both long-running and protected-mutation decorators to every canonical binding. File edits use the shared production apply-edits engine, including operation-ID correlation, revision validation, path fencing, approval, and retry classification.

## Direct transport and child calls

Direct mode installs one MCP SDK `Server` over `MCPStdioServerTransport`; it does not add a second JSON-RPC dispatcher. The transport records one accepted-request/delivered-response hop and distinguishes stdin EOF, truncated EOF, read/poll failure, PPID replacement, broken pipe, write failure, and cancellation. Terminal paths enter bounded host drain before runtime shutdown.

Long-running Agent and Context Builder providers receive an explicit run-scoped carrier. The carrier contains a private Unix endpoint, single-use launch token, verified principal/provider identity, and run ID. The endpoint directory is owner-only, the socket is identity-fenced, and token redemption checks runtime generation, peer PID, expiry, scope, and replay before registering a child connection. App-spawned provider children receive explicit `--backend app`; direct-runtime children use the private run-scoped endpoint and never auto-probe the app.

The direct Oracle provider resolves Codex from `PATH` or the explicit
`REPOPROMPT_CODEX_COMMAND` executable. The container intentionally keeps
provider installation and credentials outside the image; mount or extend the
image with a Linux Codex executable and set that variable when Oracle calls are
needed. Oracle and Context Builder launches still require the normal explicit
`ai_cost` and `external_process` mutation grants.

Headless dual Oracle uses the same nullable
`models.secondary_oracle_model` setting as the app. `null` or blank retains the
legacy single-lane result. A configured raw model runs Primary and Secondary
Codex processes concurrently, maintains stable pair/member IDs, allows
continuation through either member, and returns the PR #9 pair envelope with
independent lane results. Context Builder plan/question results nest that
envelope under `plan`, while review nests it under `review`, and the Primary ID
remains the follow-up chat. One failed lane yields `partial_failure`; two failed
lanes use the versioned structured pair-failure envelope. Disabling Secondary
Oracle prevents an existing pair from being continued as an accidental single
history. Pair state and logs are scoped to the bound context, each turn freezes
one route/root for both providers, and overlapping sends on that route fail
before conversation state changes. Because private launch tokens are
single-use, the long-running runtime exposes one bounded additional reservation
and the pair consumes a distinct carrier for each lane.
Provider roots are created in dedicated POSIX process groups; cancellation
terminates the group with a bounded TERM-to-KILL escalation so same-group
descendants cannot retain a private carrier after the Oracle turn ends. The
container uses `tini` as PID 1 to reap any resulting orphaned processes.

## State roots and security defaults

The default headless session reads the same canonical RepoPrompt CE application-support and workspace persistence roots as the app. It does not derive state from the process current working directory and does not silently create a foreign `Headless/default` profile. This preserves canonical workspace identities, selection persistence, and durable state across app and direct sessions.

`REPOPROMPT_MCP_HEADLESS_PROFILE_DIR` is an explicit isolation boundary for tests and automation. A nondefault `REPOPROMPT_MCP_HEADLESS_PROFILE` requires that directory instead of inventing storage. Explicit roots may bootstrap a synthetic workspace only inside such an isolated profile. Protected mutations default to deny until the selected persistence policy authorizes the verified principal; long-running provider costs remain decorated and auditable. Direct mode has no AppKit, SwiftUI, window, view-model, live-app, or UI-presentation dependency.

## Validation owners

- Backend-selection tests own the app default, explicit selection, one-shot auto probing, unavailable-app fallback, parser rejection, and no-protocol-bytes probe contract.
- Domain host tests own admission/drain/generation/watchdog/delivery invariants.
- Canonical catalog tests own all 27 fingerprints, single execution envelopes, fail-closed materialization, and headless `bind_context` semantics.
- Routing tests own exact presentation-to-context capture and rejection when no authoritative context exists.
- Standalone composition tests construct the real runtime without app composition and resolve every canonical tool.
- Direct process tests launch the built executable with no app, exercise canonical state roots and the advertised policy surface, verify denied mutations do not execute, and validate EOF drain.
- Stdio and private-endpoint tests own terminal provenance, bounded broken-pipe behavior, half-close response drain, identity fencing, token redemption, replay, expiry, and foreign-runtime rejection.
- `Scripts/headless_runtime_guardrails.sh` rejects duplicate schema/backend/workspace authorities, flat dependency-bag storage, retired registry/window-tool compatibility types, and MainActor/UI dependencies in the domain runtime.
