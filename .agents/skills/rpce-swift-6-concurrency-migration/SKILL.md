---
name: rpce-swift-6-concurrency-migration
description: Plan, inventory, stage, execute, or review RepoPrompt CE's project-wide migration to Swift 6.2 concurrency checking and Swift 6 language mode. Use when auditing packages, targets, settings, diagnostics, unsafe escape hatches, migration phases, blockers, or validation evidence across the root and provider packages. Do not use for a bounded diagnostic repair unless it changes migration policy or sequencing.
---

# RepoPrompt CE Swift 6.2 Concurrency Migration

Treat repository source, current compiler output, AGENTS.md, and official Swift documentation as authority. Do not infer language semantics from the toolchain version alone.

## Required reading

Read `references/repository-concurrency-profile.md` first. Load the other references only when the workflow reaches them:

- `references/official-swift-6-2.md` before interpreting or changing language/concurrency settings;
- `references/swiftpm-settings-samples.md` before editing either package manifest or designing a settings rollout;
- `references/swift-6-2-semantics-samples.md` before adopting or diagnosing caller-actor execution, `@concurrent`, default isolation, or isolated conformances;
- `references/migration-inventory.md` when creating or updating the campaign inventory;
- `references/validation-matrix.md` before starting coordinated validation.

Re-read an affected section before a settings change if the information is no longer fresh in context.

## Workflow

### 1. Establish the current state

1. Confirm the active Xcode and Swift compiler versions.
2. Inspect both package manifests and the actual settings of every affected target.
3. Distinguish the Swift tools version, language mode, strict-concurrency checking, default actor isolation, and upcoming concurrency features.
4. Capture a clean coordinated baseline before changing semantics.
5. Record pre-existing warnings or failures separately from migration diagnostics.

Never assume that using a Swift 6.2 compiler means the package is in Swift 6 language mode.

### 2. Build the inventory

Create or update a migration inventory using `references/migration-inventory.md`. Group findings by package, target, diagnostic family, isolation boundary, runtime risk, and dependency relationship.

Inventory at least:

- global and static mutable state;
- `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, and `MainActor.assumeIsolated`;
- detached or escaping tasks and their owners;
- continuations, streams, and cancellation handlers;
- locks, queues, semaphores, and custom concurrency primitives;
- actor reentrancy-sensitive state;
- Objective-C/C and delegate/callback boundaries;
- long-lived Agent Mode, MCP, indexing, persistence, and process tasks.

Do not conclude that an existing escape hatch is wrong or safe from syntax alone. Record its intended invariant and verify the implementation.

### 3. Choose phases from evidence

Prefer this initial order, then adjust it to the verified dependency graph and diagnostic counts:

1. Baseline and inventory.
2. Harden proven invariants while retaining Swift 5 language mode.
3. Stage complete concurrency checking in narrow leaf/headless targets.
4. Migrate MCP and provider boundaries.
5. Migrate app infrastructure and task-heavy feature/runtime code.
6. Migrate main-actor UI and app composition.
7. Switch targets to Swift 6 language mode independently only after the active toolchain probe proves mixed-mode behavior; otherwise use a package-wide fallback after every target meets the exit gate.
8. Adopt Swift 6.2 execution semantics and default isolation deliberately.
9. Profile, optimize, and run the final safety audit.

SwiftPM exposes package-level `swiftLanguageModes` and target-level `.swiftLanguageMode(.v6)`. Verify target-local compiler flags and generated-workspace behavior with the active toolchain before relying on mixed modes. If the probe fails or settings are ignored, retain target-level complete checking and use the documented package-wide fallback.

### 4. Execute one coherent batch

For each batch:

1. Select one package/target boundary and one settings step or diagnostic family.
2. State the runtime invariant and explicit non-goals.
3. Use `$rpce-swift-concurrency-fix` for bounded compiler-diagnostic repairs.
4. Rebuild the smallest supported affected product through conductor.
5. Run focused tests for observable cancellation, lifetime, ordering, isolation, or interoperability behavior.
6. Update the inventory and escape-hatch ledger.
7. Stop before unrelated cleanup or architecture modernization.

Use `$rpce-test-quality` to decide whether concurrency regression coverage is durable and deterministic. Use `$rpce-maintainer-guidance` for broad ownership, performance, coalescing, or observability decisions.

### 5. Adopt Swift 6.2 semantics separately

Treat these as independent design decisions:

- Swift 6 language mode and complete data-race checking;
- caller-actor execution for nonisolated async functions;
- isolated-conformance inference;
- default `MainActor` isolation;
- explicit `@concurrent` offloading.

Do not apply default `MainActor` isolation package-wide merely because RepoPrompt is a macOS app. Shared protocols, workspace core, MCP, and provider libraries have different isolation needs.

Before enabling `NonisolatedNonsendingByDefault`, audit code that relies on a nonisolated async call leaving the caller's actor. Add `@concurrent` only when off-actor execution is intentional and its arguments and results satisfy the crossing.

### 6. Close a phase

Require:

- coordinated builds for every affected product;
- focused tests for changed behavioral contracts;
- no new unsafe escape hatch without a written invariant and audit/removal condition;
- reviewed public API and sendability changes;
- updated inventory, validation tickets/logs, blockers, and non-goals.

Run broader validation only at phase boundaries or when the changed boundary requires it.

## Guardrails

- Fix runtime ownership and isolation causes; do not annotate solely to silence diagnostics.
- Prefer structured concurrency and explicit task ownership.
- Treat every suspension point as a reentrancy boundary.
- Require continuations to finish exactly once across success, failure, and cancellation.
- Do not replace established locks, queues, or primitives without a demonstrated defect.
- Do not mix a target or package language-mode switch with unrelated refactoring.
- Keep raw compiler logs in conductor storage or local investigation artifacts; keep only summarized evidence in the migration inventory.
- Never launch or stop the visible app without explicit user approval.

## Handoff

Report current compiler and package settings, baseline command/ticket/log, diagnostic counts, completed and remaining phases, escape-hatch changes, validation evidence, blockers, risks, and explicit non-goals.
