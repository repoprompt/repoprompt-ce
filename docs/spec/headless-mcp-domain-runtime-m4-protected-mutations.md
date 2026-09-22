# Headless MCP domain runtime — M4 protected mutations

Milestone 4 is PR 5/8, stacked on M3 (`feature/headless-runtime-m3-read-discovery`, PR #657). It migrates protected mutation admission into `RepoPromptDomainRuntime` without adding a direct standalone host, AI/Agent execution, credential transport, or M7 cleanup.

## Gate 4A — selection, prompt, routing, and workspace mutations

Gate 4A protects the mutation actions of `manage_selection`, `prompt`, `workspace_context`, `bind_context`, and `manage_workspaces`. Read actions on mixed tools retain their M3 behavior. `file_actions`, `apply_edits`, and `manage_worktree` remain explicitly outside the gate until 4B.

### Authority and parity ledger

| Concern | M4 authority | Compatibility boundary |
|---|---|---|
| mutation classification | `MCPDomainProtectedMutationToolProvider` | existing public names, input schemas, annotations, and physical app providers are unchanged |
| invocation identity | immutable `DomainToolInvocationSecurityContext` installed by `MCPConnectionManager`; connection generation is the coordinator-owned registration token | verified app-proxy transport and run-scoped tool advertisement remain unchanged across routing re-registration |
| persistent headless grants | `DomainMutationPolicyStore`, schema version 1, CAS-written protected-mutation policy | grants bind to a kernel-verified executable fingerprint, and running brokers reload versioned snapshots before admission/precommit |
| approval ordering and settlement | `DomainMutationApprovalBroker` | `WorkspaceApprovalManager` is an AppKit presenter and legacy policy façade |
| policy administration | `repoprompt-mcp policy list|grant|revoke` | mutations require stdin and stderr TTYs plus an immediate `yes` confirmation |
| construction | `ServiceRegistry` wraps every registered binding exactly once | app providers remain physical backends; no second mutation registration exists |

The runtime starts in an explicit construction stage. The 4A commit selected `m4A`; after its focused gate passed, the 4B commit switches production app composition to `m4B`. The configuration default remains `m3Compatibility` for explicit compatibility fixtures. This prevents both partial activation and dual executable mutation paths.

### Security ledger

- Missing, display-name-only, runtime-generation-mismatched, stale-registration, unbound, or otherwise unresolved headless routing contexts default-deny before the physical backend; routing failures are never normalized into an authoritative empty-root scope.
- Verified app-proxy principals preserve current app behavior, including the AppKit approval presenter and proxy backend.
- Run-scoped verified principals require the tool in their immutable ephemeral grant, or a non-expired, non-revoked persistent grant matching `tool.action`, kernel-verified executable fingerprint, optional provider/workspace, and canonical roots.
- All relevant 4A mutations carry canonical-root scope; `manage_workspaces.add_folder` and path-based create requests include the requested new root so a narrow grant cannot expand itself.
- Authorization reloads the persisted versioned snapshot and is revalidated with cancellation immediately before backend execution, making a TTY CLI revoke visible to an already-running broker.
- Persistent grant changes are TTY-administrator-only and compare-and-swap against the durable document.
- Corrupt, future-version, wrong-profile, or externally-conflicted policy enters degraded read-only mode.
- Approval requests have one FIFO active presenter, bounded deadlines, cancellation settlement, presenter-loss settlement, default-deny terminal mapping, and ignored late responses.

### MainActor ledger

`DomainMutationPolicyStore`, `DomainMutationApprovalBroker`, and `MCPDomainProtectedMutationToolProvider` are domain-runtime concurrency authorities and do not depend on AppKit or `@MainActor`. `WorkspaceApprovalManager` remains `@MainActor` only as the compatibility presenter/policy façade. Physical selection, prompt, routing, and workspace backends retain their existing app isolation; the new security decision executes before entering them.

### Review remediation and migration ledger

| Review gate | Resolution |
|---|---|
| B1 registration namespace | invocation and routing use one coordinator-owned registration token; re-registration is observed through the app invocation seam and unresolved routing fails closed |
| B2 physical target fence | app providers admit the translated/resolved physical target and root mapping, then revalidate exact target or nearest-existing-parent identity immediately precommit |
| B3 correlation semantics | public `operation_id` is unchanged and correlation-only; a distinct server-owned request key drives journal ownership and recovery verbs remain retryable |
| H1 live policy visibility | every admission/revalidation refreshes the versioned CAS snapshot, so external revoke/regrant is visible without relaunch |
| H2 principal spoofing | persistent grants match a kernel-derived executable fingerprint; display/provider names are metadata only |
| H3 export writes | `prompt.export` and `workspace_context.export` are durable fenced families |
| H4 DEBUG assurance | DEBUG uses real peer verification by default and exposes an injected verified/unverified identity only to tests; no forced self-PID fallback remains |
| H5 4A roots | canonical roots are passed for relevant 4A mutations and requested new workspace roots are included in authorization |

No M5 AI/Agent execution authority, M6 direct host/backend, or M7 proxy cleanup moved in this remediation.

### Gate 4A focused evidence

| Validation | Result |
|---|---|
| `make dev-test FILTER=DomainProtectedMutationSecurityTests` | passed after staged grant-selection review fix, ticket `c50dfe50-9f60-4d01-844a-c80552353fdf` |
| `make dev-test FILTER=DomainMutationApprovalBrokerTests` | passed, ticket `dd9ca20d-ec78-4e20-83e1-814259360be7` |
| `make dev-test FILTER=WorkspaceApprovalCancellationTests` | passed, ticket `16eae60b-696f-4cfb-b2b6-0c0d612d1de8` |
| `make dev-test FILTER=HeadlessMCPDomainRuntimeM0ContractTests` | passed, ticket `06983bcc-1bb0-406f-ac10-737344cc194c` |
| `make dev-test-list` | passed, ticket `04183487-83e2-4b17-a83a-54cf7eb31cea` |
| `test_suite_optimizer.py verify-ledger` | passed; 3,634 exact root/provider IDs reconciled |
| `make dev-swift-build PRODUCT=RepoPrompt` | passed, ticket `893688a2-cb77-441e-abe3-28549f715a87` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | passed, ticket `710c0e01-3ac0-419d-a1d8-cc3ae1822a79` |
| `make dev-lint` | passed, ticket `c182fb45-f0b0-4ce2-af2d-6ee532cbdabf` |
| `make xcode-generator-test` | passed, 24 tests |
| `make guardrails` | passed |

## Gate 4B — filesystem, apply-edits, and worktree mutations

Gate 4B activates `file_actions`, `apply_edits`, and mutating `manage_worktree` actions through the same `MCPDomainProtectedMutationToolProvider`; the physical app providers remain the single execution backends.

### Security and settlement ledger

| Concern | M4 authority | Commit boundary |
|---|---|---|
| root scope | immutable logical roots/revision plus `WorkspaceRootBindingProjection` physical mappings | the app backend translates/resolves the exact physical target before admission; policy scope remains canonical/logical |
| symlink/TOCTOU fence | `DomainMutationPathFence` | physical root and exact target/nearest-existing-parent device/inode plus resolution are revalidated immediately before physical mutation, detecting symlink and nonexistent-parent swaps |
| durable settlement | `DomainMutationJournal`, schema version 1, CAS-written protected-mutation journal | a server-owned request mutation key elects one writer and settles its exact result; public `operation_id` remains correlation-only and can be reused |
| file actions | existing `MCPServerViewModel.performFileAction` backend | hook follows freshness/argument validation and precedes create/trash/move I/O |
| apply edits | existing `WorkspaceFileEditHost`/`WorkspaceFileMutationService` backend | hook follows path/edit/approval/existence resolution and immediately precedes overwrite/create store I/O |
| worktrees | existing worktree provider and `VCSService` backends | create/apply/continue/abort admit and revalidate their resolved repository/worktree endpoints before settings/Git/session mutation |
| prompt/workspace exports | existing prompt-context provider and file writer | resolved export destinations use the same fence, journal, cancellation, and precommit hook as other filesystem writes |

Relative file paths remain compatible when exactly one authoritative root is bound; ambiguous multi-root relative writes fail closed. Verified app-proxy external worktree creation retains its explicit `allow_external_path` behavior while headless grants remain root-scoped.

Cancellation before the commit hook records `cancelledBeforeCommit` for the internal request key and permits a fresh retry. Once the hook atomically moves the record to `committing`, cancellation or reply loss produces a partial-success diagnostic and durable `indeterminateAfterCommit`; restart refuses automatic reexecution of that exact internal request. Applied records contain the encoded exact MCP result. Public correlation-ID reuse—including worktree merge IDs—does not collide with or poison later continue/abort/retry requests. Active-owner, corrupt/future journal, CAS exhaustion, and interrupted commit all default-deny.

### MainActor ledger

`DomainMutationJournal`, `DomainMutationPathFence`, and the protected provider are AppKit-free domain authorities. Existing physical file/edit/worktree providers retain their current actor isolation. The task-local commit controller crosses into those providers only to revalidate policy/path authority and CAS the durable journal at their physical commit point.

### Gate 4B focused evidence

| Validation | Result |
|---|---|
| `make dev-test FILTER=DomainProtectedMutationJournalTests` | passed 5 adversarial fixtures after final fence/fingerprint strengthening, ticket `f6363730-c0dc-4afb-95bd-7c3272a3a7a6` |
| `make dev-test FILTER=HeadlessMCPDomainRuntimeM0ContractTests` | passed 3 contract/ledger tests, ticket `673437d2-8b07-4232-8401-6b8539f78d71` |
| `make dev-test FILTER=MCPFileActionPartialSuccessTests` | passed 3 app compatibility tests, ticket `25816d99-c2f7-41f9-9be6-99158c3acf20` |
| focused apply-edits materialization test | passed, ticket `b58ef2f3-0170-47d9-b0dc-d1f4b9533963` |
| `make dev-test FILTER=ManageWorktreeToolServiceTests` | passed 2 provider tests, ticket `4ee23570-2a76-41f3-96ab-3b2e3bd58db5` |
| `make dev-test FILTER=ToolCatalogSnapshotTests` | passed 20 frozen catalog tests, ticket `0f8a0c6e-3538-44af-a753-b118f43348ae` |
| `make dev-test-list` + `verify-ledger` | passed; 3,639 exact root/provider IDs reconciled, list ticket `d2f504c5-cc1e-4263-8fca-b6b5ea8141de` |
| `make dev-swift-build PRODUCT=RepoPrompt` | passed, ticket `6a8b2c17-11f8-41a8-82da-ecf60948f4b6` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | passed, ticket `1c59725c-f484-429a-be78-0d318cff6f34` |
| `make dev-lint` | passed, ticket `dd1728b2-2b3e-407d-bbd2-17c59604a89d` |
| `make guardrails` | passed |


### Review-remediation focused evidence (2026-07-27)

| Validation | Result |
|---|---|
| `make dev-test FILTER=DomainProtectedMutationSecurityTests` | passed 8 live-policy/fingerprint/root-scope tests, ticket `1a669936-2f64-4372-af9d-40a3590758da` |
| `make dev-test FILTER=DomainMutationApprovalBrokerTests` | passed 4 FIFO/cancellation/default-deny tests, ticket `b281e537-38d7-4b71-9d4e-2113f101f1d4` |
| `make dev-test FILTER=WorkspaceApprovalCancellationTests` | passed 3 AppKit presenter compatibility tests, ticket `a9b18e6e-3cee-402c-8ada-496d7f5e776b` |
| `make dev-test FILTER=DomainProtectedMutationJournalTests` | passed 7 internal-key/CAS/cancellation/physical-fence adversarial tests, ticket `d4c7737b-c8eb-4380-ab99-24df4929c06d` |
| `make dev-test FILTER=MCPProtectedMutationInvocationIntegrationTests` | passed 2 actual socket/app-provider tests covering routing re-registration, injected unverified identity, correlation reuse, both export families, and bound-worktree translation, ticket `7ee8d9a1-776c-4488-81f7-2c24d76ce8f7` |
| `make dev-test FILTER=HeadlessMCPDomainRuntimeM0ContractTests` | passed 3 catalog/contract tests, ticket `988e7068-5510-44b6-b8a0-83e1b4300970` |
| routing generation/launch-token authority method | passed, ticket `18bc37ba-50ce-4f14-ab07-c41faaf78eda` |
| `make dev-test FILTER=MCPFileActionPartialSuccessTests` | passed 3 file-action/apply-edits compatibility tests, ticket `238d5ff2-87ae-4906-89be-6d7d07ddea1f` |
| `make dev-test FILTER=ManageWorktreeToolServiceTests` | passed 2 worktree compatibility tests, ticket `c35b7ea6-8ea7-478d-be00-57ee3baa4521` |
| `make dev-test-list` + `verify-ledger` | passed; 3,645 exact root/provider IDs reconciled, list ticket `da0c0db8-a271-4719-b5e9-5f3e0011f978` |
| `make dev-swift-build PRODUCT=RepoPrompt` | passed, ticket `fc625590-9fbf-46bb-837d-c720d1773e67` |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | passed, ticket `94086e9e-1dcc-478d-b1b9-46e601e596f6` |
| `make dev-lint` | passed, ticket `c6cb6634-fd98-4c5e-b05a-68c8b18e8c56` |
| `make guardrails` | passed |

## Explicit exclusions

M4 does not migrate AI/Agent/Context Builder execution (M5), add a direct host/backend or credential transport (M6), remove the app proxy/physical adapters (M7), launch/relaunch the visible app, or change the frozen 27-tool public catalog.
