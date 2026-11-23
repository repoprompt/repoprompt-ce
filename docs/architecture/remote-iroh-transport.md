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

Iroh pairing requires a live five-minute single-use QR secret, the expected Mac endpoint ID, and equality between the request's client endpoint ID and the peer authenticated by QUIC. Established RPCs are rejected before routing unless endpoint ID, device ID, bearer, and expiry match the one-device record. The router repeats that authorization check on every request.

The QR includes the Mac's Iroh address and a short-lived secret. Endpoint
identity and the bearer credential are verified on every connection.
Replacing an endpoint identity requires pairing again.

## Framing and recovery

Application DTOs remain protocol v1 JSON models inside `RemoteWireFrame` wire version 1. RPCs and event polls use bounded QUIC bidirectional streams. The mobile client repeats `event_subscribe` as a cursor-based bounded poll: the server returns one ordered replay frame or heartbeat and closes that request stream. Stale cursors return `snapshot_required`, forcing an authoritative snapshot before polling resumes. This is intentionally not advertised as a long-lived server-push stream.

Client connection attempts are staged: private/link-local direct addresses, all direct addresses with relay disabled, then relay-enabled. The authenticated Iroh path summary is surfaced as local direct, internet direct, relay, or unknown.

## Lifecycle and rollback

The endpoint runs only while the existing Remote gateway is enabled. App termination calls the same controller `stop()` path for both adapters. The phone closes RPC/event tasks in the background and starts a new generation with an authoritative snapshot when active; no background mode, push requirement, helper, RepoPrompt account, or cloud-owned state is introduced.
