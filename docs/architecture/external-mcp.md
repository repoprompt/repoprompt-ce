# External MCP integration architecture

RepoPrompt CE has a provider-neutral external-MCP core and provider-specific
adapters. The core owns integration identity, capability decisions, runtime
leases, revisions, and fail-closed policy. Providers retain ownership of their
processes, OAuth flows, credentials, and provider-specific protocols.

## Figma ownership and capability axes

The app-wide Figma definition is nonsecret settings metadata. It is not an
authentication record and does not select a provider. Each production provider
registration makes independent decisions for four capabilities:

| Capability | Meaning |
| --- | --- |
| Login initiation | RepoPrompt may start the provider's reviewed login route |
| Proof | A registered structured Figma-specific result may make the row Connected |
| Revocation | A reviewed provider-specific Figma credential revocation route exists |
| Runtime binding | Current provider-bound proof may grant a Figma runtime lease |

Login support does not imply proof, revocation, or runtime binding. Configuration
presence, browser launch, CLI output, and successful process exit are not Figma
proof.

## Current production matrix

| Provider | Login | Proof | Revocation | Runtime binding |
| --- | --- | --- | --- | --- |
| Codex CLI | Codex-managed | Codex-managed | Codex-managed | Codex-managed |
| Claude Code CLI | Verified | Verified | Verified | Unverified |
| OpenCode CLI | Unsupported | Unsupported | Unsupported | Unsupported |
| Cursor CLI | Unverified | Unverified | Unverified | Unverified |
| Grok Build | Unsupported | Unsupported | Unsupported | Unsupported |
| Google Antigravity | Unsupported | Unsupported | Unsupported | Unsupported |
| Devin CLI | Unverified | Unverified | Unverified | Unverified |

Codex remains the sole RepoPrompt-managed Figma lifecycle. Claude Code owns its
verified login, structured provider-bound status, and target-specific revocation;
its runtime binding remains denied. Cursor retains a Settings-only login and
temporary tool-surface observation that cannot become neutral proof or runtime
authority. Devin has no reviewed canonical-target login or structured proof
contract, so its row is actionless and cannot authorize runtime access. OpenCode
is explicitly unsupported because the remote client and structured-proof gates
are not satisfied. Antigravity's local desktop Figma route is not this remote
endpoint, and Grok Build has no supported Figma route.

## Fixed provider rows

The Settings Figma card presents rows in this exact order:

1. **Codex CLI**
2. **Claude Code CLI**
3. **OpenCode CLI**
4. **Cursor CLI**
5. **Grok Build**
6. **Google Antigravity**
7. **Devin CLI**

Rows are keyed by provider and cannot promote one another. The aggregate badge
represents an operational, proof-backed route, not a login attempt. OpenCode,
Grok Build, and Google Antigravity are neutral **Currently unsupported** rows.
Devin remains fail-closed and actionless without verified Figma access.

All selectable `AgentProviderKind` cases map to these seven Figma runtime
families. CC Zai, CC Moonshot/Kimi, and CC Custom share the Claude Code Figma
integration path because they launch through the Claude-compatible runtime; they
do not receive separate Figma rows. This classification does not transfer a
credential context, structured proof, or runtime-binding authority to a variant
or custom home.

## Provider-process ownership and boundaries

For non-Codex routes, the provider owns browser launch, OAuth state, callback or
loopback handling, PKCE, code exchange, and credential storage. RepoPrompt does
not implement a second OAuth client, scrape authorization output, copy provider
credentials, or persist provider tokens.

A status service may use only the registered structured checker for the exact
provider, canonical target, credential context, capability revision, and
operation generation. A Sign Out action is absent unless proof and a reviewed,
target-specific revocation contract are both available. Generic provider logout
is not Figma Sign Out.

Runtime decisions repeat capability checks as defense in depth. Only current
provider-bound proof plus verified runtime-binding support can grant a fresh,
top-level lease. Unsupported, unverified, stale, cancelled, disabled, or
unauthenticated states return no lease. Managed child, provider-native child,
headless, cloud, discovery, and otherwise unsupported sessions remain denied by
default.

## Persistence and privacy

Settings persist only the nonsecret app-wide integration definition. OAuth
attempts, authorization URLs, callback values, PKCE material, access or refresh
tokens, provider configuration, account identity, temporary proof, and runtime
leases remain process-local or provider-owned.

## Evidence-gated future work

Cursor's Settings observation remains separate from neutral proof. Structured
Figma proof, scoped revocation, and runtime binding require independent review.

Devin remains unverified until its CLI exposes a stable, machine-readable,
provider-bound authentication contract. Do not infer access from `mcp list`,
`mcp get`, configuration presence, or login process success.

OpenCode remains unsupported until Figma remote-client eligibility and an exact,
versioned configuration and structured-proof contract are established. Dormant
provider-local code is not production authority.
