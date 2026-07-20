---
name: rpce-swift-concurrency-fix
description: Diagnose and repair a bounded set of Swift concurrency compiler errors or warnings in RepoPrompt CE, including actor isolation, Sendable crossings, task captures, continuations, cancellation, global mutable state, and Objective-C interoperability. Use for a specific diagnostic, file, target, or coherent diagnostic family. Preserve behavior and avoid unrelated refactors; use the migration skill for project-wide settings, inventory, sequencing, or progress planning.
---

# RepoPrompt CE Concurrency Fix

Resolve the requested diagnostics with the smallest semantic change that makes the runtime ownership explicit. Do not treat an annotation-only compile as proof of safety.

## Required context

1. Read `references/diagnostic-playbook.md`, classify the boundary, then load the matching detailed reference below. Load another only if the traced boundary spans families:
   - `references/isolation-sendability-samples.md` for actor isolation, Sendable crossings, global state, isolated conformances, reentrancy, or escape-hatch repairs;
   - `references/tasks-cancellation-continuations-samples.md` for task ownership, detached work, continuation races, streams, or deterministic concurrency tests;
   - `references/synchronization-interop-samples.md` for locks, queues, `@unchecked Sendable`, Objective-C/C callbacks, runtime assertions, or `@preconcurrency`.
2. Read `references/repository-patterns.md` before changing an existing RepoPrompt task, continuation, synchronization, UI-publication, or concurrency-utility pattern.
3. For Swift 6.2 settings or execution semantics, read `../rpce-swift-6-concurrency-migration/references/official-swift-6-2.md` and its linked local samples.
4. Inspect the owning target's actual manifest settings before interpreting a diagnostic.
5. Before running builds or tests, read root `AGENTS.md` and the applicable section of `../rpce-swift-6-concurrency-migration/references/validation-matrix.md`.

## Workflow

### 1. Capture the failure

Record:

- exact diagnostic text;
- package, target, file, and declaration;
- compiler and Swift language mode;
- strict checking, default isolation, and upcoming-feature settings;
- whether the issue is first-party, imported, generated, or dependency code.

### 2. Trace the boundary

Follow the value, closure, or mutable state through its real execution path. Identify:

- source and destination isolation domains;
- owning actor, task, lock, queue, or immutable value;
- suspension and reentrancy points;
- task lifetime and cancellation owner;
- callback/continuation completion paths;
- public API or interoperability constraints.

State the runtime invariant the compiler cannot see. If it is unknown, investigate rather than selecting an escape hatch.

### 3. Choose the smallest semantic fix

Prefer, in order:

1. express the correct actor or global-actor isolation;
2. keep non-Sendable state within one isolation domain;
3. transfer immutable or genuinely `Sendable` snapshots;
4. give unstructured work an explicit owner or replace it with structured concurrency;
5. protect short synchronous mutable state using an established actor/lock/queue invariant;
6. adjust a boundary API when the existing contract is the root cause.

Use `@concurrent` only for intentional off-actor async work after verifying Swift 6.2 settings and sendability crossings.

### 4. Verify immediately

After reading the repository validation instructions, recompile the smallest supported affected product through conductor, then run focused tests for the changed contract. Use `$rpce-test-quality` before adding timing-sensitive concurrency tests.

Stop when the requested diagnostic family is resolved. Record causally unrelated diagnostics for the migration inventory rather than expanding the change.

## Escape-hatch gate

Do not add `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, `MainActor.assumeIsolated`, `Task.detached`, or a new manual lock merely to silence the compiler.

If no checked design is practical, document:

- protected state and allowed operations;
- synchronization or ownership mechanism;
- why it prevents concurrent invalid access;
- cancellation, lifetime, and reentrancy behavior;
- why checked alternatives are impractical;
- focused verification;
- audit or removal condition.

## Anti-refactor rules

- Do not rename, reorganize, or broadly reformat adjacent code.
- Do not modernize unrelated async APIs.
- Do not convert neighboring types to actors without a traced invariant requiring it.
- Do not replace established synchronization without a demonstrated defect.
- Do not blanket-apply `@MainActor`.
- Do not assume all GCD, locks, or detached work is wrong; prove whether the ownership is valid.
- Do not use sleeps as deterministic concurrency verification.

## Handoff

Summarize the diagnostic, confirmed boundary, invariant, minimal fix, escape-hatch decision, focused build/test evidence, and deferred unrelated findings.
