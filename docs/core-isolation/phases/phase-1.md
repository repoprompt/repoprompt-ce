# Phase 1 — Land Package, Harness, and Guardrail Scaffolding Atomically

**Date:** 2026-06-21
**Base/checkpoint:** `e30f104d74ee27973fed1a336b3763261fb86ec2`
**Scope:** Phase 1 only
**Production behavior changes:** none; additive compile/control-plane scaffolding only
**Runtime ownership changes:** none
**Close disposition:** GO — Phase 1 closed; Phase 2 may begin separately

## Objective and completed work

- Added the five production target roots frozen by ADR-001:
  `RepoPromptCore`, `RepoPromptCoreMacOS`, `RepoPromptPOSIXSupport`,
  `RepoPromptSyntaxCBridge`, and `RepoPromptHeadless`.
- Added only one executable product, `repoprompt-headless`, backed by a no-I/O
  scaffold. No direct-stdio protocol, state, permissions, install, packaging,
  smoke, or other Phase 8 behavior is present.
- Preserved all current `RepoPrompt` runtime declarations, writers, watchers,
  persistence, selection, search, prompt, MCP routing, and bridging-header
  ownership. No Phase 2 declaration moved or was duplicated.
- Added exact manifest/source guards for dependency direction, forbidden Core
  imports, canonical declaration ownership, the `rpce_` namespace, narrow bridge
  roots, app/headless packaging separation, and absent placeholder test roots.
- Added conductor/Make/CI build vocabulary for all five targets and the headless
  product while adding no future test, package, install, or smoke lane.
- Updated generated Xcode validation for the five targets and native headless
  product while retaining exactly the existing three convenience workflows.
- Migrated optimizer/documentation vocabulary to `root/`, `provider/`, `core/`,
  `core-macos/`, `posix/`, `syntax-c-bridge/`, and `headless/`. An absent test
  target contributes zero IDs and no list operation; once declared, its exact
  module-bound list lane is mandatory and nonempty.

## Test-quality decision

No XCTest target or method was added, moved, renamed, consolidated, or removed.
Phase 1 introduces no runtime behavior with a faithful executable XCTest oracle;
placeholder methods would create false coverage. P0-09 and P0-10 are protected
at the lowest faithful layer by deterministic manifest, source/import, C-symbol,
packaging-separation, conductor, optimizer, and Xcode generator tests.

The curated contract ledger remains exactly 1,874 live IDs: 1,867 `root/` and
7 `provider/`. Scenario totals remain 2,415: 2,399 root and 16 provider. The
five reserved prefixes remain empty. No old-to-new test-ID mapping exists.

## Focused implementation evidence

| Command | Result |
| --- | --- |
| `python3 Scripts/test_core_isolation_guardrails.py -v` | exit 0; 9 deterministic positive/negative guard tests passed |
| `python3 Scripts/core_isolation_guardrails.py` | exit 0; live target/source/symbol/package guard passed |
| `python3 Scripts/test_test_suite_optimizer.py` | exit 0; 26 optimizer tests passed |
| `python3 Scripts/test_conductor_lifecycle.py` | exit 0; 66 conductor tests passed |
| `make xcode-generator-test` | exit 0; 23 deterministic generator tests passed |
| independent final-diff review | six findings; dependency edges, declaration ownership, test-module binding, packet index, ledger provenance, and repository instructions corrected |
| RepoPrompt Oracle review attempt | unavailable because the RepoPrompt MCP transport closed after parallel probes; not counted as review evidence |

## Final Phase 1 validation ladder

### Production targets and products

| Command | Ticket | Result |
| --- | --- | --- |
| `make dev-swift-build TARGET=RepoPromptCore` | `96463783-2b6c-4af4-8762-f936bfdcba10` | exit 0 |
| `make dev-swift-build TARGET=RepoPromptCoreMacOS` | `95210eb3-3834-488b-9b44-eaad2045e3d0` | exit 0 |
| `make dev-swift-build TARGET=RepoPromptPOSIXSupport` | `a763838d-b425-42e0-91e9-94b09103808a` | exit 0 |
| `make dev-swift-build TARGET=RepoPromptSyntaxCBridge` | `0a77a482-b197-42dd-8060-ec0a3b22b2cf` | exit 0 |
| `make dev-swift-build TARGET=RepoPromptHeadless` | `c5a5aa98-1963-4bd8-b11f-e72cbf4d8731` | exit 0 |
| `make dev-swift-build PRODUCT=RepoPrompt` | `c2b61b88-84c4-42f0-a793-94aa1bc82029` | exit 0 |
| `make dev-swift-build PRODUCT=repoprompt-mcp` | `c27ea531-4d99-4a4d-9624-1aba255e10ec` | exit 0 |
| `make dev-swift-build PRODUCT=repoprompt-headless` | `ea08f05f-a6a2-42b0-9e46-9db257f7f76d` | exit 0 |

### Test lists and ledger

| Command | Ticket / artifact | Result |
| --- | --- | --- |
| `make dev-test-list` | `f20b3693-0346-40ba-94bb-857e693ffe5b` | exit 0; 1,867 IDs; SHA-256 `d1217f6703a581562fb47a986bb2c0a8f4ee67b20ff40a41d395856d8c77d9e2` |
| `make dev-provider-test-list` | `079c0d54-67df-42c3-967c-a2813bfb742a` | exit 0; 7 IDs; SHA-256 `af8669b714868d718314b12d53a2e4d3980e040a2cd4ede26d28d17d03368948` |
| `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv` | final list tickets `68e58af5-5f7e-4784-9db1-80ed986c6451` / `f6ece191-4907-439e-97ef-daf6837a05b2` | exit 0; exact total 1,874; root 1,867; provider 7; all five reserved prefixes zero and undeclared |

### Guards, generated Xcode, and style

| Command | Ticket | Result |
| --- | --- | --- |
| `make guardrails` (final) | n/a | exit 0; Core guard tests, source layout, contributor allowlist, and 49-package notice inventory pass |
| `make xcode-generator-test` | n/a | exit 0; 23 tests; byte determinism and scaffold manifest contracts pass |
| `make xcode-validate` | n/a | exit 0; regenerated workspace and `xcodebuild -list` validate native `repoprompt-headless` plus exactly three convenience workflows |
| `make dev-format` (final) | `1054c722-6203-4eb6-b40e-65c85cd6abda` | exit 0; 0/1,224 files formatted |
| `make dev-lint` (final) | `d9923ed2-7628-4bcb-9005-50df3c2cf1d4` | exit 0; 0 format changes and 0 strict-lint violations |

### Full tests and package validation

| Command | Ticket | Result |
| --- | --- | --- |
| `make dev-test` (first final-tree attempt) | `86a088c1-d99a-43fd-aac5-042753486e8f` | exit 1; known Phase 0 transient `MCPAskOracleWorktreeTests` artifact-path unwrap |
| exact failing test retry | `3f146ebc-98a1-4c99-a00e-0ef5060982a9` | exit 0; 1 test passed |
| `make dev-test` (full retry) | `a1a767d4-9982-42a0-84a0-3338c37b8546` | exit 0; full 1,867-test root lane passed |
| `make dev-provider-test` | `5a162918-3994-4c8e-8d41-03b493a30574` | exit 0; 7 tests passed |
| `make dev-build` | `d6a73997-04d0-42de-9686-2804673a230b` | exit 0; signed package, architecture, embedded proxy layout, and helper smoke pass without launching the app |
| bundle executable assertion | `.build/debug/RepoPrompt.app` | `RepoPrompt` and `repoprompt-mcp` present; `repoprompt-headless` absent |

Local evidence artifacts are under `/tmp/core-isolation-phase1/`; they are not
tracked packet files.

## Risks and blockers

- No open implementation, graph, test, package, or lifecycle blocker remains.
- Transitional app C/grammar/charset dependencies and the app bridging header
  intentionally remain until their owning Phase 2–3 moves.
- The headless executable terminating without I/O is scaffold behavior only and
  is not evidence for the frozen Phase 8 wire/security contract.
- No visible app launch, stop, or relaunch occurred.
- The first full-root run reproduced the same Phase 0 transient artifact-path
  unwrap. Its exact retry and the complete root rerun passed.
- The required RepoPrompt Oracle review could not start after its MCP transport
  closed. An independent full-diff review found six issues; all were corrected
  and the affected final gates passed.

## Close review checklist

- [x] Five production targets and exactly one new product are present.
- [x] No Phase 2 declaration or runtime authority moved.
- [x] No Phase 8 headless behavior, package, install, or smoke lane exists.
- [x] No placeholder test target, root, lane, or XCTest exists.
- [x] Seven-prefix optimizer vocabulary and absence semantics are implemented.
- [x] Negative dependency/import/declaration/C/package guards pass.
- [x] Final target/product/list/ledger/Xcode/style/test/package ladder passes.
- [x] Explicit Phase 1 GO/NO-GO disposition appended.

## Close disposition — 2026-06-21 (append-only)

**GO.** Phase 1 is complete. All five production targets and all three products
compile; the graph/source guards reject reverse or extra edges, forbidden
imports, copied Phase 2 declarations, unprefixed CE C symbols, app/headless
packaging overlap, and placeholder test targets. Root/provider IDs and scenario
totals are unchanged, all five reserved prefixes reconcile at zero, generated
Xcode is deterministic with the existing three convenience workflows, and
style, guardrails, full tests, and package validation pass.

Phase 2 may begin only as a separate change that moves ledger-owned neutral
declarations with their faithful tests. Phase 8 headless runtime, state,
packaging, install, and smoke behavior remain explicitly unimplemented.
