# MCP lifecycle diagnostics (#1039)

## Scope and evidence

This is an observation-only change, not a crash fix. Sentry issue
[7607620546](https://repoprompt.sentry.io/issues/7607620546/) contains event
`03ab2e99df19470d9db712e6cec5cf7a` at `2026-09-17T09:17:32Z`, reported in
[GitHub #1039](https://github.com/repoprompt/repoprompt-ce/issues/1039).
The inspected issue had 180 events; this is a snapshot, not a current count.

Sanitized provenance: release `com.pvncher.repoprompt.ce@1.4.1+37`, release
commit `f5dcf7db54cca520fbe37056c1397b3af8679dd1` (Sentry lastCommit agrees
with the v1.4.1 stable rollout manifest), MCP SDK revision
`85dec2fc7a27252bc33dc7728be6af6b3bd398c0` from `repoprompt/swift-sdk`.
The event ran on macOS 14.8.5 (23J423), x86_64. App image debug ID
`994c8653-59c2-380d-aca8-a678f60f4a63` and libswift_Concurrency image debug ID
`66126279-2274-3a36-9726-6166da401ee6` both had symbols found. Compiler and
Swift runtime semantic versions were not present in the inspected evidence.

The symbolicated stack includes `swift_task_dealloc`, Swift concurrency fatal
error, `TaskLocal.withValueImpl`, `ServerNetworkManager.withConnectionID`, and
the registerHandlers closure. Existing breadcrumbs show only app initialization
and MCP startup. This establishes a task allocator teardown failure, not which
request, cancellation, transport, or runtime defect caused it. Source line
numbers refer to that release, not current main. Do not infer a TaskLocal fix
or rewrite TaskLocal propagation from this stack alone.

## Entry point, privacy, and lifecycle

`MCPLifecycleDiagnostics.shared.record` observes existing tools/call entry/return,
actual provider entry/return, watchdog cancellation/grace/late settlement,
watchdog abort, and admitted connection removal/cancellation/stop/completion.
Provider markers bracket the domain host's actual resolved binding, after all
host admission/activation checks and successful `providerWillEnter`. A rejected
admission or a throwing entry callback emits neither provider marker. The
binding's return callback is synchronous and default-no-op for other callers;
it runs on both success and throw, without changing settlement ownership.
The handler-return marker sits outside the connection TaskLocal wrapper; it
means the closure is returning, not that Swift has deallocated its task frame.
Removal completion can precede a detached provider's late settlement.
`owned_tools_cancelled` means the cancellation call returned, not that every
provider cooperated. `connection_stopped` includes an already-stopped committed
bootstrap predecessor. Missing phases are unknown evidence, not proof of absence.

The recorder uses one short synchronous lock; it creates no tasks, timers, files,
new TaskLocals, or release-side event buffer. Sequence numbers order recorder
observations within one process only; they do not establish cross-process or
cross-await causality. Its sink is installed only after existing Sentry startup
consent, DSN, and environment gates succeed. Opt-out clears the sink under the
same lock before SDK close. No destination or consent setting changes.

The existing Sentry project receives category `mcp.lifecycle`, a fixed phase
message, and only these closed-schema fields: `schema=mcp_lifecycle_v1`, opaque
app-generated `connection_id`, optional opaque app-generated `invocation_id`,
fixed `phase`, and process-local `sequence`. These UUIDs are not account/session,
client, workspace, JSON-RPC, or user operation identifiers. No names, paths,
prompts, content, arguments, responses, credentials, error descriptions, or
provider payloads are accepted. The existing scrubber and 20-breadcrumb ring
remain unchanged; unrelated or busy connections can evict relevant phases.
The DEBUG-only test capture requires explicit connection registration, retains
at most 128 observations per registered connection, and is removed by test defer.

## Deterministic coverage and bounded investigation

The existing socket integration fixture covers normal return, idle EOF and
immediate reconnect (distinct correlation), cancellation after provider entry
with late settlement, and a manual-clock watchdog timeout where the provider
ignores cancellation and settles after terminal socket delivery. Real lifecycle
hooks are inspected; no new synthetic state machine is asserted. The existing
pre-activation gate asserts absence of provider markers before binding entry,
and expired admission asserts only request entry/handler return. Existing
protocol outcome assertions remain authoritative. These tests do not reproduce
the allocator crash or prove release/runtime compatibility.

For one instrumented release, inspect at most the first **20 matching crash
events or 7 days after rollout, whichever comes first**. Group only by exact
release, macOS/architecture, image debug IDs, and available runtime/compiler
provenance. Compare retained phase/sequence/UUID correlations, explicitly mark
truncated rings and missing fields unknown, and report whether normal return,
request cancellation, watchdog force-disconnect, or connection removal preceded
the crash. Do not treat no crashes as a fix or claim causation from adjacency.
Record missing compiler/runtime provenance rather than guessing it.

At that boundary, remove the lifecycle sink/hooks if evidence is sufficient or
no longer useful; extending the observation window needs an explicit maintainer
decision. This is an operational review window, not a hidden per-install timer.
Turning off existing telemetry stops recording immediately. No on-disk local
artifact cleanup is needed. Live instrumented reproduction and hosted release
validation are separate follow-ups; this patch must not be reported as crash
resolution on the strength of local focused tests alone.
