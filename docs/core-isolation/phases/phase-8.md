# Phase 8 — Independently packaged standalone headless v1

**Implementation base:** `5f0dab77874a240b23cf3cc72d256c47c55c17b2`
**Committed checkpoint:** `8046078ffe59f4130dc38dbecbb31b3485c9f735`
**Execution date:** 2026-06-22
**Frozen contract:** [`../contracts/headless-v1.md`](../contracts/headless-v1.md)
**Identity decision:** [`../decisions/ADR-002-headless-version-and-transport-identity.md`](../decisions/ADR-002-headless-version-and-transport-identity.md)
**Historical implementation seed:** reviewed `21b5603f5a333454aee899dd39ff38d860a5b716`; current contracts override its stale version and unversioned state path.
**Disposition:** **GO — all Phase 8 close gates passed and were committed at `8046078f`**

Post-close publication hardening is tracked separately in
[`../publication-remediation-2026-06-22.md`](../publication-remediation-2026-06-22.md).
It does not rewrite this phase's execution history or begin Phase 9 convergence.

## Scope and non-goals

Phase 8 activates the reserved `repoprompt-headless` product as a direct NDJSON
stdio server with an exact nine-tool read-oriented profile. It owns a fenced root
registry, state store, selection/workspace/prompt transactions, tool registry,
request lifecycle, and descriptor-confined file access.

It does not instantiate `WorkspaceSessionController`, `RepoPromptCoreSession`,
`RepoPromptCoreHost`, `WorkspaceFileContextStore`, app runtime registries, window
routing, or the bootstrap proxy. `repoprompt-mcp`, app bundle packaging, app
sockets/state/secrets, Phase 7 routing identity, and visible app behavior remain
unchanged. Headless/Core convergence and compatibility cleanup remain Phase 9+.

## Frozen identities

| Surface | Phase 8 value |
| --- | --- |
| Product / target / binary | `repoprompt-headless` / `RepoPromptHeadless` / `repoprompt-headless` |
| Display / MCP protocol | `RepoPrompt Headless` / `2024-11-05` |
| State root | `~/Library/Application Support/RepoPrompt CE/Headless/v1` |
| Secret service | `com.pvncher.repoprompt.ce.headless.keychain` |
| Debug command | `/usr/local/bin/rpce-headless-debug` |
| Release command | `/usr/local/bin/rpce-headless` |
| Staged root | `~/Library/Application Support/RepoPrompt CE/HeadlessTools/{Debug,Release}` |
| Release metadata | `version.env`: `1.0.21 (build 22)` |

A state-directory override names the complete version root and must be absolute;
no current-working-directory fallback exists. Default resolution honors an
explicit isolated `HOME`.

## Runtime contract

- Input is compact JSON-RPC 2.0 NDJSON with CRLF normalization, ignored empty
  lines, a 1 MiB frame cap, one parse error per oversized frame, resynchronization
  at LF, and an exact incomplete-EOF parse error.
- stdout is serialized by the reviewed writer and contains protocol frames only
  while serving; diagnostics go to stderr.
- initialization gates tools; shutdown returns JSON `null`; exit terminates only
  after shutdown; post-shutdown requests fail exactly; EOF cancels and drains.
- request IDs are tracked until terminal delivery. Duplicate active IDs fail;
  cancellation returns `-32800`; unexpected failures return `-32603`.
- `get_file_tree`, `get_code_structure`, `read_file`, and `file_search` may run
  concurrently. All other tools serialize. Cancellation before commit changes
  nothing; cancellation after a committed result preserves success.

## Exact tool profile

Advertised in this order only:

1. `bind_context`
2. `manage_workspaces`
3. `manage_selection`
4. `workspace_context`
5. `get_file_tree`
6. `get_code_structure`
7. `read_file`
8. `file_search`
9. `prompt`

Write, VCS-write, agent-launch, and app-only tools use the frozen capability error.
Unknown tools use the frozen unsupported-tool error. Enabling persisted permission
booleans does not advertise or register a denied tool.

## Root, state, and export security

Configured roots must be explicit absolute existing directories and cannot be `/`.
Lexical and resolved identities are stored; drift makes the root unavailable until
remove/re-add. Absolute paths choose the longest root. Ambiguous relative paths
require `RootName/` qualification.

Filesystem leaves are reached through descriptor-relative component walks using
`openat`, `O_NOFOLLOW`, validated components, `fstat`, and regular-file/directory
checks. Symlinks, devices, FIFOs, sockets, empty/dot/dot-dot/NUL components, root
replacement, and intermediate/leaf replacement races fail closed or remain bound
to the already-open descriptor.

State directories are owner-only `0700`; files and locks are owner-only regular
single-link `0600` entries. Atomic replacement, lock acquisition, read/write, and
export use descriptor anchors. Private exports remain under `Exports/` by default;
external export is denied unless explicitly enabled and still validates owner,
leaf type, and replacement races.

## Resource bounds

The implementation enforces the frozen read, tree, expansion, result, context,
catalog, content-file/content-byte, matcher, regex-subject, and elapsed limits.
Deterministic search budget seams cover cancellation and elapsed exhaustion.

## Package, install, and control plane

- `RepoPromptHeadlessTests` is an independent SwiftPM test target.
- Conductor operations: `headless-build`, `headless-test --list|--filter`,
  `headless-package`, `headless-provenance`, `headless-install`,
  `headless-status`, `headless-uninstall`, and `headless-smoke`.
- Headless artifacts serialize on `headlessArtifact`; app packaging continues to
  use `debugArtifact`/`liveApp` and does not stage headless.
- Debug packaging signs the native-architecture binary. Release packaging builds
  arm64 and x86_64 independently and joins them with `lipo`.
- `artifact-manifest.json` records product/target/display/protocol, version/build,
  Git commit/dirty provenance, SHA-256, size, owner/mode, architectures, staged
  path, and executable version output. Verification recomputes these values.
- Install/status/uninstall manage only headless staged binaries, manifests, and
  owned symlinks. Normal uninstall preserves `Headless/v1`; `--delete-state` is
  explicit and rejects symlinked, unsafe, or non-owned roots.
- The packaged smoke uses isolated HOME/TMP/state, direct stdio only, exact tool
  listing/errors, malformed/oversized/EOF recovery, lifecycle, special-file and
  symlink denial, bounded search, serialized cross-process mutations, owner-only
  state, and clean response draining.

## Test inventory and evidence

Authoritative IDs come only from `make dev-headless-test-list`; the curated ledger
uses the `headless/` prefix. No existing test moved targets, so Phase 8 adds rows
without changing earlier IDs or scenario totals.

Final evidence:

| Lane | Ticket / result |
| --- | --- |
| Full root/provider/Core/CoreMacOS/POSIX/headless roots | `e25e5f14`, `89616b0e`, `508b3dd4`, `29fb8cc7`, `1d88e651`, `016a88df`; passed before review; affected headless rerun below |
| Final headless root | `541abda5-5ef2-4e32-add2-27272144bca3`; 89/89 passed |
| Final authoritative headless list | `312fe0fc-4973-4ff8-ae82-27de676a9a5d`; 89 exact IDs |
| Exact ledger reconciliation | 2,027 methods: root 1,637; provider 7; Core 257; CoreMacOS 34; POSIX 3; headless 89 |
| Format / strict lint | `1f57a9f4-e3cc-4ad8-8d2e-db227613ab16`, `b215b0a7-4b5b-449d-8375-2f90e3c16476`; passed |
| Guardrails / conductor / Xcode generator and `xcodebuild -list` | passed, including negative Phase 8 dependency/profile/package fixtures |
| All Swift products | `e8d0fb8f-242e-413b-8efb-28b76d10c144`; `RepoPrompt`, `repoprompt-mcp`, and `repoprompt-headless` passed |
| Debug packaged direct-stdio smoke | `58fc7d74-8337-46e6-bd9c-106cd4e079eb`; passed |
| Comparable debug packaged smokes | `a2858b8e-3caa-4f54-beba-4a0e01e2f7c4`, `fe13046e-e0be-43af-9513-6f350f9e7d32`; passed |
| Universal release package / provenance / smoke | `dbf8bac7-fb07-4734-94e7-16908e66e603`, `913c7372-ee21-4643-bd2f-a0a9e5920b17`, `479e1e86-3dcb-40a6-aaee-01b32386db70`; passed |
| Isolated debug/release install/status/uninstall | passed; both commands reported `1.0.21 (build 22)` and ordinary uninstall preserved the sentinel state |
| Separate unchanged app-proxy smoke | `cb4f57cc-4404-4158-9a6d-ccb767976901`; passed |
| Exact app stop / status / absence | `c3e388fc-198e-4784-a9b9-6d4de09edd2b`, `7bd5a095-1452-4788-9397-51434b5bad50`; PID 50364 absent and both exact executable scans empty |

The earlier `fe6efb74` smoke is excluded because its original `--skip-package`
path selected a build-tree binary. All final smoke evidence above used the staged
artifact. The hardened smoke covers manifest path/dirty/status tampering, binary
symlink substitution, exact release identity, duplicate IDs, cancellation, EOF
cancel/drain, incomplete framing, special-file and symlink rejection, bounded
catalog work, cross-process mutation, owner-only state, and explicitly enabled
external export without widening parent permissions.

## Independent review

Immutable Git snapshots `2026-06-22/0242` and `2026-06-22/0302` were published
before the single review. The bound-worktree tab rejected the generated artifact
alias, so the same review chat was completed with a manually curated full-file
selection of 55 runtime, security, package, test, and contract files rather than
silently reviewing the main checkout. Oracle review chat `untitled-chat-0ECC2A`
found six P1 groups; all were confirmed and corrected:

1. request-ID validation and collision checks now precede every request and
   distinguish JSON booleans from numeric `1`;
2. unexpected registry failures now become JSON-RPC `-32603` rather than MCP tool
   errors;
3. config/workspace commits use the frozen lock order and reject stale active
   workspace mutations;
4. catalog/tree enumeration is descriptor-relative and bounds all examined
   directory entries, including skipped names;
5. private state creation walks original path components with `openat` and
   `O_NOFOLLOW`, rejecting a symlinked ancestor without outside creation; and
6. initialize exposes exact build identity, manifest verification covers every
   source/artifact field and pre-resolution symlinks, and packaged smoke/install
   lanes cover the previously missing negative cases.

The focused regressions and final 89-test headless root passed after these fixes.
No app source, app bundle membership, `repoprompt-mcp` source, app socket/state/
secret identity, or Phase 7 routing identity changed. Phase 9 cleanup remains
unstarted.

## Rollback

Remove only managed headless links, staged binary, and matching manifest. Preserve
private `Headless/v1` state unless explicitly deleting it. Rollback must not touch
`RepoPrompt.app`, `repoprompt-mcp`, app sockets, app state/defaults, app Keychain
items, or Phase 7 runtime routing.
