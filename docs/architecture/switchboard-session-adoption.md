# Switchboard session account adoption

This interface is limited to explicitly paired root Codex Agent Mode sessions.
It is not exposed through generic MCP. All examples below are synthetic. Real
pairing envelopes, capabilities and grants must never be put in logs, MCP,
transcripts or reports. This is an implementation contract, not a shipped claim.

## Transport and pairing authority

Switchboard owns a private Unix stream socket. RepoPrompt connects directly.
One request and one response are LF-terminated UTF-8 JSON objects per connection;
at most 65,536 bytes including LF. After writing its request frame the client
must `shutdown(SHUT_WR)`. The server reads EOF before any mutation, preventing
delayed trailing bytes from bypassing strict framing. The server closes after
its response; the client requires EOF and rejects bytes after the response LF.
Reject trailing data, unknown fields, invalid
types, duplicate JSON keys, invalid UTF-8 and malformed frames. Use a 3-second
whole-exchange deadline (including connect/read/write); no unbounded reads.

The user imports a **session-specific** pairing envelope into the RepoPrompt
session UI. No discovery file or generic MCP command grants consent. Envelope:

```json
{"v":1,"socket_path":"/private/tmp/example-private-bridge/session.sock","peer_pid":12345,"peer_start":{"seconds":1788710000,"microseconds":123456},"capability":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","expires_at":1788710300}
```

The example capability is deliberately invalid for real use. Production uses
32 cryptographically random bytes encoded as canonical base64. Envelope expires
within five minutes and applies to one user-created consent ID/session only.
Expiry bounds initial registration only; an established consent remains valid
until revocation or either pinned process/server instance is lost. The capability
remains in app memory; no preference or transcript persistence.
Socket and parent must be owned by the current UID, non-symlinks and private
(parent mode 0700, socket mode 0600). Reject path-component symlinks. On every
connection require kernel peer UID/PID and the process birth stamp from pairing;
never trust a JSON PID or process display name. Validate before sending secrets.
Switchboard must reciprocally pin the connected RepoPrompt process and require
the capability before accessing grants. The authenticated register binds the
capability to the exact consent/session IDs; registration cannot overwrite an
existing binding. Consent and server instance loss require pairing again.
Same-binding registration with a new request ID is idempotent. Replayed request
IDs fail with `invalid_request`; retries always allocate a new request ID.

## Common request and response

Every request has exactly these common keys, plus the operation-specific keys
below. All UUID fields use canonical lowercase hyphenated UUID strings; uppercase
or alternate spellings are rejected. controller_generation is a host-created
UUID pinned to one actual controller instance. The native thread ID is opaque,
nonempty, bounded text; do not parse it as a UUID.

```json
{"v":1,"id":"11111111-1111-1111-1111-111111111111","capability":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","op":"poll","consent_id":"22222222-2222-2222-2222-222222222222","session_id":"33333333-3333-3333-3333-333333333333","controller_generation":"44444444-4444-4444-4444-444444444444","thread_id":"synthetic-thread-a","last_seen_revision":0}
```

Every response has exactly `v`, `id`, and either `result` or `error`. `id` must
match the request. Error is exactly `{"code":"<stable-code>"}`; no exception
text, headers, paths, tokens, provider payloads or arbitrary message strings.
Codes: `invalid_request`, `unauthorized`, `expired`, `revoked`, `stale_revision`,
`unavailable`, `grant_unavailable`, `identity_mismatch`.

The server rejects unknown operations. Integers must be JSON integers, not
booleans or fractional numbers. Revisions are positive monotonically increasing
integers per consent, bounded by 2^53-1; zero denotes no selection seen yet.
Only a newer explicitly selected revision can initiate adoption. Replaying an
applied or failed revision never installs credentials a second time.

## Operations

| Operation | Additional request fields | Result |
|---|---|---|
| `register` | none; `thread_id` may be null before native bind | `{"registered":true}` |
| `poll` | `last_seen_revision`: nonnegative integer | `{"selection":null}` or selection below |
| `refresh` | `adoption_id`, `expected_revision`, `previous_account_id` | `{"selection":<selection>}` with the **same** adoption/revision/account and a renewed grant |
| `status` | `adoption_id`, `expected_revision`, `state`, `reason` | `{"accepted":true}` |
| `revoke` | none | `{"revoked":true}` |

All requests include thread_id. `register` may have a null thread ID. `revoke`
may also carry null, but only to revoke the exact already-registered null-thread
consent/session/controller binding. All other operations require a bound native
ID. This permits cancellation cleanup before native startup/binding completes.
Before native thread creation the server may retain the registration but must
not advertise a switchable session. Binding the first exact native ID uses
another `register` with the same consent/session/controller IDs; only a
null-to-nonempty transition is allowed. A different nonempty native ID or
controller generation requires new pairing/consent. Grants must not be sent
before the exact native identity is bound. Initial managed HTTP transport setup
therefore creates/binds a thread with no provider turn before the first poll.

A `poll` result selection has exactly:

```json
{"selection":{"selection_id":"55555555-5555-5555-5555-555555555555","adoption_id":"66666666-6666-6666-6666-666666666666","selection_revision":1,"expires_at":1788710400,"account_id":"synthetic-account-b","email":"b@example.invalid","plan":"plus","access_token":"SYNTHETIC-NOT-A-TOKEN"}}
```

The bridge validates canonical account identity before releasing this grant.
`email` and `plan` may be null. Access token is nonempty bounded secret text.
Receiver compares scope, revision, expiry, consent and controller/native thread
identity again after every await, before mutation and before publishing status.
The access token is sent only to that controller's `account/login/start`; it is
never written to auth.json, UserDefaults, a transcript or a generic tool.

`expected_revision` on refresh refers to the **applied** revision. A newer queued
selection must not redirect refresh to that newer account. Refresh returns the
same selection_id, adoption_id, revision and account_id with renewed grant data.
An unrecognized or retired applied revision fails. `previous_account_id` is
required and must match; a null/unknown runtime account cannot silently refresh.

Status is revision-scoped and cannot update a newer selection. Stale status is
acknowledged with `stale_revision` and cannot change UI/account ownership.
Before accepting `status(applying)`, Switchboard freshly validates destination
capacity and the exact canonical token, including after an arbitrarily long idle
wait. It rechecks consent and revision before transitioning or retiring the old
refresh identity. Admission can fail with `grant_unavailable`, `stale_revision`
or `unavailable`. RepoPrompt must await this acknowledgement while holding its
dispatch reservation and must not send native login when admission fails.
Allowed states: `waiting_idle`, `applying`, `applied_unverified`, `failed_unknown`,
`revoked`. Allowed reasons: `none`, `busy`, `pending_interaction`, `active_tools`,
`active_children`, `queued_dispatch`, `runtime_unavailable`, `unsupported_runtime`,
`transport_unverified`, `identity_changed`, `grant_expired`, `bridge_unavailable`,
`mutation_unconfirmed`, `revoked`.

`applied_unverified` means a verified canonical grant was explicitly installed,
the native login/account shape was consistent, the pinned managed HTTP runtime
and exact retained native thread were checked, and new work may proceed under
that proved transport policy. It does **not** claim that a subsequent real
provider request has been observed. UI text: “Account applied; next request
unverified.” Do not convert this into a green “runtime verified” state. Real
transport evidence belongs to a separate future receipt contract.

Revocation is local and immediate even if the bridge cannot acknowledge it.
In-flight operations recheck consent. If revocation races a dispatched login,
the account state is indeterminate and further provider dispatch remains blocked.
Revocation must not release an indeterminate backend back to ordinary managed
authentication or global login recovery.

## Runtime constraints

Only new backends explicitly launched under this policy qualify. The managed
provider ID is `switchboard-managed-http`, with name `Switchboard managed HTTP`,
base URL `https://chatgpt.com/backend-api/codex`, `wire_api="responses"`,
`requires_openai_auth=true`, and `supports_websockets=false`. Runtime config/read
must prove the effective definition, not merely launch intent. Route/auth/config
overrides are fail-closed. Existing unknown backends cannot be relabeled managed.
Launch also pins `cli_auth_credentials_store="ephemeral"` and
`features.goals=false`; effective configuration must confirm both. Autonomous
goal mutations are refused for this explicitly opted-in pilot, and the opt-in
UI must disclose this limitation. Ordinary sessions retain existing behavior.

Before mutation, reserve the controller against all new dispatch and idle
reaping, require authoritative idle plus no local/native tools, interactions,
queued work, recovery or active children, and pin exact thread/controller IDs.
Mutation uncertainty blocks further work; no logout, implicit retry or new-thread
fallback is allowed. Refresh ownership remains pinned to the applied grant.

## Reviewed runtime and recovery boundary

The reviewed runtime is exactly Codex **0.149.0** from the validated app bundle.
A future bundled version is ineligible until synthetic outgoing-request tests
again prove HTTP A→B switching on the same native thread, history retention,
ephemeral credential-store behavior, and disabled autonomous goals. Matching the
current bundle manifest alone is insufficient. WebSocket transport is explicitly
ineligible: changing account/read identity does not prove its cached transport
identity changed.

The backend starts with ephemeral credential storage and must report a null
initial account before thread creation. It does not load or overwrite shared
managed credentials. Managed launches suppress native/raw-event logging and
ambient provider, proxy, tracing and exporter overrides. Non-null native logging
or telemetry configuration is refused. Ordinary sessions are unaffected.

The loaded native thread set must be exactly the single owned root thread.
Additional loaded native threads refuse adoption even if they appear idle. This
pilot does not claim arbitrary subagent-heavy backends are switchable. Active or
unknown app-owned descendants, tools, queued work, interactions and recovery also
prevent admission.

Codex 0.149 cannot return includeTurns history for an unmaterialized new thread.
Metadata-only idle proof is allowed only when the app-server actor proves it
created a new thread and has never dispatched provider work. Resumed threads and
any backend that has dispatched work require full native history. There is no
catch-based fallback from a failed history read to weaker metadata evidence.

Only the nonsecret requiresSwitchboardPairing marker is persisted. A reopened
managed conversation cannot silently return to ordinary shared-account login.
Explicit re-pairing must retain its exact native thread. If a new managed backend
is needed for repair, it may resume that exact saved thread once; it may never
create a replacement thread as a recovery fallback. Pairing loss preserves
history and blocks future work with an actionable re-pair status.

Consent revocation is checked again at the final child-process write using a
synchronous revocable authorization. Main-actor checks alone are insufficient:
a revoke must also fence a login or refreshed-token response queued for native
actor execution. Pairing and grant data remain memory-only.
Privileged native writes use nonblocking pipe mode while holding this authority
lock. A partial write or unavailable pipe capacity fails closed and retires the
owned transport; revocation must not wait for a stalled child's pipe to drain.

## Validation status

Deterministic state, wire, transport-policy and recovery tests live under
Tests/RepoPromptTests/AgentMode/Codex. Runtime fixture provenance is documented
in their synthetic fixture sources; private filesystem paths are replaced.
Tests and synthetic outgoing transport probes do not constitute installed-app
validation. A visible candidate app launch requires explicit approval and
isolated bundle/storage paths; do not replace or restart an existing release as
part of headless validation.
