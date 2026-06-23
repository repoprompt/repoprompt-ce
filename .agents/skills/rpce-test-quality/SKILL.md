---
name: rpce-test-quality
description: Select, design, review, consolidate, or remove RepoPrompt CE tests, diagnostic harnesses, and smoke checks by regression value and maintenance cost. Use when the task centers on test, diagnostic, or smoke coverage, including whether a single regression test is worth committing. Do not use for feature or bug-fix work merely because it may need coverage, or for routine test or validation execution.
---

# RepoPrompt CE Test Quality

Protect meaningful current contracts, not changed lines or method counts. Maximize regression signal per maintenance cost. Follow `AGENTS.md` and the repository harness in `docs/testing.md`.

## Decide Before Writing

1. Name the current behavior and plausible defect: user failure, data loss, protocol/security break, race, persistence error, malformed input, or costly operational failure.
2. Search existing direct and outcome-level coverage.
3. Define an observable oracle that distinguishes broken from fixed behavior.
4. Choose the lowest layer that faithfully reproduces the risk.
5. Add, consolidate, redesign, classify as diagnostics, or omit.

For a bug, prefer a test that fails against known-bad behavior. If no stable contract, credible defect, or discriminating oracle can be named, do not add a test.

## Choose the Layer

- **Isolated core:** deterministic decisions, transformations, parsers, state machines, policy, invariants, and failure semantics.
- **Provider package:** provider protocol, codec, translation, launch arguments, and model mapping under `Packages/RepoPromptAgentProviders/Tests`.
- **Root SwiftPM:** module behavior without a GUI, including actors, persistence, fixtures, subprocess adapters, in-process MCP, and deterministic concurrency under `Tests/RepoPromptTests`.
- **Runtime diagnostics:** assembled-app-only rendering, restoration, routing instrumentation, churn, or resource investigations. Require a bounded scenario, privacy-safe machine-readable evidence, entry point, and cleanup path. Without an acceptance threshold, a benchmark is diagnostics.
- **Live/packaged smoke:** real app/MCP wiring, bundle layout, embedded helpers, ownership, signing, provenance, and a few critical journeys.
- **Structural guard:** last resort when executable behavior, compiler boundaries, lint, or guardrails cannot cheaply enforce a narrow constraint.

Do not use smoke as the only protection for deterministic logic.

## Quality Gate

Commit only when the test protects a current contract with plausible impact, fails for a meaningful defect, asserts an observable result, adds distinct coverage at the lowest faithful layer, and is deterministic and maintainable relative to risk.

Redesign or omit invocation-only, no-crash, non-nil-only, source-shape, symbol-presence, constant-restatement, report-only, arbitrary-sleep, coverage-driven, and omnibus tests unless that fact is the explicit contract and no stronger oracle exists.

## Use the XCTest Harness

- List authoritative executable IDs with `make dev-test-list` and `make dev-provider-test-list`.
- Use exact ledger IDs shaped as `root/RepoPromptTests.<Suite>/testMethod` or `provider/RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod`.
- For every executable add, rename, consolidation, or removal, edit `Scripts/Fixtures/test-suite-contract-ledger.tsv` surgically in the same patch. Never regenerate or overwrite the curated ledger.
- Count `scenario_count` as distinct input, boundary, outcome, fixture, or lifecycle scenarios—not assertions. Preserve affected-suite and repository scenario totals across consolidation unless removal is explicitly justified.
- Use reviewed metadata and `current_disposition=retain` for new/retained rows or `consolidated_replacement` for live replacements. Delete stale old rows, keep live-row `replacement_method_id` blank, and record exact old-to-new/removed mappings in replacement notes and the handoff.
- Run `python3 Scripts/test_suite_optimizer.py verify-ledger --ledger Scripts/Fixtures/test-suite-contract-ledger.tsv`. It checks schema, duplicates, and exact live-ID reconciliation only; it does not validate scenario totals or metadata completeness.

## Author and Validate

Assert exact outcomes and negative boundaries. Keep one coherent contract per test; use labeled tables only for equivalent cases. Control time, randomness, locale, environment, resources, ordering, and concurrency; use gates, clocks, or continuations instead of sleeps. Use temporary resources and verify important cleanup or ownership. Add production seams only when narrow, deterministic, behavior-preserving, and justified.

For ordinary changes, run the smallest focused daemon test, the affected target's authoritative list command, and ledger verification; follow repository style/guardrails as applicable. Do not launch the app for ordinary logic.

For optimization/performance campaigns, additionally preserve append-only inventory, baseline, focused, and full-root artifacts plus the scoreboard. Use 3–5 comparable normal samples; never count diagnostic or wake-probe runs as timing samples.

## Required Handoff

Report:

- protected contract, plausible defect, layer, and oracle;
- exact added/renamed/consolidated/removed IDs and old-to-new/removed mappings;
- scenario-count rationale and before/after affected-suite plus repository totals for consolidations;
- surgical ledger update and exact validation commands/results;
- campaign artifact paths, scoreboard entry, and sample validity when applicable;
- coverage omitted, removed, moved to diagnostics, or replaced by a guardrail, with justification.
