# Headless MCP domain runtime — M3 read/discovery evidence

Milestone 3 moved the nine read/discovery tool registrations to one Swift 6, AppKit-free owner in `RepoPromptDomainRuntime`. It is stacked on the M2 workspace/context authority and does not add a standalone stdio host. The nine-method count is historical evidence; the current retained `MCPDomainReadToolProviderTests` inventory is four methods.

## Scope

| Family | Shared registration | App physical backend | Context / read-derived side effect |
|---|---|---|---|
| `get_code_structure`, `get_file_tree`, `read_file`, `file_search` | `MCPDomainReadToolProvider` / `MCPDomainReadToolDefinitions` | `MCPFileToolProvider` | file/codemap/search require workspace authority; tree retains graceful no-workspace behavior; read/search enqueue selection before replying |
| `workspace_context`, `prompt` | same | `MCPPromptContextToolProvider` | workspace authority required; selected-context consumers drain; prompt mutations remain compatibility passthroughs and gain no M4 policy |
| `oracle_chat_log`, `history` | same | `MCPOracleToolProvider`, `MCPHistoryToolProvider` | workspace-independent; no MainActor authority capture |
| Git `status`, `diff`, `log`, `show`, `blame` | same | `MCPGitToolProvider` | workspace/connection remain optional where historically accepted; requested artifact selection and advertisement commit before success |

The app catalog projects `MCPDomainToolDefinition` into the existing `Tool` value at its final registration boundary and retains `MCPWindowToolRuntime` as the freshness/tracing/watchdog execution envelope. The legacy app providers no longer register these nine names. Historical `ToolCatalogSnapshotTests` evidence recorded the unchanged 24-tool order, descriptions, annotations, and schema hashes.

## Authority and concurrency contract

Top-level shared validation runs before routing, so invalid `read_file`, `file_search`, and `get_code_structure` parameters cannot be replaced by unrelated connection/workspace failures. The provider classifies each family as workspace-independent, optional, or required. Only scoped reads capture app authority, and they capture it once.

For a resolved live app workspace, `DomainWorkspaceAuthorityClient.registerForRead` synchronously registers a transient authority snapshot before binding. This closes the debounced/unawaited publication race and supports ephemeral and test workspaces without adding them to the durable workspace catalog. Direct/test composition receives a registered fallback domain handle tied to the same runtime identity as its effect coordinator rather than executing a required read unfenced. A failed canonical command does not discard the overlay; any later applied/deduplicated canonical create/replace supersedes it, including different canonical bytes.

`DomainReadContextHandle` contains runtime and connection generations, `DomainContextIdentity`, workspace/context revisions, routing revision evidence, and binding kind, but no window identity. `refreshReadContext` fences the runtime incarnation, exact connection incarnation, current binding/entity identity, and the workspace/context revisions actually consumed. It intentionally ignores the process-global routing revision and unrelated window presentation changes. Existing run-scoped bindings are never rebound by reads. Refresh runs on the domain actor rather than recapturing `MCPServerViewModel`/MainActor state. Read resolution neither registers nor rewrites a window presentation descriptor.

The app registers one invocation-scoped execution snapshot containing captured request metadata, resolved routing/worktree authority, and lookup scope, then releases it on every terminal path. File and prompt backends consume that snapshot instead of recapturing routing. After a legacy selection-queue drain, selection-consuming prompt/context reads refresh only the exact canonical selection value and revision for the already-bound workspace/tab; they do not repeat heavyweight tab routing or alter prompt/worktree/presentation authority. Window teardown tracks and unregisters every domain connection it owns, so a completed connection lifecycle cannot leak an immutable binding into a later connection incarnation.

Physical I/O, parsing, search, history, prompt rendering, Oracle-log lookup, and Git work remain in injected non-MainActor backends. A later direct host can inject its backend without defining another tool or schema.

## Side-effect contract

`DomainReadSideEffectCoordinator` maintains independent lanes per exact domain context and effect class (`selection`, `gitArtifacts`). Selection effects remain ordered with selection effects, while Git artifact publication cannot be blocked by unrelated selection latency in the same context.

Each lane assigns monotonic revisions, deduplicates exact operation-ID retries, rejects fingerprint collisions, and keeps bounded operation/task plus expired-receipt ledgers. A new effect waits for an earlier effect to terminate but does not inherit its error; the exact submitter still observes its own failure or cancellation, and later calls recover. Exact waits fail closed when their receipt has expired instead of silently succeeding. Cancelling an exact waiter cancels its own effect; cancelling a shared drain returns promptly without cancelling the shared effect. Shutdown cancels pending work and rejects new submissions.

Historical visibility is preserved at the app seam:

- `read_file` / `file_search` await admission to the existing canonical selection queue before the tool replies. The retained `MCPDomainReadToolProviderTests/testSideEffectCommitCompletesBeforeSuccessfulResponse` covers commit-before-response; deterministic selection and routing tests cover the subsequent consumer handoff.
- Git artifact selection and advertisement both commit before a successful Git response.
- A failed/cancelled side effect cannot be normalized into success, poison later effects, or publish a second late success.

## Parity and evidence

- Current shared owner/context coverage: four retained `MCPDomainReadToolProviderTests` methods cover per-family requirements, required-authority fail-closed/release behavior, validation-before-routing, and commit-before-response.
- Earlier catalog, authority, contention, cancellation, and broad parity runs are historical milestone evidence; their dedicated timing and orchestration suites were removed during the test cleanup.
- Source/MainActor guards: the M0 contract manifest and `source_layout_guardrails.sh` enforce all nine shared definitions, the family requirement mapping, awaited read registration, absence of repeated `validateDomainReadContext`, absence of presentation registration in read resolution, independent effect classes, and non-poisoning effect chaining.

## Explicit exclusions

M3 does not add protected mutation policy, AI sends, Agent or Context Builder execution, provider/process token handoff, a standalone stdio host/backend, credentials/listener work, or M4+ UI cleanup. Existing socket proxy behavior and all unmigrated tool registrations are unchanged.

The headless side of this milestone is the executable shared provider/backend contract, not a new direct process surface. Direct standalone composition remains the planned host milestone.
