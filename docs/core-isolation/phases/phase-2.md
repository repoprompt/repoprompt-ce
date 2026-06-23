# Phase 2 — Extract Neutral Leaves with One Concrete Owner

**Date:** 2026-06-21
**Base/checkpoint:** `b3eb2222c35f93e82b23ec08006c90464d49d0bb`
**Scope:** Phase 2 only
**Production behavior changes:** none intended; declaration ownership only
**Runtime authority changes:** none
**Close disposition:** **GO**

## Objective and completed work

Moved the ledger-owned Foundation/C-neutral workspace, root, readiness, catalog,
path, scope, selection, slice, prompt, codemap, regex, and utility leaves into
`RepoPromptCore` in dependency order. Every moved symbol has one concrete
production declaration. App call sites are preserved through the classified
temporary aliases in `Sources/RepoPrompt/App/CoreCompatibilityAliases.swift`
and three narrow forwarders/extensions recorded in the migration ledger.

### Dependency-leaf batches

1. Standardized/relative/checkout path identities, line ranges, slice math, and
   Unicode path-character policy.
2. Path-match protocols/frozen records, locate/create values, workspace root/
   alias/issue/client-path values, validated root/scope records, readiness and
   catalog DTOs, and path lookup DTOs.
3. Regex toolkit/adapter plus its existing Swift PCRE2 wrapper dependencies;
   no C implementation, symbol, bridging-header, or platform move.
4. Search query and immutable `PathSearchIndex`; root-generation indexes,
   store ranking policy, and caches remain in the app for Phase 4.
5. Selection/prompt projection values, factual `FileAPI` storage, immutable
   codemap snapshots, token snapshots, and file-tree snapshot values.
   Codemap rendering/token orchestration remains an app extension for Phase 6.
6. The exact persisted workspace graph plus its required `FilesTab`,
   `CopyCustomizations`, `FileTreeOption`, `CodeMapUsage`, and
   `GitInclusion` dependencies.

`WorkspaceModel` retains current defaults, equality exclusions, normalization,
the legacy `discover` key, malformed-compose-tabs fallback, and Foundation
JSON/date behavior. Its OSLog-only diagnostic dependency was replaced with the
Foundation `NSLog` equivalent so neutral Core imports no forbidden platform
module.

## Deliberate exclusions

- No `WorkspaceFileContextStore`, generation lease, root-local search index,
  path matcher/worker, watcher, ingress, persistence writer, or mutable workspace
  authority moved; these remain Phase 4–5 work.
- No POSIX, CoreServices/FSEvents, Security/Keychain, charset, descriptor/socket,
  Tree-sitter bridge, bridging-header, or C-symbol ownership move began; these
  remain Phase 3.
- No prompt/review authorization, prompt assembly, token-accounting actor, or
  factual rendering orchestration moved; these remain Phase 6.
- No headless runtime behavior or app-proxy routing changed.

## Test target and exact ID moves

Declared the first meaningful `RepoPromptCoreTests` target and added the
coordinated `core-test` lane, Make wrappers, module-filtered authoritative list
helper, CI job, contributor documentation, and optimizer-compatible exact list.

Exact moves:

- `root/RepoPromptTests.WorkspaceRootSyncTests/testWorkspacePersistenceLegacyDecodeCurrentEncodeAndCurrentReaderRoundTripContract`
  → `core/RepoPromptCoreTests.WorkspaceRootSyncTests/testWorkspacePersistenceLegacyDecodeCurrentEncodeAndCurrentReaderRoundTripContract`
  (3 scenarios preserved).
- `root/RepoPromptTests.WorkspaceRootSyncTests/testWorkspaceDecodeCreatesDefaultComposeTabAndIgnoresRemovedLegacyFields`
  → `core/RepoPromptCoreTests.WorkspaceRootSyncTests/testWorkspaceDecodeCreatesDefaultComposeTabAndIgnoresRemovedLegacyFields`
  (1 scenario preserved).
- `root/RepoPromptTests.RepoSearchQueryRecoveryTests/testFactoryNormalizesBoundsSlashAndWildcardSupport`
  → `core/RepoPromptCoreTests.RepoSearchQueryRecoveryTests/testFactoryNormalizesBoundsSlashAndWildcardSupport`
  (1 curated scenario preserved).
- `root/RepoPromptTests.PathSearchIndexRecoveryTests/testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata`
  → `core/RepoPromptCoreTests.PathSearchIndexRecoveryTests/testSearchMatchesFilenameSubpathTokensAndPublishesDeterministicRankMetadata`
  (1 curated scenario preserved).

New Phase 2 close oracles:

- `core/RepoPromptCoreTests.WorkspaceRootSyncTests/testNewWorkspaceBytesDecodeThroughIndependentLegacyRollbackReader`
  proves new Core bytes decode through an independent test-only legacy rollback
  DTO.
- `core/RepoPromptCoreTests.WorkspacePersistedOptionCompatibilityTests/testPersistedWorkspaceOptionRawValuesOrderingAndCodableBytesRemainStable`
  freezes five persisted option/raw-value/order/legacy-decode/customization-byte
  scenarios.

Authoritative post-change counts are 1,863 root IDs, 6 Core IDs, and 7 provider
IDs (1,876 total). Scenario totals are 2,393 root, 12 Core, and 16 provider
(2,421 total). The four physical moves preserve six scenarios; the two new
methods add six reviewed scenarios.

## Independent review

RepoPrompt Oracle review `new-chat-0AC0A1` found:

- codemap rendering had crossed the Phase 6 boundary — corrected by retaining
  `renderedCodemap` in an app extension;
- persisted `FileTreeOption` needed a direct compatibility oracle if Core-owned
  — retained as a required `WorkspaceModel` dependency and covered by the new
  five-scenario option test;
- root/Core test filters were not mechanically module-fenced — corrected and
  covered by conductor tests;
- an accidental conductor `last_tail` deletion and provider help regression —
  restored.

No second review was run, per repository workflow.

## Focused evidence

| Command | Ticket / result |
| --- | --- |
| `make dev-swift-build TARGET=RepoPromptCore` | final `0b339251-b6db-4de3-a7e6-d1906918aa98`; exit 0 |
| `make dev-swift-build PRODUCT=RepoPrompt` | `3f8791e2-6556-4b75-a166-5a67862da024`; exit 0 |
| `python3 Scripts/test_conductor_lifecycle.py` | final focused run: 67 tests, exit 0 |
| `python3 Scripts/test_core_isolation_guardrails.py -v` | final focused run: 9 tests, exit 0 |
| `python3 Scripts/test_test_suite_optimizer.py` | 26 tests, exit 0 |
| `make dev-core-test` | final `e01af642-c65d-41d0-a32b-821affd0106d`; 6 tests, exit 0 |
| `make dev-core-test-list` | `c2073e03-0bbd-4349-9434-3b50d9be2ee8`; 6 exact IDs, exit 0 |
| `make dev-test-list` | `38fbebf8-ba51-45f6-b384-91a5bfeae006`; 1,863 exact IDs, exit 0 |
| `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | exit 0; root 1,863, Core 6, provider 7 |
| `make dev-format` | `0efd4db7-a1ee-4510-9e82-222ecda42020`; exit 0; 16/1,241 files formatted |

## Final Phase 2 validation ladder

| Command | Ticket / result |
| --- | --- |
| `make dev-format` | `0efd4db7-a1ee-4510-9e82-222ecda42020`; 16/1,241 files formatted; exit 0 |
| `make dev-lint` | `c3fc98be-64d3-400e-af68-68a261f09e5c`; formatter 0 changes, SwiftLint 0 violations; exit 0 |
| `python3 Scripts/core_isolation_guardrails.py` | pass |
| `python3 Scripts/test_core_isolation_guardrails.py -v` | 9 tests; exit 0 |
| `python3 Scripts/test_conductor_lifecycle.py` | 67 tests; exit 0 |
| `python3 Scripts/test_test_suite_optimizer.py` | 26 tests; exit 0 |
| `make guardrails` | source layout pass; allowlist 747; notices 49; exit 0 |
| `make xcode-generator-test` | 23 tests; exit 0 |
| `make xcode-validate` | generated-workspace validation pass; exit 0 |
| `make dev-swift-build TARGET=RepoPromptCore` | `0b339251-b6db-4de3-a7e6-d1906918aa98`; exit 0 |
| `make dev-swift-build TARGET=RepoPromptCoreMacOS` | `7521b839-4c4f-4569-97d6-396edff0943b`; exit 0 |
| `make dev-swift-build TARGET=RepoPromptPOSIXSupport` | `f3006ae9-cb05-450d-a6c2-f4d7a0caa28b`; exit 0 |
| `make dev-swift-build TARGET=RepoPromptSyntaxCBridge` | `1f46488d-3406-4f15-be09-1f048757893f`; exit 0 |
| `make dev-swift-build TARGET=RepoPromptHeadless` | `0d7b6868-27de-4c86-a1a0-539672406d8f`; exit 0 |
| `make dev-swift-build PRODUCT=all` | `17db0bd4-197c-4bc0-8ee4-c8ccc7aa1ef0`; all three products; exit 0 |
| `make dev-core-test-list` | `c2073e03-0bbd-4349-9434-3b50d9be2ee8`; 6 exact IDs; exit 0 |
| `make dev-test-list` | `38fbebf8-ba51-45f6-b384-91a5bfeae006`; 1,863 exact IDs; exit 0 |
| `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | root 1,863; Core 6; provider 7; 1,876 total; scenario total 2,421; exit 0 |
| `make dev-core-test` | `e01af642-c65d-41d0-a32b-821affd0106d`; 6 tests, 0 failures |
| `make dev-test` | `4c712bf7-5a3e-404d-be57-8f48757525b2`; 1,863 tests, 2 skipped, 0 failures |
| `make dev-provider-test` | `e9b4935b-40aa-4a72-af16-04d753121d8f`; 7 tests, 0 failures |
| `make dev-build` | `f8abaf39-9521-4ebc-af4a-516503106a91`; signed debug package, architecture/layout checks and embedded MCP helper smoke pass; exit 0 |

No visible app was launched, stopped, or relaunched. A live app smoke was not
required because Phase 2 changes declaration/test ownership only and does not
change proxy routing, runtime authority, CLI identity, or headless behavior.

## Risks and blockers

No known blockers. The temporary app aliases/forwarders remain explicit Phase 9
cleanup debt, and the retained app rendering/presentation extensions are
classified by `P2-APP-001`. Phase 3 platform/C bridge work and Phase 4 engine
extraction remain untouched.

## Exact uncommitted file inventory

The following paths are the complete Phase 2 working-tree inventory at close.
Deleted app paths have replacement concrete owners under `RepoPromptCore`.

```text
.github/workflows/ci.yml
AGENTS.md
Makefile
Package.swift
Scripts/Fixtures/test-suite-contract-ledger.tsv
Scripts/conductor.py
Scripts/core_isolation_guardrails.py
Scripts/list_swift_tests.py
Scripts/test_conductor_lifecycle.py
Scripts/test_core_isolation_guardrails.py
Sources/RepoPrompt/App/CoreCompatibilityAliases.swift
Sources/RepoPrompt/Features/CodeMap/CodeMapExtractor.swift
Sources/RepoPrompt/Features/CodeMap/FileTreeSelectionSnapshot.swift (deleted/moved)
Sources/RepoPrompt/Features/CodeMap/Models/FileAPI.swift (deleted/moved)
Sources/RepoPrompt/Features/Prompt/Models/Copy/CopyCustomizations.swift (deleted/moved)
Sources/RepoPrompt/Features/Prompt/Models/Copy/CopyPreset.swift
Sources/RepoPrompt/Features/Prompt/Models/FilesTab.swift
Sources/RepoPrompt/Features/Prompt/ViewModels/PromptViewModel.swift
Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift
Sources/RepoPrompt/Infrastructure/Regex/PCRE2RegexAdapter.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/Regex/RegexToolkit.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/Utilities/CheckoutPathIdentity.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/Utilities/RelativePath.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/Utilities/StandardizedPath.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/Models/WorkspaceFileContextModels.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathCharPolicy.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatchTypes.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathLookup/PathMatchingInterfaces.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/PathResolution/WorkspacePathPolicy.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/PathSearchIndex.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/RepoSearchQuery.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/LineRange.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/WorkspaceContext/Slices/SliceRangeMath.swift (deleted/moved)
Sources/RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationService.swift
Sources/RepoPrompt/Infrastructure/WorkspaceContext/TokenAccounting/TokenCalculationSnapshot.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2Error.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2JIT.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2LiteralEscaping.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2Match.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2Options.swift (deleted/moved)
Sources/RepoPrompt/ThirdParty/SwiftPCRE2/PCRE2Regex.swift (deleted/moved)
Sources/RepoPromptCore/CodeMap/FileTreeSelectionSnapshot.swift
Sources/RepoPromptCore/CodeMap/Models/FileAPI.swift
Sources/RepoPromptCore/Regex/PCRE2Error.swift
Sources/RepoPromptCore/Regex/PCRE2JIT.swift
Sources/RepoPromptCore/Regex/PCRE2LiteralEscaping.swift
Sources/RepoPromptCore/Regex/PCRE2Match.swift
Sources/RepoPromptCore/Regex/PCRE2Options.swift
Sources/RepoPromptCore/Regex/PCRE2Regex.swift
Sources/RepoPromptCore/Regex/PCRE2RegexAdapter.swift
Sources/RepoPromptCore/Regex/RegexToolkit.swift
Sources/RepoPromptCore/Utilities/CheckoutPathIdentity.swift
Sources/RepoPromptCore/Utilities/RelativePath.swift
Sources/RepoPromptCore/Utilities/StandardizedPath.swift
Sources/RepoPromptCore/WorkspaceContext/Models/WorkspaceFileContextModels.swift
Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathCharPolicy.swift
Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathMatchTypes.swift
Sources/RepoPromptCore/WorkspaceContext/PathLookup/PathMatchingInterfaces.swift
Sources/RepoPromptCore/WorkspaceContext/PathResolution/WorkspacePathPolicy.swift
Sources/RepoPromptCore/WorkspaceContext/Search/PathSearchIndex.swift
Sources/RepoPromptCore/WorkspaceContext/Search/RepoSearchQuery.swift
Sources/RepoPromptCore/WorkspaceContext/Slices/LineRange.swift
Sources/RepoPromptCore/WorkspaceContext/Slices/SliceRangeMath.swift
Sources/RepoPromptCore/WorkspaceContext/TokenAccounting/TokenCalculationSnapshot.swift
Sources/RepoPromptCore/WorkspaceContext/TokenAccounting/TokenEstimator.swift
Sources/RepoPromptCore/Workspaces/CodeMapUsage.swift
Sources/RepoPromptCore/Workspaces/CopyCustomizations.swift
Sources/RepoPromptCore/Workspaces/FileTreeOption.swift
Sources/RepoPromptCore/Workspaces/FilesTab.swift
Sources/RepoPromptCore/Workspaces/GitInclusion.swift
Sources/RepoPromptCore/Workspaces/WorkspaceModel.swift
Tests/RepoPromptCoreTests/WorkspaceContext/Search/PathSearchIndexRecoveryTests.swift
Tests/RepoPromptCoreTests/WorkspaceContext/Search/RepoSearchQueryRecoveryTests.swift
Tests/RepoPromptCoreTests/WorkspacePersistedOptionCompatibilityTests.swift
Tests/RepoPromptCoreTests/WorkspaceRootSyncTests.swift
Tests/RepoPromptTests/WorkspaceContext/Search/PathSearchIndexRecoveryTests.swift (deleted/moved)
Tests/RepoPromptTests/WorkspaceContext/Search/RepoSearchQueryRecoveryTests.swift (deleted/moved)
Tests/RepoPromptTests/WorkspaceRootSyncTests.swift
docs/core-isolation/README.md
docs/core-isolation/migration-ledger.tsv
docs/core-isolation/phases/phase-2.md
docs/testing.md
```

## Close disposition

**GO.** Phase 2 is complete from checkpoint `b3eb2222`. The declaration moves,
compatibility shims, exact Codable/rollback coverage, authoritative ID migration,
curated ledger, target graph, full tests, package gate, and isolation guardrails
all pass. The work remains intentionally uncommitted. Phase 3 and Phase 4 have
not begun.
