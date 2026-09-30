# Figma MCP connection

RepoPrompt CE provides one app-wide, nonsecret Figma MCP definition under
**Settings → MCP Integrations**. Its provider rows are independent routes over
that definition; they are not separate persisted integrations and cannot borrow
one another's authentication state.

Login initiation, structured proof, credential revocation, and Agent Mode
runtime binding are separate capabilities.

## Current production capability matrix

| Provider | Login | Structured proof | Revocation | Runtime binding |
| --- | --- | --- | --- | --- |
| Codex CLI | Codex-managed | Codex-managed | Codex-managed | Codex-managed |
| Claude Code CLI | Verified | Verified | Verified | Unverified |
| OpenCode CLI | Unsupported | Unsupported | Unsupported | Unsupported |
| Cursor CLI | Unverified | Unverified | Unverified | Unverified |
| Grok Build | Unsupported | Unsupported | Unsupported | Unsupported |
| Google Antigravity | Unsupported | Unsupported | Unsupported | Unsupported |
| Devin CLI | Unverified | Unverified | Unverified | Unverified |

The Settings rows use this order: Codex CLI, Claude Code CLI, OpenCode CLI,
Cursor CLI, Grok Build, Google Antigravity, and Devin CLI.

Claude-compatible backends—including CC Zai, CC Moonshot/Kimi, and CC Custom—
share the Claude Code Figma integration path rather than creating independent
Figma identities. Sharing that path does not transfer credentials, proof, or
runtime authority to another target or custom home.

## Provider behavior

- **Codex CLI** retains the RepoPrompt CE-managed lifecycle: configuration,
  authorization handoff, structured verification, cancellation, persistence,
  confirmed Sign Out, and runtime authority.
- **Claude Code CLI** owns its provider-native OAuth and credentials. RepoPrompt CE
  uses the reviewed Claude login, structured status, and target-specific
  revocation contracts. Runtime binding remains disabled.
- **Cursor CLI** has a version-fenced Settings login and temporary tool-surface
  observation. That observation is memory-only, expires, and cannot authorize
  Agent Mode runtime access or become structured proof.
- **OpenCode CLI** is currently unsupported. Generic MCP support and dormant
  provider-local code do not establish Figma client eligibility or proof.
- **Grok Build** is currently unsupported.
- **Google Antigravity** is currently unsupported for this remote endpoint. Its
  local desktop Figma route is a separate integration.
- **Devin CLI** remains fail-closed and actionless. Devin can own native MCP
  configuration and OAuth, but RepoPrompt CE cannot obtain structured Figma proof,
  revoke credentials, or grant runtime authority from human-readable CLI state.

## Row states and proof

**Connected** requires fresh, structured, provider-bound Figma proof for the
exact provider and target. Configuration-file presence, browser launch,
successful process exit, model connectivity, approval IDs, API keys,
human-readable output, or another provider's proof do not qualify.

**Authorizing** and **Connecting** describe only the owning provider's current
attempt. Cancellation, timeout, stale generations, and replaced operations fail
closed. Unsupported rows are actionless and are never probed.

Provider Sign Out is shown only when current proof and a reviewed scoped
revocation capability both exist. Generic provider logout is not Figma Sign Out.

## Persistence, runtime, and privacy

The Settings schema remains version 6. RepoPrompt CE persists only the nonsecret
Figma definition. It does not persist provider OAuth attempts, process IDs,
authorization URLs, callback or PKCE values, proof snapshots, credential
references, tokens, account identity, provider configuration, or runtime leases.

Runtime access additionally requires a verified provider-specific binding
contract. Settings connectivity never grants runtime authority automatically.
Unsupported, unverified, stale, cancelled, disabled, and unauthenticated states
return no lease.

RepoPrompt CE MCP Server and its exposed **Tools** remain independent of this Figma
integration. See [`architecture/external-mcp.md`](architecture/external-mcp.md)
for ownership and capability boundaries.
