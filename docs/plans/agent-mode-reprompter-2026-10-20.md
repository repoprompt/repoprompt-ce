# Agent Mode Re-prompt — v2

## History

The October 20 v1 implementation used a modal review editor and optional Oracle/Context Builder consultations. User testing replaced that design before release. v2 removed the modal, consultants and selection-commit plumbing in favor of tool-less streaming into the existing composer. v2.1 added compact original comparison, repeat/undo shortcuts, profile-scoped modes and a concrete model picker. The obsolete v1 execution ledger and unshipped compatibility policy are intentionally removed; Git retains the implementation history.

## Current v2 contract

### Composer and lifecycle

- The first Send prepares; Review before sending is the default. No submit claim is held during preparation. An operation UUID, per-call revision, canonical draft generation and 40 ms coalesced publications fence streaming updates. The next Send acquires a fresh ordinary composer claim and sends the exact edited draft.
- The existing capped-height text field is read-only while streaming/refining or answering questions. Text alone is rewritten; attachments, tagged files and workflow selection retain their existing owners. All local attachment intake and removal must be gated while preparation owns the composer, including delayed picker/drop completions.
- The strip displays the actual model, honest elapsed time, Cancel and Send original after five seconds. Completed review shows the first original inline (dimmed, expandable), adjacent Revert and keyboard hints. Only generating/refining spins, never completed review or routing speculation. The v2.1 stuck spinner was a cached pill snapshot not refreshed on phase changes; the operation's post-mutation callback now refreshes it.
- Return prepares an unprepared enabled draft or sends a prepared draft. Cmd+Return explicitly prepares for Review, including one-shot with the pill off. Repeating an unchanged rewrite uses the first original; edited text becomes the new source while the first original remains the comparison/restoration reference. Shift+Return remains newline. Existing interactive-review shortcuts retain ownership. Cmd+Return formerly fell through to ordinary Return in this local editor; the edit-review card's Cmd+Return Accept remains untouched because Re-prompt refuses while interactive review owns input.
- Esc during preparation cancels/restores; Esc/Revert after completion restores the original in one undo transaction and keeps the rewrite recoverable. Late chunks cannot regain authority after cancel, tab/session replacement, Stop or target/settings changes.
- Invalidation restores the first original when the live draft is still operation-owned. User edits are never overwritten: an unresolved recovery offers Restore original / Keep rewrite and prevents Return from silently re-rewriting generated text. Both original and partial/completed/edited alternatives remain accessible. A kept/restored rewrite authorizes only its exact draft bytes through a fresh local claim, retaining original slash classification; later edits require a new explicit choice. Successful submission consumes that recovery authority, while failure retains original/rewrite choices. A newer explicit preparation supersedes old recovery authority without deleting its text. Inactive/replaced sessions cannot overwrite the active composer.
- Send automatically is an opt-in profile preference. Successful completion emits a one-use intent consumed through a fresh submit claim. Any clarifying questions, including skip-all, force Review. Slash-leading generated or edited text (after leading whitespace) also forces Review: provider-native command interpretation is not assumed safe. Review displays “Starts with / — your agent may treat it as a command”. A deliberate subsequent Send may pass that text to the provider; RepoPrompt skill expansion remains bypassed for rewritten text.

### Questions, output and isolation

- Markdown body streams directly, with headings only when useful and trivial prompts returned near-identically. Optional framed trailing questions metadata is incrementally withheld, including delimiter prefixes, and validated only when complete. At most three questions, at most one refinement rebuilt from original + substantive answers; skip-all does not refine.
- Questions appear in a transient transcript slot using the timeout-free ask_user wizard, labeled Before sending. They are excluded from implementing-agent/provider history.
- Side requests are tool-less and stateless. Native Claude uses request-scoped print NDJSON streaming with empty MCP configuration and no inherited tools/workspace; other providers use streamMessage. No consults, file contents, git packaging, Oracle chat links or attachment payloads are included. The cheap manifest contains root names and selected relative paths only.
- Safety limits: original 32 KiB; guidance 16 KiB; answers 16 KiB; manifest 4 KiB; serialized history 8 KiB; output 80 KiB raw / 64 KiB body / 16 KiB metadata. Truncated/error text is recoverable, never successful auto-send. Safety ceilings are 60 seconds for API calls and 120 seconds for native calls, including effort judgment.
- Session-link, managed/noncomposer, staged slash-command and attachment-only paths bypass preparation entirely. Enabling the pill does not change their ordinary admission policy. Original text controls RepoPrompt slash/workflow classification, not generated text.

### Model, effort and settings

- Profile-scoped model, mode, history and guidance extend schema 13 with requiredSchemaVersion feature fencing, global/workspace copy/reset and stale-draft conflict checks. No migration exists for unshipped Re-prompt sentinels. Unknown explicit model strings are retained but unavailable; unknown mode values fail closed to Review. Real shipped settings compatibility is unchanged.
- The UI never names an abstract default model mode: the picker/header show a concrete resolved name or Choose a model. Default policy is fast current native subscription tier → other connected native subscription tier → bounded configured API fast tiers → none. No arbitrary catalog-first or primary-Oracle fallback. Model resolution is frozen for an operation/retries; failure never silently switches billing routes. Explicit selections never fall back. Runtime-unavailable models require a user choice.
- Current preferred tiers are native Claude Code Sonnet 5.5 Low and Codex GPT-6.1 Sol Low; API fallback tiers are Sonnet 5.5, GPT-6.1 Sol Low and Gemini 3 Flash. Other models remain explicitly selectable when configured and side-call capable.
- Effort defaults Low for supported variants. With Auto Effort enabled, the existing masked summary, decision policy, backend and coordinator choose the rewriter's effort without changing the implementing session. Explicit service tiers are preserved. Providers without supported effort fields retain provider-native behavior; no unsupported Anthropic API field is invented.
- Settings use the standard model picker, mode row and recent-history toggle. Advanced guidance is collapsed; Restore Default affects guidance only. Saving model/mode/history alone preserves an untouched guidance baseline. Default-equivalent guidance normalizes to nil so future defaults still apply.

### Recent-chat addendum

Include recent chat context defaults on and persists in the profile. Only sessions with at least two previously completed user turns qualify. Include up to three prior user messages as sent (approved rewrites where applicable), plus each turn's final assistant reply trimmed UTF-8-safely to approximately 1.5 KiB, retaining start and end. Serialized total is capped at 8 KiB by dropping oldest first. Only post-compaction turns qualify. No tools, thinking, diffs, attachments, system/workflow wrappers or unfinished turns enter this projection.

The fixed, non-editable contract marks history as BACKGROUND for intent/vocabulary only. Current message wins; history must not create new requirements, constraints or acceptance criteria. Assistant statements are unverified. Redirects/corrections/frustration must abandon, not repeat, the prior failed approach. The strip says with chat context only when excerpts are actually sent. Recipient disclosure includes history and is acknowledged per billing route/history exposure.

### Routing and audit

Speculation starts only after a complete brief, keyed by preparation identity/content, and transfers to the fresh submit claim. Edits, changed candidates/configuration or effective usage state discard it. No-op usage reconciliation must not invalidate an otherwise reusable result. Turn Auto Effort judges the approved draft, with bounded original fallback for oversized text. Minimal audits contain outcomes and speculation/fallback flags, not raw prompts or consultation branches.

## PR #1432 review follow-up (2026-10-21)

- Maintainer and Sentry reports were read in full. Draft invalidation, default-guidance persistence, pill-dependent bypass admission and no-op usage revision findings were confirmed in source.
- Merged origin/main at 446967aa6 without rebasing. PR #1426 remains OPEN (not merged); this branch therefore retains current image attachment API/text-view names. Read-only gating covers present image and tagged-file intake/removal, with delayed-callback revalidation; the future rename must preserve that guard.
- Removed consult-era Oracle context_builder cancellation propagation, unshipped Re-prompt sentinel handling and obsolete v1 ledger material. Object-change freshness checks are coalesced per operation.
- Compiler-index diagnosis reproduced 1,361 wrong-way file edges. The added edge was `Features/AgentMode/Runtime/AgentRepromptOperation.swift → Features/AgentMode/ViewModels/UI/AgentRepromptUIStore.swift`. The operation owns composer revisions, UI publications and recovery, not provider execution; moved it into ViewModels alongside its owning VM. The isolated provider service remains Runtime. No ratchet was increased.
- One independent static review (`untitled-chat-3AF5C8`) verified two additional gaps: stale recovery authority could bypass/block a newer operation, and nil live tab selection fell back to a captured attachment target. Active operations now take precedence, accepted new preparation retires only old recovery authority (not recoverable text), and delayed attachment callbacks require the live selection even when nil. Focused regressions cover both.
- Maintainer-guidance check: the invariant is preservation of first-original and user-edited state, with explicit send/replace choices. Root causes above are confirmed by source paths and focused regression fixtures. Canonical session drafts, operation revisions, scoped settings and fresh submit claims remain authorities. Validation notifications are coalesced to one pending check; no new provider IO/scanning occurs during UI projection. Live-provider command interpretation is deliberately not claimed safe; automatic dispatch falls back to Review.

### Changed files in the review follow-up

One coordinator rename plus 30 modified files (21 source owners, eight existing test files, two docs; no new test-importing files):

- Agent Mode models/routing: `AgentRepromptModelPolicy.swift`, `Routing/UsageBalancing/AgentUsageBalancer.swift`.
- Agent Mode VM: `AgentRepromptOperation.swift` (moved from Runtime), `AgentModeViewModel.swift`, `AgentModeViewModel+DraftsAttachments.swift`, `AgentModeViewModel+Reprompt.swift`, `AgentModeViewModel+RepromptUI.swift`, `UI/AgentModelsSettingsViewModel.swift`, `UI/AgentRepromptUIStore.swift`.
- Composer/settings/shared editor: `AgentInputBar.swift`, `Components/AgentRepromptComposerStrip.swift`, `Components/AgentRepromptPill.swift`, `Settings/Views/AgentRepromptModelPicker.swift`, `Infrastructure/UI/TextField/ResizableTextField.swift`.
- Consult/churn cleanup: `Chat/ViewModels/Oracle/OracleViewModel+MCP.swift`, `Infrastructure/MCP/MCPInvocationContext.swift`, `Infrastructure/MCP/ViewModels/MCPServerViewModel+TabContext.swift` now match main (no net PR changes).
- Core modules: `RepoPromptProviderQuota/ProviderUsageBalancer.swift`, `RepoPromptSettingsCore/AgentRepromptGuidance.swift`, `AgentRepromptModelPreference.swift`, `GlobalSettingsDocument.swift`.
- Existing tests extended/revised: `ProviderUsageBalancerTests.swift`, `AgentRepromptSchemaTests.swift`, `AgentRepromptHistoryTests.swift`, `AgentRepromptSubmissionTests.swift`, `AgentRepromptRoutingIntegrationTests.swift`, `AgentRepromptSessionLinkIsolationTests.swift`, `AgentRepromptPresentationTests.swift`, `AgentRepromptSettingsTests.swift`.
- Docs: this plan and `docs/privacy/telemetry.md`. The obsolete Runtime coordinator path is removed by the rename; no feature/service/test deletions are otherwise needed in this follow-up.

## Verification

Final frozen-source validation (2026-10-21):

| Command | Result | Conductor ticket |
| --- | --- | --- |
| `make dev-test FILTER=AgentReprompt` | 76 tests (72 app + four settings-core), zero failures | `67ae6333-0d1f-420b-8659-83ee36bdc12a` |
| `make dev-test FILTER=AgentSessionLink` | 1,273 tests, zero failures | `5a81a12d-612b-45ec-bcdb-407dace2c421` |
| `make dev-test FILTER=AgentModelsSettings` | 11 tests, zero failures | `b1bdeaac-d8c2-4c6b-9ba3-e55092d32d39` |
| `make dev-test FILTER='GlobalSettings\|ProviderUsageBalancer\|ResizableTextField\|ContextBuilder'` | 257 distinct tests, zero failures; covers GlobalSettings 37, ProviderUsageBalancer four, ResizableTextField seven, ContextBuilder 213 (four overlapping matches run once) | `f70bfa0c-760a-4fb7-a944-b2606647b230` |
| `make dev-swift-build PRODUCT=RepoPrompt` | Passed, no packaging or launch | `9b52002c-0f35-48b1-9d38-128bbd20daaa` |
| `make dev-lint` | Passed; 0/1,851 files need formatting; strict SwiftLint passed | `870854ed-2787-466d-a544-299a85b75517` |
| `python3 Scripts/modularization_index_graph.py check --output .build/modularization/index-check.json` | Passed after the product build: wrong-way edges **1360/1360**, largest cycle 63/66 | Local compiler-index JSON with source hashes |

The first Re-prompt test run exposed missing persistent bindings in two new synthetic active-session fixtures, not compiler failures; corrected their setup before the green rerun. Initial diagnostic/validation jobs were explicitly cancelled before source adjustments, not counted as passing validation. After the first three filters passed, remaining filters were batched without changing their test set to reduce repeated shared-heavy admission waits; the superseded standalone GlobalSettings ticket was cancelled before admission. The final Re-prompt run recorded 15 minutes of coordinated global-heavy admission wait; no queue bypass was used. Only changed Swift files were formatted with the pinned formatter (the large VM's last adjustment used a line range); no formatting baseline was changed.

The staged-index contribution preflight (`.agents/skills/rpce-contribution-check/scripts/preflight.sh commit`) is the final gate before the local commit, rerun after any staging change. Optional full `pr-ready`/unfiltered validation was not run after the lengthy coordinated focused runs; full CI remains necessary. Existing compiler/package warnings are not represented as new failures.

No app launch/relaunch, push, rebase or main-checkout working-tree changes were performed. Live multi-window/provider usability checks remain user-run.

## References

- docs/architecture/source-layout.md
- docs/architecture/provider-plugins.md
- docs/architecture/agent-session-oversight-auto-wake.md
- docs/testing.md
