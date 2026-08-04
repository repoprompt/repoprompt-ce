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

## Author and Validate

Assert exact outcomes and negative boundaries. Keep one coherent contract per test; use labeled tables only for equivalent cases. Control time, randomness, locale, environment, resources, ordering, and concurrency; use gates, clocks, or continuations instead of sleeps. Use temporary resources and verify important cleanup or ownership. Add production seams only when narrow, deterministic, behavior-preserving, and justified.

Use exact XCTest filters shaped as `RepoPromptTests.<Suite>/testMethod` or `RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod`. For ordinary changes, run the smallest focused daemon test first:

```bash
make dev-test FILTER=RepoPromptTests.<Suite>/testMethod
make dev-provider-test FILTER=RepoPromptClaudeCompatibleProviderTests.<Suite>/testMethod
```

Broaden to the affected target or full suite when the change crosses shared infrastructure, package boundaries, generated surfaces, or test harness behavior. Follow repository style and guardrails as applicable. Do not launch the app for ordinary logic.

For optimization or performance work, define the workload, acceptance threshold, comparable environment, sample validity rules, and retained evidence before measuring. Keep diagnostic and wake-probe runs separate from performance samples. Do not create a replacement test registry, executable census, or repository-wide scoreboard merely to track method counts.

## Required Handoff

Report:

- protected contract, plausible defect, layer, and oracle;
- exact added, renamed, consolidated, or removed test IDs and mappings;
- focused and broader validation commands/results appropriate to the changed boundary;
- measurement protocol and sample validity when performance evidence is applicable;
- coverage omitted, removed, moved to diagnostics, or replaced by a guardrail, with justification.
