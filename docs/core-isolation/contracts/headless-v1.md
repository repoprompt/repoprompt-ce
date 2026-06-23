# Standalone Headless v1 Contract

**Frozen:** 2026-06-21
**Reviewed implementation:** `21b5603f5a333454aee899dd39ff38d860a5b716`
**Security hardening reference:** `487cd71d892dbc3104689cc42fdb39f6c038e8fb`
**Post-close B1 filesystem admission hardening:** 2026-06-22
**Version policy:** [ADR-002](../decisions/ADR-002-headless-version-and-transport-identity.md)

This is the Phase 8 acceptance oracle. Headless v1 is a fenced parallel runtime;
it may consume neutral values and platform adapters but must not instantiate
`WorkspaceSessionController`, `RepoPromptCoreSession`,
`WorkspaceFileContextStore`, app registries, or the app bootstrap proxy.

## Identity and installation

| Item | Frozen value |
| --- | --- |
| Product / binary | `repoprompt-headless` |
| Swift target | `RepoPromptHeadless` |
| Display/server name | `RepoPrompt Headless` |
| Protocol | `2024-11-05` |
| Release command | `/usr/local/bin/rpce-headless` |
| Debug command | `/usr/local/bin/rpce-headless-debug` |
| User release link | `~/Library/Application Support/RepoPrompt CE/repoprompt_headless` |
| User debug link | `~/Library/Application Support/RepoPrompt CE/repoprompt_headless_debug` |
| Staged release binary | `~/Library/Application Support/RepoPrompt CE/HeadlessTools/Release/repoprompt-headless` |
| Staged debug binary | `~/Library/Application Support/RepoPrompt CE/HeadlessTools/Debug/repoprompt-headless` |
| Secure-storage service | `com.pvncher.repoprompt.ce.headless.keychain` |

Phase 8 derives marketing/build versions from current release metadata. The
historical `1.0.10 (build 11)` constants are not reconstructed.

## State and permissions

Default root: `~/Library/Application Support/RepoPrompt CE/Headless/v1`.
The reviewed snapshot's unversioned `.../Headless` root is archaeology; ADR-002
supersedes it to satisfy the execution plan's versioned-state requirement. An
explicit state-directory override supplies the complete version-specific root.

Contents:

- `config.json` and `config.lock`;
- `Workspaces/`;
- `Exports/`.

All state directories are `0700`. State files and locks are `0600`, regular
files, owned by the effective UID, and have a single hard link. State-path
symlinks are rejected and nonconforming permissions are corrected before use.
Headless never reads app workspace state, app Keychain items, app sockets, or app
defaults.

External export is disabled by default. When explicitly enabled, newly created
directories are `0700` and files `0600`. Existing external directories keep
their owner/mode; the destination leaf must be a regular non-symlink file.
Uninstall removes only installed links/staged binaries by default and leaves the
private state root unless the user explicitly requests state deletion.

## Direct NDJSON transport

- stdin/stdout carry one compact JSON-RPC 2.0 object per LF-delimited frame.
- Every response ends with exactly one `\n`.
- CRLF is accepted by stripping a trailing `\r`; empty lines are ignored.
- Maximum input frame is 1,048,576 bytes.
- An oversized frame emits one `-32700` parse error, discards through the next
  LF, and then resumes.
- Malformed JSON emits `-32700`. A valid non-object JSON value emits `-32600`.
- A non-whitespace unterminated EOF tail emits `-32700` with
  `Incomplete newline-delimited JSON-RPC frame at EOF.`; a whitespace-only tail
  is ignored.
- There is no separately frozen encoded response-size or error-message-size cap.
  Tool-specific output bounds below are mandatory.
- stdout contains protocol frames only; logs go to stderr or private artifacts.

## Lifecycle, concurrency, cancellation

- `initialize` returns the frozen protocol/display identity, tools capability,
  configured-root count, state directory, and safe-profile flag.
- `notifications/initialized` has no response.
- `notifications/cancelled` uses `params.requestId`. A matching task returns
  `-32800` / `Request cancelled.`.
- `get_file_tree`, `get_code_structure`, `read_file`, and `file_search` may run
  concurrently. Other tools are serialized.
- One Headless-owned controller is shared by every server in the process and
  bounds aggregate filesystem work with weighted capacity `4`. `file_search`
  has weight `4`; `get_file_tree`, `get_code_structure`, and `read_file` each
  have weight `1`.
- Weighted waiters are admitted in strict FIFO order without bypass. Invalid
  weights fail. Cancelling a queued request removes its waiter without consuming
  capacity. If cancellation races with handoff, the granted lease is released
  before tool execution. Every granted lease releases its weight exactly once.
- Admission wraps both registered and test-override execution for the four
  filesystem tools. Ping, initialize/shutdown/notifications, tool listing, and
  serialized workspace/selection/prompt mutations remain outside this gate.
- `shutdown` returns JSON `null` and changes the server to shutdown state.
- Requests after shutdown return `-32600` /
  `Server has shut down and no longer accepts requests.`.
- The process exits only on a later `exit` notification. `exit` before shutdown
  is ignored.
- `exit`, `notifications/initialized`, and `notifications/cancelled` carrying
  request IDs return `-32600`.
- EOF cancels active requests, waits for pending responses, then terminates.
- Duplicate or invalid request IDs fail with `-32600`. Unexpected tool failures
  use `-32603`; tool-level deny/unknown results remain MCP `isError: true`.

## Safe tool profile

Enabled:

1. `bind_context`
2. `manage_workspaces`
3. `manage_selection`
4. `workspace_context`
5. `get_file_tree`
6. `get_code_structure`
7. `read_file`
8. `file_search`
9. `prompt`

Default capabilities are all false: `write_files`, `vcs_write`,
`launch_agents`, and `export_outside_state_directory`.

Explicitly denied:

| Capability | Tool names |
| --- | --- |
| `writeFiles` | `file_actions`, `apply_edits` |
| `vcsWrite` | `git`, `manage_worktree` |
| `launchAgents` | `agent_run`, `agent_explore`, `agent_manage` |
| `appOnly` | `ask_oracle`, `oracle_send`, `oracle_chat_log`, `context_builder`, `ask_user`, `share_thoughts`, `set_status`, `wait_for_next_user_instruction`, `app_settings` |

Denied message:

> Tool '<name>' is not available in RepoPrompt Headless v1. Required capability:
> <capability>. The standalone profile fails closed until both permission wiring
> and a registered implementation exist.

Unknown message:

> Unsupported headless tool: <name>. Use tools/list to see the enabled safe
> profile.

## Root and file-access security

- Configured roots are explicit, absolute, existing directories; `/` is rejected.
- Both lexical and resolved paths are stored. A changed resolved target makes the
  root unavailable until it is removed/re-added.
- Candidates must be component-contained by both lexical and resolved roots.
- Longest matching root wins for absolute paths.
- Ambiguous relative paths fail and require a `RootName/` prefix.
- Descriptor-relative access uses `openat`, `O_NOFOLLOW`, and component
  validation.
- Empty, `.`, `..`, NUL, symlink, device, and non-file/non-directory
  components/leaves fail closed.
- Root opens also use `O_NOFOLLOW`. Symlink traversal and replacement races are
  rejected.

## Resource bounds

The weighted process-wide bound above is additive to, and does not replace or
pool, these unchanged per-request budgets:

| Area | Bound |
| --- | --- |
| File read | 2 MiB |
| Tree output | 1,500 lines |
| Tree default depth | 4; full-mode default 12 |
| Directory expansion | 1,000 entries/files |
| Search results | default 50; clamp 1…1,000 |
| Search context | 0…5 lines |
| Search catalog | 20,000 records |
| Search content files | 2,048 |
| Search content bytes | 64 MiB |
| Matcher work | 32 MiB |
| Regex subject | 64 KiB |
| Search elapsed | 3,000 ms |

## Required Phase 8 negative evidence

Subprocess fixtures must prove malformed/oversized input recovery, incomplete
EOF, cancellation, duplicate IDs, post-shutdown rejection, root escape and
symlink denial, owner-only state, isolated HOME/state/secret namespaces, absent
app socket use, denied tools, unknown tools, and clean response draining. Direct
stdio and app-proxy package/smoke lanes remain separate.
