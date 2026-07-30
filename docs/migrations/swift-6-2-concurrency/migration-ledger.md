# Swift 6.2 Concurrency Migration Ledger

Updated: 2026-07-20

## Toolchain and policy

- Active compiler: Apple Swift 6.2.4 (`swift-driver` 1.127.15), arm64-apple-macosx26.0.
- Root package tools version: 6.2; package default and all non-Item-6 targets remain in Swift 5 language mode.
- Migration policy: target-scoped complete strict-concurrency checking first, followed by independently evidenced target-local `.swiftLanguageMode(.v6)`. No default MainActor or Swift 6.2 execution/isolation feature is adopted by this tranche.

## Completed boundaries

| Boundary | Commit / state | Language/checking | Evidence |
| --- | --- | --- | --- |
| Dependency/grammar upgrade and broad parser-lock removal | `3b330db9fdfad6c23e715c84d47877995214f1c7` | Swift 5 | Exact SwiftTreeSitter 0.10/runtime 0.25.10 and grammar revisions; scanner shim retained after clean-link proof. |
| Official-source cleanup (Item 8) | `bb8c38e664c4f7fa99cf500a1c89bb757ccfe242` | Swift 6 unchanged | PHP resolves from the official v0.24.2 source with updated cache identity; the wrapper URL migration remains blocked by Neon’s released dependency identity. |
| Generated-Xcode official-graph acquisition (Item 9) | `9a4a353933dfa488acabcb4c27ad41c6f293377d` | Swift 6 unchanged | Xcode package acquisition retains the authoritative graph and uses a process-local same-host HTTPS transport for public GitHub SSH submodule URLs; no dependency target, identity, revision, source, or language setting changes. |
| Official JavaScript/Python scanner cleanup (Item 10) | Blocked on an upstream release | Swift 6 unchanged | Official `v0.25.0` and default-branch manifests still omit both scanner objects in the root graph; a clean shim-free link failed on all ten external-scanner ABI symbols. |
| Exact grammar semantic-version requirements (Item 12) | `a6c17da25534ae73f4bfec546cfc95f19098c732` | Swift 6 unchanged | Every released/buildable grammar uses an exact semantic version while resolved commits and CodeMap cache identity remain unchanged; Dart and Neon remain evidenced revision exceptions. |
| Highlighting query compatibility and C# coverage (Item 13) | `a8885ac9b4fefb7e3af170b5899ad80d5037d7da` | Swift 6 unchanged | All 14 app-owned highlighting queries compile against their registered grammars; C# completes the 14-language CodeMapCore fixture/golden matrix without changing the existing 13 outputs. |
| `RepoPromptRegexCore` | extraction `6feead2fcfbbd53bc9d4b9d0255401ec51bfd374`; Item 6 this change | Swift 6 | Production and owner-test targets compile with `-swift-version 6`; eight owner tests and Swift 5 app-consumer linkage pass. |
| `RepoPromptCodeMapCore` / owner tests | extraction `22bfff1c5904d5f02c0a881055142c94f4783a84`; Item 6 this change | Swift 6 | Production and owner-test targets compile with `-swift-version 6`; 16 owner tests, mixed-mode app tests, and both Swift 5 product builds pass. |

## Item 3 ownership record

Moved to `RepoPromptCodeMapCore`:

- provenance-free decoder policy/raw digest/decoded result vocabulary with pipeline and artifact-key canonical encoding;
- immutable grammar/pipeline descriptors, exact CodeMap-only query bytes, extension registry, parse limits, and synchronous Tree-sitter execution;
- syntax artifact outcomes/builder, capture indexing, extraction memoization, signature/type helpers, language strategies, generator, and path-free canonical artifact rendering;
- invocation-local parser, query cursor, extraction memo, and performance collector state.

Split or retained in `RepoPromptApp`:

- decoder and SHA construction authority, exact raw bytes, validation tokens, Git/worktree provenance, and workspace decoder;
- direct SwiftTreeSitter highlighting linkage and mutable highlight/language caches;
- build permits, priority, pre/post parse cancellation, coordinator flights/fairness, environment flags, and performance aggregation;
- CAS/container/catalog/locator/manifest persistence, workspace/Git authority, token and path/import presentation, selection-graph policy, UI, and MCP.

Test ownership:

- `RepoPromptCodeMapCoreTests` is the sole owner of pure CodeMap parsing fixtures, goldens, canonical byte tests, deterministic negative outcomes, registry/query bytes, and concurrent all-language initialization/build checks.
- `RepoPromptTests` retains adapter, coordinator/cancellation, persistence/CAS, workspace, presentation, highlighting, UI, and MCP integration tests.

## Strict-concurrency diagnostics and escape-hatch inventory

- `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptRegexCoreTests`, and `RepoPromptCodeMapCoreTests` now use target-local Swift 6 language mode. Verbose SwiftPM compiler invocations contain `-swift-version 6` for exactly those four modules; `RepoPromptApp`, `RepoPromptTests`, and `RepoPromptMCP` remain `-swift-version 5` consumers. No invocation adds default MainActor, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, or another execution/isolation feature.
- Parser and cursor objects remain invocation-local and never cross a Sendable boundary. Public cross-target graphs remain package-visible immutable Sendable values.

| Escape hatch | Scope | Preserved invariant | Audit / removal condition |
| --- | --- | --- | --- |
| `nonisolated(unsafe)` on standard-library `Regex` constants | 25 existing annotations in `LanguageTypeExtractor` | Every value is immutable and initialized once; matching is nonmutating; no mutable shared cache or escaping match state is hidden by the annotation. The annotation exists because the standard-library `Regex` output metadata used here does not expose Sendable conformance. | Re-audit when the deployed Swift standard library makes these concrete/type-erased `Regex` values Sendable; remove only when the active minimum toolchain compiles the declarations without the escape hatch. |
| `PCRE2Regex: @unchecked Sendable` | One existing class in `RepoPromptRegexCore` | Compilation, including JIT, completes before publication and the compiled `pcre2_code` is immutable afterward. Ordinary matches allocate independent match data/context; `MatchSession` owns mutable state, is deliberately non-Sendable, and is confined to one sequential consumer. A live call retains the regex, preventing deinitialization from racing the call. The current implementation therefore needs no lock around immutable compiled code. | Re-audit on a PCRE2 upgrade or any change that shares mutable match/session state, mutates compiled code after publication, or changes lifetime ownership. |

No new escape hatch or source annotation was added for Item 6. The four target logs and raw verbose invocation evidence contain zero diagnostics attributed to their source or owner-test paths.

## Item 3 evidence

- Baseline golden: conductor ticket `880de0e6…` — 13 language fixture/golden comparisons passed before extraction.
- Baseline syntax artifact: ticket `b10a0628…` — six deterministic artifact/outcome tests passed before extraction.
- Baseline authoritative test list: ticket `fdb54f9e…`.
- Extracted canonical key/registry/concurrency suite: ticket `d690b814…` — passed under the owner target.
- Complete owner target: ticket `5928f578…` — 16 tests passed (9 canonical key/registry/concurrency, 1 golden corpus test covering 13 files, and 6 artifact/outcome tests); log grep found zero warnings or errors attributed to `Sources/RepoPromptCodeMapCore` or `Tests/RepoPromptCodeMapCoreTests`.
- Focused app integration: ticket `e5eacaf7…` — 95 adapter, app golden/presentation, coordinator, container, store, and workspace-binding tests passed, including 35 coordinator retry/cancellation/CAS tests.
- Byte-identity audit: all 27 moved fixture/golden resources and all 13 CodeMap query literal bodies exactly match `HEAD` before extraction; `Package.resolved` is unchanged.
- Authoritative root test list: ticket `c590972a…`; exact ledger verification passed at 3,451 IDs with final root ticket `3f92a87b…` and provider ticket `4257122f…`.
- SwiftFormat mutation: ticket `e673cfbe…`; strict formatter/lint: final ticket `e7c517b7…`; source/license guardrails passed.
- Coordinated ad-hoc debug package and authorized relaunch: ticket `25a7eb0b…`; package/build/signature/launch completed. The debug app uses documented ephemeral secure storage; no live MCP behavior test was required for the synchronous internal seam.

## Item 6 Swift 6 language-mode evidence

- Swift 5 staged baseline: Regex owner tests ticket `7dfd535b…`; CodeMap owner tests ticket `2016de2d…`; both passed before the manifest change.
- Swift 6 owner tests: Regex ticket `7730d2a9…` (8 tests); CodeMap ticket `f97a9002…` (16 tests); zero failures and zero in-scope compiler diagnostics.
- Verbose compiler invocations under Apple Swift 6.2.4: `RepoPromptRegexCore`, `RepoPromptCodeMapCore`, `RepoPromptRegexCoreTests`, and `RepoPromptCodeMapCoreTests` each received `-swift-version 6`. Both CodeMap targets retained their conditional manifest `DEBUG` definition. `RepoPromptApp` and `RepoPromptTests` received `-swift-version 5`; the coordinated MCP build description also recorded `RepoPromptMCP` at `-swift-version 5`.
- Mixed-mode app tests: coordinator ticket `c21ae5d2…` (37 tests), source-snapshot adapter ticket `16782ea7…` (1 test), and app CodeMap golden/presentation ticket `499e8a76…` (4 tests); zero failures.
- Swift 5 consumer products: RepoPrompt ticket `6c091ce4…`; repoprompt-mcp ticket `afed7b28…`; both built successfully.
- Phase boundary: full root ticket `a5f3c831…` passed in 9m28s; full provider ticket `11ad3aad…` passed; lint ticket `ce6cd2f4…`, 23 generator contract tests, and source/license guardrails passed.
- Package default remains `swiftLanguageModes: [.v5]`; `Package.resolved` and all source files are unchanged.

## Item 8 official-source cleanup evidence

- Official `tree-sitter/tree-sitter-php` tag `v0.24.2` resolves to `5b5627faaa290d89eb3d01b9bf47c3bb9e797dea`. The previously resolved fork revision descends from that commit and changes only `.github/workflows/lint.yml`, so `Package.swift`, headers, parsers, scanners, and queries are byte-identical. The manifest pin, resolved pin, PHP grammar/cache revision, owner-test registration, license attribution, inventory, and guardrail now use the official source.
- Official `tree-sitter/swift-tree-sitter` tag `0.10.0` resolves to the existing `f97df585296977d8fcaf644cbde567151d1367b8` commit and identical tree. The wrapper URL was not changed because pinned Neon `07a325403534f4759c814aff0a58ac69144a524c` and every published Neon tag through `0.6.0` still declare the legacy `ChimeHQ/SwiftTreeSitter` package identity. A clean resolver probe with the official root URL produced separate `swift-tree-sitter` and `swifttreesitter` packages; a mirror probe failed because Neon names the legacy identity. No released official combination can currently preserve the required APIs and one wrapper/runtime identity without a fork, branch pin, mirror, vendoring, or unrelated modernization.
- Target-local Swift 6 settings and behavior are unchanged. `TreeSitterScannerSupport` and generated-Xcode behavior remain untouched for Items 9–10.
- Validation: CodeMap owner suite ticket `0be39f86…` passed all 16 tests, including the then-current 13-language golden corpus and registry/cache-identity assertions; RepoPrompt build ticket `b6074b7f…` and MCP build ticket `89085163…` passed; format ticket `f72a1851…` changed no files; strict lint ticket `595357fc…` passed.

## Generated-Xcode status

Item 9 traced the acquisition boundary with an isolated Xcode source-package directory. The official SwiftTreeSitter and Neon gitlinks materialized at their pinned commits; the remaining failure was the pinned Dart grammar’s unreachable test-support gitlink, whose public GitHub URL is expressed as `git@github.com:` and therefore required an SSH credential even though the repository is public. Xcode performs this recursive repository update before RepoPrompt scheme reachability can exclude external test support.

The generated-workspace validator now appends a process-local Git configuration entry that uses the same official GitHub repository over HTTPS while preserving any caller-supplied `GIT_CONFIG_*` entries. It creates no fork, mirror, branch pin, vendored source, persistent Git configuration, package override, or extra scheme target. `Package.swift`, `Package.resolved`, all grammar dependencies, `TreeSitterScannerSupport`, and the four target-local Swift 6 settings remain unchanged. `make xcode` runs this acquisition/list gate before opening the workspace.

Validation: all 26 focused generator contracts passed. A clean `make xcode-clean && make xcode-validate` regenerated the workspace and completed `xcodebuild -list`, discovering the native `RepoPrompt` product and all three repository convenience schemes against the pinned official package graph.

## Item 10 official scanner cleanup blocker

- Reverified on 2026-07-20 against the official repositories. JavaScript’s latest release `v0.25.0` is `44c892e0be055ac465d5eeddae6d3e194424e7de`; its default `master` is `58404d8cf191d69f2674a8fd507bd5776f46cb11`. Python’s latest release `v0.25.0` is `293fdc02038ee2bf0e2e206711b69c90ac0d413f`; its default `master` is `26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64`. For each grammar, the released and default-branch `Package.swift` files are byte-identical (JavaScript SHA-256 `88581869cc5b6cde3caeb57cc1c96203da9318e93ceec3aa95e63b525b439d69`; Python SHA-256 `5baeba461ea73c918690bba570031e490236767db30bf3312c6d3521d3a17955`) and still use the process-relative `FileManager.default.fileExists(atPath: "src/scanner.c")` probe before appending the scanner source.
- A detached clean worktree at `9a4a353933dfa488acabcb4c27ad41c6f293377d` removed only the `TreeSitterScannerSupport` target and the CodeMap core dependency edge. A fresh official-source resolution/build used only a transient HTTPS transport canonicalization for the pinned Dart package’s public SSH-form submodule URL; it created no fork, mirror, override, source mutation, or persistent Git configuration. Coordinated owner-suite ticket `696b3f01-56b6-4c23-a396-a88dd69002a6` reached the final arm64 link and failed before tests ran.
- The JavaScript and Python grammar build directories contained `src/parser.c.o` and no `scanner.c.o`. An `nm` scan of all produced objects and archives found undefined references and no definitions for `tree_sitter_javascript_external_scanner_{create,destroy,scan,serialize,deserialize}` and `tree_sitter_python_external_scanner_{create,destroy,scan,serialize,deserialize}`. The linker reported those exact ten missing symbols from each grammar’s `parser.c.o`.
- Because the clean link failed, all-language queries, malformed-source behavior, concurrent builds, and goldens could not execute without the shim. The experiment worktree and transient Git configuration were removed, the primary repository was restored clean, and `TreeSitterScannerSupport`, copied sources/headers, checksums, attribution, source-layout exception, and guardrails remain unchanged. Removal is blocked solely on an official merged and released manifest revision that compiles both scanners in the root package graph.

## Item 11 independent review and hosted acquisition follow-up

- Independent range inspection and RepoPrompt Oracle review found no unresolved correctness, security, compatibility, dependency/cache identity, Xcode acquisition, Swift 6 preservation, or documentation defect in Items 8–10. Local lint, both products, full root/provider suites, guardrails, 26 generator contracts, clean Xcode validation, contribution `pr-ready`, and the authorized live CodeMap/Agent Mode smoke all passed.
- The first exact-head hosted run `29758056093` then exposed a clean-cache acquisition gap outside the generated-Xcode validator. App shards and the Sentry build failed before compilation because SwiftPM recursively initialized the pinned Dart grammar's public `git@github.com:tree-sitter/tree-sitter` test-support submodule without the validator subprocess's HTTPS transport environment. The provider and secret-scan jobs, which do not acquire the root app graph, passed.
- The hosted CI workflow now supplies the same process-local, same-host `git@github.com:` → `https://github.com/` canonicalization to its job subprocesses. It creates no persistent Git configuration, credential dependency, fork, mirror, package override, source mutation, revision change, duplicate package identity, or cache-key change. Generated-Xcode validation retains its own subprocess boundary for local/manual acquisition.

## Item 12 exact grammar requirement evidence

- Released/buildable grammar requirements are exact C `0.24.2`, C++ `0.23.4`, C# `0.23.5`, Go `0.25.0`, Java `0.23.5`, JavaScript `0.25.0`, Python `0.25.0`, Rust `0.24.2`, TypeScript/TSX `0.23.2`, Ruby `0.23.1`, PHP `0.24.2`, and Swift `0.7.3-with-generated-files`. SwiftPM accepts the Swift companion tag as an exact semantic-version prerelease and resolves it to the existing buildable commit `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5`.
- A fresh temporary-package resolution, using only the existing process-local HTTPS transport canonicalization for Dart's public SSH-form test submodule, resolved all 12 released grammars plus SwiftTreeSitter, Dart, and Neon to their pre-change commits. The committed `Package.resolved` records the exact versions and identical revisions; CodeMap grammar revision/cache identity values remain unchanged.
- Dart remains at canonical revision `be07cf7118d3dba06236a3f19541685a68209934` because its maintained repository publishes no releases. Neon remains at exact revision `07a325403534f4759c814aff0a58ac69144a524c` because its newest release, `0.6.0`, is older and incompatible with SwiftTreeSitter `0.10.0`; no downgrade or moving branch dependency was introduced.
- Validation: CodeMap owner suite ticket `40f621f9…` passed all 16 tests, including the then-current 13-language golden corpus and exact registry/cache-identity assertions; RepoPrompt ticket `f00815e3…` and MCP ticket `95d3166c…` built successfully; formatter ticket `648ee581…` changed no files and strict lint ticket `a835e4f9…` passed; all 26 generated-workspace contracts and clean `make xcode-clean && make xcode-validate` acquisition/list validation passed.

## Item 13 query compatibility and C# coverage evidence

- The app-owned highlighting registry has one query for every `LanguageType` case, and `SyntaxHighlightingQueryTests` compiles all 14 queries against the corresponding grammar descriptor. This catches stale node names and anonymous-token patterns outside CodeMap-only query ownership.
- The invalid Dart `dynamic` token and unsupported C++ module tokens/nodes were removed after direct compilation against the pinned grammars. The pinned Swift grammar accepts the existing `"nil"` token query, so no speculative Swift query change was made.
- The C# fixture/golden completes the 14-language CodeMapCore output matrix. All 13 pre-existing fixture and golden files are byte-identical to `49f8aff3`; CodeMap query bytes, grammar revisions, artifact identity, synchronous invocation-local parser/query execution, and target-local Swift 6 settings are unchanged.
