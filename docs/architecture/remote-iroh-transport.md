# Remote Iroh transport

RepoPrompt CE keeps the Mac as the lifecycle, state, authorization, and command authority. Remote access always retains the legacy pinned-HTTPS adapter; Iroh is an additional explicit opt-in transport and may be disabled without deleting the bearer, TLS identity, endpoint identity, or legacy pairing.

## Boundaries

- `RemoteGatewayController` owns enablement, startup/shutdown, QR state, event production, and diagnostics.
- `RemoteGatewayRequestRouter` is the only application router. Both adapters use the same snapshot/read/control services, authority mapping, transcript paging, replay buffer, and `RemoteErrorResponse` vocabulary.
- `RemoteLegacyHTTPSGatewayAdapter` owns TLS, bounded HTTP parsing, Bonjour, SSE serialization, and the authenticated bootstrap/bind migration routes.
- `RemoteIrohGatewayAdapter` owns the Swift side of the Rust endpoint, authenticated hello/pairing preflight, framed RPC/event serialization, and connection/path diagnostics.
- `RepoPromptIrohTransport` owns Iroh, QUIC streams, four-byte bounded framing, staged connection policy, deadlines, and cryptographically authenticated peer endpoint IDs. It does not persist identity or application data.

## Identity and pairing

Swift Keychain stores a separate 32-byte Iroh endpoint secret and passes it to Rust only when starting the endpoint. The existing desktop instance ID, TLS certificate, bearer credential, and Iroh identity remain distinct.

Iroh pairing requires a live five-minute single-use QR secret, the expected Mac endpoint ID, and equality between the request's client endpoint ID and the peer authenticated by QUIC. Established RPCs are rejected before routing unless endpoint ID, device ID, bearer, and expiry match the one-device record. The router repeats that authorization check on every request.

An Iroh QR embeds the pinned HTTPS fallback. An existing HTTPS pairing can add its endpoint binding only through the bearer-authenticated `/remote/v1/transport/bootstrap` and `/remote/v1/transport/bind` routes. Identity loss clears only the Iroh binding and requires that authenticated rebind.

## Framing and recovery

Application DTOs remain protocol v1 JSON models inside `RemoteWireFrame` wire version 1. Iroh does not tunnel HTTP or SSE. RPCs and event polls use bounded QUIC bidirectional streams. The mobile client repeats `event_subscribe` as a cursor-based bounded poll: the server returns one ordered replay frame or heartbeat and closes that request stream. Stale cursors return `snapshot_required`, forcing an authoritative snapshot before polling resumes. This is intentionally not advertised as a long-lived server-push stream.

Client connection attempts are staged: private/link-local direct addresses, all direct addresses with relay disabled, then relay-enabled. The authenticated Iroh path summary is surfaced as local direct, internet direct, relay, or unknown. HTTPS is attempted only after Iroh stages fail.

## Lifecycle and rollback

The endpoint runs only while the existing Remote gateway is enabled. App termination calls the same controller `stop()` path for both adapters. The phone closes RPC/event tasks in the background and starts a new generation with an authoritative snapshot when active; no background mode, push requirement, helper, RepoPrompt account, or cloud-owned state is introduced.

Disabling Iroh immediately returns runtime behavior to pinned HTTPS while preserving migration data for later use. Physical Wi-Fi/cellular and relay-path validation remains a release gate and must be reported separately from simulator evidence.
