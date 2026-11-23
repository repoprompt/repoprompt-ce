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

Companion clients build their protocol implementations independently. The
shared Swift sources and JSON fixtures define the versioned Iroh wire contract.

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

Iroh frames cover pairing, authentication, snapshots, event replay,
workspace and session lists, agent and workflow catalogs, diagnostics,
history, transcripts, attachments, context building, and chat commands.

History requests can be scoped to a workspace. The response echoes the
workspace and includes an `olderCursor` for the next page when needed.

The gateway emits coarse workspace, session, run-state, interaction, and
authorization/catalog events from the same authoritative projection used for
snapshots. Transcript rows are paged separately so the fleet stream stays
bounded. Tool arguments/results, reasoning, file/worktree key paths, process
metadata, and approval-adjacent details are only returned when the client
explicitly requests details; common credential fields are redacted before
returning them.

## Authorization

The desktop remains the authorization boundary. `RemoteAuthorizationState`
models the default device authority. Mobile controls may be hidden or disabled for usability, but the desktop
must evaluate the required authority again when it executes each command.

The levels are intentionally ordered:

| Level | Meaning |
| --- | --- |
| `observe` | Read state, transcripts, and history |
| `respond` | Answer supported questions and accept, decline, or cancel one-time approvals |
| `control` | Start, follow up, steer, cancel, resume, configure a chat, and run Context Builder |
| `danger` | Also change desktop-wide Codex tool settings |

Worktree merges, permission grants, and persistent or amended approvals require review on the Mac, even at `danger`.

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
  ├── authenticated Iroh read and command streams
  └── resumable event stream and replay buffer
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

Enabling Remote starts the Iroh gateway. Generate a pairing code explicitly on
an unpaired Mac. Codes are short-lived and single-use. The Mac stores the Iroh endpoint secret and the paired-device
credential in its signed secure-storage domain. Unpairing revokes the stored
credential before clearing the live connection.

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
validating Iroh identity and paired-credential persistence. Keep the
identity and team in local build settings. Prefer the
applicable `make dev-*` targets (`make dev-test`, `make dev-smoke`, and so on)
to uncoordinated commands. Use `rpce-cli-debug` against the running CE debug app
to select a known workspace, create recognizable non-destructive session state,
and record the CLI start/wait result that the phone observes.

Run acceptance in sequence: pair Simulator through the Debug manual field with
the copied short-lived `rpremote://pair?...` value, then test a registered
physical iPhone by camera on the same non-isolated LAN. On the device, verify
Iroh reconnect after a network change and a CE restart. Only one device credential is active: forget the
pairing in iOS and revoke it in CE before re-pairing, and confirm the old
credential is rejected.

The gateway currently rejects push registration with `notifications_unavailable`
and does not deliver previously registered notifications. Re-enabling delivery
requires Mac-owned relay selection, including redirect policy. Simulator,
physical-device, Iroh path, and Keychain-persistence acceptance remain
unverified by these documentation steps.

Release acceptance also requires an organization-controlled Iroh artifact
with provenance tying the archive checksum to reviewed source and Cargo.lock,
and a reviewed inventory and license texts for the linked dependencies in the
app's Legal resources. The SwiftPM checksum check alone is not that evidence.

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
5. Future: register iOS notification tokens and forward only encrypted, sanitized
   envelopes through a Mac-owned relay. The phone reconnects to the desktop for
   authoritative state.

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
