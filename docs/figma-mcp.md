# Figma MCP connection

RepoPrompt CE provides one app-wide, nonsecret Figma MCP definition under
**Settings → MCP Integrations → Figma**. Its provider rows are independent routes
over that definition; they are not separate persisted integrations and cannot
borrow one another's authentication state.

Login initiation, structured proof, credential revocation, and Agent Mode
runtime binding are separate capabilities.

## Remote MCP scope and usage

This integration uses Figma's remote MCP server at `https://mcp.figma.com/mcp`.
It does not configure or require the separate Figma Desktop MCP server.

1. Connect Figma for your CLI provider below the usage guide in Settings.
2. Complete the Figma authorization flow.
3. Open the Figma Design file you want to work with.
4. Copy the link to the relevant file, frame, or layer and give it to the agent
   in RepoPrompt CE.
5. Ask the agent to inspect, explain, or implement the referenced design.

Figma MCP is available on all Figma plans. Dev and Full seats on paid plans have
higher MCP usage limits; other seat types may be more limited. See Figma's
[current access guidance](https://developers.figma.com/docs/figma-mcp-server/rate-limits-access/)
for current limits and supported clients. If tools are unavailable after
connecting, reconnect Figma or restart your CLI provider.

These usage steps do not override the provider-specific runtime restrictions
below: only Codex currently has a RepoPrompt CE-managed runtime route.

## Current production capability matrix

| Provider | Login | Structured proof | Revocation | Runtime binding |
| --- | --- | --- | --- | --- |
| Codex CLI | Codex-managed | Codex-managed | Codex-managed | Codex-managed |
| Claude Code CLI | Verified | Verified | Verified | Unverified |
| OpenCode CLI | Unsupported | Unsupported | Unsupported | Unsupported |
| Cursor CLI | Unverified | Unverified | Unverified | Unverified |
| Grok Build CLI | Unsupported | Unsupported | Unsupported | Unsupported |
| Google Antigravity ACP | Unsupported | Unsupported | Unsupported | Unsupported |
| Devin CLI | Unverified | Unverified | Unverified | Unverified |

The matrix describes the four independent capability registrations, not the
user-facing connection status. Cursor's separate Settings observation does not
change its unverified proof or runtime capabilities. Devin's unverified
production registration is shown as **Currently unsupported**.

## Settings groups and CLI prerequisites

Provider cards are alphabetically ordered within three groups:

- Connected providers appear first, without a heading; the group is absent when
  empty. A connected route undergoing a connection check stays in this group.
- **Not Connected** is always shown and includes an **Open CLI Providers** button.
- **Currently Unsupported** contains providers whose Figma route is unavailable.

A provider must first be connected under **Settings → Agent Mode → CLI Providers**
before its Figma card can expand or start a new connection action. The card names
the required provider and shows the navigation instruction on a separate line.
CLI availability is a prerequisite, not Figma authentication evidence. Losing CLI
availability does not prove that Figma credentials were revoked; cancellation of
an existing login attempt remains available.

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
  observation. That observation is memory-only, expires after five minutes,
  triggers a fresh check on expiry, and cannot authorize Agent Mode runtime
  access or become structured proof. **Disconnect** disables the integration
  while retaining Cursor-owned configuration and OAuth credentials; it is not
  credential Sign Out.
- **OpenCode CLI** is currently unsupported. Generic MCP support and dormant
  provider-local code do not establish Figma client eligibility or proof.
- **Grok Build CLI** is currently unsupported.
- **Google Antigravity ACP** is currently unsupported for this remote endpoint. Its
  local desktop Figma route is a separate integration.
- **Devin CLI** is shown as **Currently unsupported** and remains fail-closed and
  actionless. Native MCP configuration or a successful login process does not
  establish the reviewed canonical-target login and structured proof contracts
  required by this integration.

## Row states and proof

For the Codex and Claude routes, **Connected** requires current, structured,
provider-bound Figma proof for the exact provider and target. Cursor may instead
show **Connected** based on its explicitly limited, unexpired Settings
observation. That observation can contribute to the aggregate badge, but neither
the row nor the aggregate badge grants runtime authority.

Configuration-file presence, browser launch, successful process exit, model
connectivity, approval IDs, API keys, human-readable output, or another provider's
proof do not establish structured Figma authentication.

**Authorizing** and **Connecting** describe only the owning provider's current
attempt. Cancellation, timeout, stale generations, and replaced operations fail
closed. Unsupported rows are actionless and are never probed.

Provider Sign Out is shown only when current proof and a reviewed scoped
revocation capability both exist. Generic provider logout is not Figma Sign Out.

## Persistence, runtime, and privacy

The global Settings document persists the nonsecret Figma definition and its
activation state, with feature-aware schema handling. It does not persist
provider OAuth attempts, process IDs, authorization URLs, callback or PKCE
values, proof snapshots, credential
references, tokens, account identity, provider configuration, Cursor observations,
or runtime leases. Provider-owned credentials remain with the respective CLI.
Disabling or removing the saved definition does not itself revoke credentials.

Runtime access additionally requires a verified provider-specific binding
contract. Settings connectivity never grants runtime authority automatically.
Unsupported, unverified, stale, cancelled, disabled, and unauthenticated states
return no lease.

RepoPrompt CE MCP Server and its exposed **Tools** remain independent of this Figma
integration. See [`architecture/external-mcp.md`](architecture/external-mcp.md)
for ownership and capability boundaries.
