# Remote control architecture

RepoPrompt Remote is a RepoPrompt-specific control protocol for a paired mobile
client. It is not a network version of the existing Unix-socket MCP transport.

## Standalone wire contract

RepoPrompt CE owns its Foundation-only protocol implementation in
`Sources/RepoPromptRemoteProtocol/` and builds it as an internal SwiftPM target.
It has no source, package, path, submodule, or build dependency on any companion
application repository. `Sources/RepoPromptShared/RemoteProtocolExports.swift`
re-exports the internal target for desktop consumers without importing the app
UI or MCP implementation.

Companion clients own their protocol implementations independently. Compatibility
is defined only by the versioned wire format. The protocol-v1 baseline in this
repository is frozen against the RepoPrompt Remote TestFlight source commit
`0bfa18f2a480791cddde24bb79fa79b40d0dd934`; the contract tests and JSON fixtures
under `Tests/RepoPromptRemoteProtocolTests/` protect decoding and additive-field
compatibility with that shipped client. Neither application needs the other
application's checkout to build.

`RemoteSnapshot` is the authoritative fleet projection sent after pairing and
on reconnect. It contains desktop and connection state, authorization, all saved
workspaces, live or persisted sessions, attention items, workflow and agent
catalogs, and the last event cursor.

`RemoteEvent` is a versioned, RepoPrompt-specific event envelope. Every event
has a desktop instance ID, monotonic sequence number, event ID, timestamp, event
type, and optional workspace/session scope. The event payload is typed and does
not provide a generic MCP or arbitrary JSON escape hatch.

`RemoteEventReplayBuffer` is a bounded actor-owned buffer. A reconnect requests
events after the mobile cursor. If the cursor is older than the retained range,
the gateway must return a complete snapshot before resuming live events. Event
IDs are deduplicated so retries cannot apply the same event twice.

The current wire surface includes:

- `POST /remote/v1/pair`
- `GET /remote/v1/snapshot`
- `GET /remote/v1/events?after=<cursor>`
- `GET /remote/v1/workspaces`
- `GET /remote/v1/sessions`
- `GET /remote/v1/agents`
- `GET /remote/v1/workflows`
- `GET /remote/v1/diagnostics`
- `GET /remote/v1/history?q=<query>&limit=<n>`
- `GET /remote/v1/transcript?session_id=<id>&after=<sequence>&limit=<n>&details=1`
- `POST /remote/v1/commands`
- `POST /remote/v1/context-builder`

History can be scoped with `workspace_id`. The response echoes the workspace
and includes `olderCursor` when more chats are available. Pass its
`lastActivityAt` and `sessionID` as `before_date` and `before_id` on the next
HTTPS request, or as the typed `before` cursor over Iroh. Dates are measured in
seconds since 2001-01-01 UTC. Older desktops return a global page without the
workspace echo.

The gateway emits coarse workspace, session, run-state, interaction, and
authorization/catalog events from the same authoritative projection used for
snapshots. Transcript rows are paged separately so the fleet stream stays
bounded. Tool arguments/results, reasoning, file/worktree key paths, process
metadata, and approval-adjacent details are only returned when the client
explicitly requests `details=1`; common credential fields are redacted before
returning them.

## Authorization

The desktop remains the authorization boundary. `RemoteAuthorizationState`
models the default device authority and an optional temporary/session-scoped
grant. Mobile controls may be hidden or disabled for usability, but the desktop
must evaluate the required authority again when it executes each command.

The levels are intentionally ordered:

| Level | Meaning |
| --- | --- |
| `observe` | Read state, transcripts, and history |
| `respond` | Answer questions, approve lower-risk interactions, send follow-ups |
| `control` | Start, steer, cancel, resume, workflows, and Context Builder |
| `danger` | High-risk, destructive, unrestricted, or cleanup actions |

Secret interactions are represented by `RemoteInteractionSummary` only as a
pending secure-entry prompt. No answer value is present in a snapshot, event,
history record, search index, or push payload. The command endpoint accepts the
secret as a one-shot request body and excludes it from its response and all
remote projections.

## Gateway boundary

The desktop implementation now lives below the app/UI layer in
`Sources/RepoPrompt/Infrastructure/Remote`:

```text
RemoteGatewayController
  ├── pairing and device credential store
  ├── desktop-enforced authorization
  ├── snapshot projection
  ├── HTTPS JSON snapshot/catalog/history/transcript/diagnostics endpoints
  ├── HTTPS JSON command endpoint
  ├── resumable event stream and replay buffer
  └── encrypted notification envelope + configurable relay client
        │
        ▼
shared typed RepoPrompt control services
        │
        ▼
existing Agent Mode, Context Builder, workspace, and history services
```

The gateway does not call MCP providers through serialized tool requests. It
uses `RemoteSnapshotBuilder`, `WindowRemoteReadService`, and
`WindowRemoteAgentControlService` to call typed application services directly.
The command boundary rechecks authorization before dispatching Agent Mode
start, follow-up, steer, response, cancel, and resume operations.

The gateway is opt-in. Pinned LAN HTTPS remains the default transport and uses
Bonjour for discovery; Iroh is a separate explicit opt-in for newer Remote
builds. The default pairing QR remains the untagged LAN advertisement understood
by the current TestFlight build. Pairing codes contain a short-lived, one-time
secret, never a long-lived bearer credential. The desktop stores the generated PKCS#12 TLS identity, Iroh endpoint identity,
and paired-device credential in the app's signed secure-storage domain. The
runtime imports the TLS identity in memory. An upgrade migrates legacy records
that are accessible without a Keychain prompt, preserving the certificate pin and
bearer. Unpair persists a revocation marker before clearing the live connection
so a legacy record cannot restore access after a restart.

## Local development integration

RepoPrompt CE and RepoPrompt Remote are standalone repositories. CE owns its
protocol implementation in `Sources/RepoPromptRemoteProtocol` and its Iroh
transport package in `Packages/RepoPromptIrohTransport`; neither package resolves
source from a sibling checkout. Remote owns its corresponding implementation.
Wire fixtures and additive protocol contract tests—not shared source
distribution—keep the two applications compatible.

When developing the standalone mobile checkout, run `xcodegen generate`. A fast
Simulator Debug build may disable signing:

```sh
xcodebuild -project RepoPromptRemote.xcodeproj \
  -scheme RepoPromptRemote \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

For a device Debug build, select the developer's own Apple Developer team in
Xcode locally—never hard-code or commit it. Register the iPhone and use a
development profile for a Push Notifications-enabled App ID; the installed
Debug app must carry `aps-environment=development`.

Use the CE checkout's canonical coordinated workflow:

```sh
make doctor
export SIGN_IDENTITY='Apple Development: <local identity>'
export DEBUG_SECURE_STORAGE_BACKEND=keychain
make dev-build
make dev-run
make debug-cli-status            # make install-debug-cli if not installed
rpce-cli-debug -e 'windows'
```

The local signing identity and secure-storage override are required when
validating CE certificate and paired-credential persistence; never commit the
identity or team. Prefer the
applicable `make dev-*` targets (`make dev-test`, `make dev-smoke`, and so on)
to uncoordinated commands. Use `rpce-cli-debug` against the running CE debug app
to select a known workspace, create recognizable non-destructive session state,
and record the CLI start/wait result that the phone observes.

Run acceptance in sequence: pair Simulator through the Debug manual field with
the copied short-lived `rpremote://pair?...` value, then test a registered
physical iPhone by camera on the same non-isolated LAN. On the device, verify
Bonjour discovery and recovery after Wi-Fi interruption and a CE restart with
an ephemeral-port change. Only one device credential is active: forget the
pairing in iOS and revoke it in CE before re-pairing, and confirm the old
credential is rejected.

Optional local push comes last. Run the relay with APNs sandbox credentials
(`APNS_PRODUCTION` unset) and configure the Mac-side relay URL as
`http://127.0.0.1:8787/v1/notify`. The Mac, not the phone, resolves loopback;
push remains only an attention signal followed by authoritative LAN resync.
This path does not cover production APNs, FCM, or deployed relay operations.
Simulator, physical-device, Bonjour/LAN, Keychain-persistence, and APNs
acceptance remain environment-dependent and are not established by these
documentation steps.

## Delivery order

1. Extract typed control services and implement a snapshot projection from
   existing Agent Mode and workspace state.
2. Add the opt-in desktop listener, pairing, credential rotation, snapshot and
   command endpoints, and replayable event stream.
3. Build the separate iOS client against the same protocol-v1 wire contract.
4. Add Context Builder/workflow operations and explicit detail expansion on top
   of the established command/read boundaries. Context Builder clarify,
   question, plan, and review flows now use the desktop window-tool service;
   richer raw command/reasoning/file/worktree details are now available only
   through the explicit detail request.
5. Register iOS notification tokens and forward only encrypted, sanitized
   envelopes through a configured APNs/FCM-compatible relay; the phone always
   reconnects to the desktop for authoritative state.

## Current owner inventory

The first typed service seam is implemented in
`Sources/RepoPrompt/Infrastructure/Remote/RemoteControlServices.swift`.
Adapters currently read the following existing owners without routing through
serialized MCP requests:

| Remote concern | Current desktop owner | Adapter boundary |
| --- | --- | --- |
| Saved workspaces and immutable IDs | `WorkspaceManagerViewModel.workspaces` and `WorkspaceModel` | `WorkspaceManagerRemoteCatalogService` |
| Closed/open workspace state | `WindowStatesManager` plus `WorkspaceManagerViewModel` | `WorkspaceManagerRemoteCatalogService` |
| Workspace activation | `WorkspaceManagerViewModel.switchWorkspace(to:saveState:reason:)` | `WorkspaceManagerRemoteActivationService` |
| Compose-tab identity | `WorkspaceModel.composeTabs` and `activeComposeTabID` | workspace DTOs and activation result |
| Live Agent Mode state | `AgentModeViewModel.sessions` and `AgentModeViewModel.TabSession` | `AgentModeRemoteSessionQueryService` |
| Persisted session index | `AgentModeViewModel.sessionIndex` / `AgentWorkspaceSessionIndexStore` | `AgentModeRemoteSessionQueryService` |
| Parent/child relationships | `AgentSessionIndexEntry.parentSessionID` | snapshot builder child projection |
| Context-safe interaction state | `TabSession.pendingAskUser`, `pendingUserInputRequest`, `pendingMCPElicitationRequest`, and `pendingApproval` | `RemoteInteractionSummary` with no answer data |
| Window reuse | `WindowStatesManager.findWindowState(showing:)` | activation result |

`RemoteSnapshotBuilder` is intentionally fed only value-type records. This
keeps path sanitization, run-state normalization, interaction redaction, and
parent/child projection testable without constructing a provider process or a
serialized MCP request. `RemoteSnapshotProjectionTests` provides the fixture
coverage for live, waiting, failed, completed, and child sessions, including a
closed saved workspace.

The current gateway aggregates the saved workspace catalogs and session indexes
from all available desktop windows, exposes the paired snapshot/event/read
surfaces above, and returns `snapshot_required` when a requested cursor is older
than the bounded replay buffer. Built-in and custom workflows are projected
  from `AgentWorkflowStore`; selected workflow starts use the desktop template
  without sending workflow contents to the phone. Launch-at-login and active-run
  sleep prevention are wired into Remote availability settings. Notification
  registration, envelope encryption, attention categories, deep-link routing,
  network monitoring, and gateway diagnostics are implemented; deploying a
provider-backed relay URL remains environment configuration rather than a
desktop runtime dependency.

The desktop gateway remains responsible for its own threat model, residual risks,
and release gates. Companion applications maintain their security documentation
and release process independently; they are wire-compatible peers, not build-time
dependencies.

## Upstream compatibility maintenance

The October 7, 2026 integration incorporates upstream
`2ee1a27a58c64cf9a7fcd10c513333e001148d26` while preserving the standalone
Remote Gateway and Iroh transport. Remote session metadata belongs to the current
`AgentTabSession` authority. Model configuration retains upstream's workspace and
inactive-run admission checks, and successful starts settle provisional session
claims through `mcpAcceptSessionTarget`.

Remote pending interactions are projected from Agent Mode's canonical
`mcpPendingInteraction` surface, including permission and worktree approvals.
The optional `responseUnavailableReason` wire field directs hook trust,
unsupported approval choices, and multipart requests to the Mac. The gateway
also rejects responses to these requests, including from older mobile clients.
The protocol remains version 1; legacy payloads omit this optional field.

Validation for this integration: the desktop product build, MCP product build,
93 focused Remote/persistence tests, and repository Swift lint passed. The mobile
peer passed 62 iOS Simulator tests, 34 protocol tests, and 3 relay tests. The
mobile repository's `Scripts/check-desktop-compatibility.py` checks vendored Swift
sources and JSON fixtures against the tested desktop revision. Real paired-device
acceptance and release packaging are separate, unperformed checks.

The window catalog owns one lazy Remote Gateway, which owns its pairing and
availability services. Settings observes those same instances. The Remote targets
and direct imports are registered in the upstream module catalog; architecture
ratchet limits remain unchanged. Gateway/security/mutation and producer/projection
test classes retain their suite names in two app-test files.
