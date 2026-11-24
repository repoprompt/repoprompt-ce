# Remote Iroh transport

The macOS Remote Gateway uses Iroh for paired mobile access. The Mac owns
gateway lifecycle, session state, permissions, and command execution.

## Boundaries

- `RemoteGatewayController` owns enablement, startup/shutdown, QR state, event production, and diagnostics.
- `RemoteGatewayRequestRouter` is the only application router. The adapter uses the snapshot/read/control services, authority mapping, transcript paging, replay buffer, and `RemoteErrorResponse` vocabulary.
- `RemoteIrohGatewayAdapter` owns the Swift side of the Rust endpoint, authenticated hello/pairing preflight, framed RPC/event serialization, and connection/path diagnostics.
- `RepoPromptIrohTransport` owns Iroh, QUIC streams, four-byte bounded framing, staged connection policy, deadlines, and cryptographically authenticated peer endpoint IDs. It does not persist identity or application data.

## Identity and pairing

Swift Keychain stores a separate 32-byte Iroh endpoint secret and passes it to Rust only when starting the endpoint. The desktop instance ID, bearer credential, and Iroh endpoint identity have separate purposes.

The QR advertises `requiresPairingConfirmation` and includes a five-minute
single-use secret, desktop instance ID, and pinned Mac Iroh endpoint. The
phone saves its attempt ID and endpoint binding before sending
`pairing_prepare`. The Mac validates the QR and both endpoint IDs and writes
the provisional credential and QR redemption as one Keychain update.

A repeated prepare from the same endpoint, attempt ID, and QR secret returns
the same credential during the pending window. The phone saves that credential
and attempt ID in Keychain before sending `pairing_confirm`. The Mac promotes
the record only after checking the provisional bearer, the attempt ID, the
device ID, and the authenticated peer. A repeated confirmation returns the same
`pairing_confirmed` acknowledgment after either app restarts, without extending
the lifetime. Pending credentials authorize confirmation only.

An expired or abandoned attempt can be replaced from Mac Settings. Existing
saved credentials and their usual authorization rules remain supported. New
pairings require updated builds on both sides.

## Framing and recovery

Application DTOs remain protocol v1 JSON models inside `RemoteWireFrame` wire version 1. RPCs and event polls use bounded QUIC bidirectional streams. The mobile client repeats `event_subscribe` as a cursor-based bounded poll: the server returns one ordered replay frame or heartbeat and closes that request stream. Stale cursors return `snapshot_required`, forcing an authoritative snapshot before polling resumes. This is intentionally not advertised as a long-lived server-push stream.

The phone starts a single relay-capable dial with Iroh discovery and direct
routes available immediately. Successful authentication can refresh the phone's
cached route hints for the pinned Mac identity.

The authenticated hello establishes an application session when the phone
supports first-sync confirmation. The first successful snapshot includes a
server-generated sync ticket. The phone decodes the snapshot and echoes the
ticket in `sync_confirm`. The Mac shows Connected once it validates that
ticket for the current session. The status expires after 25 seconds without
authenticated application activity. An earlier client can use its existing
credential. Settings shows Phone active for this connection and prompts the
user to update the phone to confirm sync.

The phone supervises its connection and event poll with one retry task.
Foregrounding or returning online restarts recovery promptly, and a failed
dial backs off with jitter before retrying. Cached data remains visible
while offline. Mutating commands are never automatically replayed.

## Lifecycle and rollback

The endpoint runs only while the existing Remote gateway is enabled. App termination calls the same controller `stop()` path for both adapters. The phone closes RPC/event tasks in the background and starts a new generation with an authoritative snapshot when active; no background mode, push requirement, helper, RepoPrompt account, or cloud-owned state is introduced.
