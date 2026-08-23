# Private-pilot security and access

## Supported network topologies

Exactly one browser topology is allowed:

1. **Direct TLS** — the portal shares the TLS listener. `REPOPROMPT_PORTAL_PORT` and `REPOPROMPT_PUBLIC_ORIGIN` are unset. Every `Forwarded`, `X-Forwarded-*`, and `X-Real-IP` header is rejected.
2. **Trusted proxy** — the plaintext portal backend binds only to loopback. Set `REPOPROMPT_PORTAL_PORT`, an HTTPS `REPOPROMPT_PUBLIC_ORIGIN`, and explicit `REPOPROMPT_TRUSTED_PROXY_CIDRS`. The immediate peer must match the CIDR set and must send one `X-Forwarded-For`, `X-Forwarded-Proto: https`, and `X-Forwarded-Host` matching the public origin. Multi-hop or ambiguous forwarding is rejected.

The internal API remains TLS. A browser portal cannot share a client-certificate-required listener; use the trusted-proxy topology when internal mTLS is enabled. Plaintext non-loopback portal binding is unsupported.

## First-run setup

On an empty V9 store the server issues a single-use setup token to the owner-only `operator-setup-token` file in the configured state directory with mode `0600`. Neither the token nor its path is emitted in structured logs. The portal requires that token for every first-run setup, including loopback and trusted-proxy requests; there is no tokenless pilot exception. Account creation, token consumption, initial-session creation, throttle clearing, and their success audit records commit in one database transaction. The owner-only token file is deleted before the successful onboarding response is returned.

## Passwords and sessions

- Password hashes use the repository's durable salted password-hashing contract; plaintext is never stored or logged.
- Browser sessions are 12 hours, represented by a random bearer token whose SHA-256 digest is stored.
- Session metadata, last-seen time, revocation, and reason are durable across restart.
- Online password change verifies the old password and atomically revokes all sessions, writes the new hash, creates one replacement session, and audits the outcome.
- Portal “Revoke Other Sessions” preserves the current browser. Offline `operator revoke-all-sessions` revokes every session.
- There is no online reset endpoint. Offline reset requires the namespace maintenance lease and reads the new password from a file descriptor, never an argument.

Examples:

```bash
printf '%s\n' "$NEW_PASSWORD" | RepoPromptServer operator reset-password --database /var/lib/repoprompt/state/repoprompt.sqlite --password-fd 0
RepoPromptServer operator revoke-all-sessions --database /var/lib/repoprompt/state/repoprompt.sqlite
RepoPromptServer operator issue-setup-token --database /var/lib/repoprompt/state/repoprompt.sqlite --output /secure/operator-setup-token
```

Do not place passwords in shell history or environment variables. Prefer a secret manager writing an owner-only pipe or file descriptor.

## Throttling and audit

Setup, login, and offline-reset attempts are reserved atomically in durable buckets keyed by client and username digests before secret verification. Five attempts in a 60-second window block the bucket through the end of that window; ten consecutive failures impose a 15-minute block. Buckets survive restart. Successful setup/login clears the matching bucket; successful offline reset preserves its attempt window so repeated maintenance resets cannot bypass the limit.

The V9 security audit contains operation, outcome, actor label, channel, keyed client digest, correlation ID, bounded detail code, and timestamp. It must never contain passwords, tokens, credential paths, forwarded raw addresses, or provider credentials.
