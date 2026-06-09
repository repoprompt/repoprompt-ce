# Shared Runtime Phase 2 — Slice 3 factual rendering checkpoint

Date: 2026-06-06
Base: `77635d5` (`Characterize Slice 3 Context Builder parity`)

## Scope

This checkpoint moves only deterministic factual prompt rendering into `RepoPromptCore/Prompt`:

- already-classified full-file and sliced-file blocks;
- codemap text supplied as a neutral value, with missing-codemap fallback to source content;
- code fences, range labels, ordering, omission, separators, and trailing whitespace;
- already-classified selected-diff slicing, ordering, two-newline joining, and non-duplication;
- factual `<file_map>`, `<file_contents>`, and `<git_diff>` wrappers.

`PromptPackagingService` remains the app facade. It owns `PromptFileEntry`/`FileViewModel` and `ResolvedPromptFileEntry` conversion, `_git_data` diff-artifact classification, multi-root/display-path projection, `FileAPI` codemap projection, selected-artifact precedence and generated Git fallback, diagnostics, presets, title/date/meta/user/chat/clipboard policy, and Context Builder/MCP envelopes.

## Deferred boundaries

This checkpoint does not move local-definition or codemap projection algorithms, workspace-context projections, token or code-structure projections, MCP DTO/formatter/catalog/dispatch, app-proxy transport, or standalone headless code. Existing Prompt, MCP, and Context Builder call sites remain behind the app facade.

## Frozen behavior

The renderer preserves:

- exact full-file and slice fixtures, including source trailing newlines before closing fences;
- normalized range ordering, descriptions, and blank-line separators;
- custom display-path resolver precedence and multi-root relative labels;
- codemap-only placement in `<file_map>` and one-time missing-codemap content fallback;
- stable selected-diff ordering, selected-artifact precedence, and no generated-diff duplication;
- file tree before codemaps with exactly two newlines;
- nil-content omission while non-nil empty files still render.

## Validation

Passed on the checkpoint worktree:

- `make dev-test FILTER=PromptRenderingServiceTests`
- `make dev-test FILTER=PromptRenderingParityCharacterizationTests`
- `make dev-test FILTER=MCPRenderingParityCharacterizationTests`
- `make dev-test FILTER=ContextBuilderRenderingParityCharacterizationTests`
- `make dev-test FILTER=PromptMigrationRemovalTests`
- `make dev-test FILTER=WorkspaceFileContextStoreTests/testResolvedClipboardPackagingRendersStoreCodemaps`
- `make dev-swift-build PRODUCT=RepoPrompt`
- `make dev-swift-build PRODUCT=repoprompt-mcp`
- `make dev-guardrails`
- targeted SwiftFormat on the five touched Swift files
- `git diff --check`

`make dev-lint` was also run. Its repository-wide SwiftFormat phase is currently blocked by pre-existing drift in unrelated files (for example `WindowStateComposition.swift`, `FileSystemService+Metadata.swift`, and `PCRE2LiteralEscaping.swift`); it reported no touched checkpoint file as a finding. Staged contribution preflight and the commit check run after this record is staged.
