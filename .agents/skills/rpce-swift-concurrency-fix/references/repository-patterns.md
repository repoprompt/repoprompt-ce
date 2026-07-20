# RepoPrompt CE concurrency patterns

Use these as review prompts, not copy-paste prescriptions. Read current implementations and tests before reusing or changing them.

## Existing primitives

`Sources/RepoPrompt/Infrastructure/Concurrency` contains:

- `AsyncMutex` for cancellation-aware async mutual exclusion;
- `AsyncScope` for awaited setup/cleanup lifetime management;
- `BoundedOrderedConcurrentMap` for bounded structured parallel mapping with ordered results;
- `TaskSemaphore` for actor-backed concurrency limiting.

Prefer a proven existing primitive when its contract exactly matches the needed invariant. Do not introduce a second synchronization authority.

## Task ownership

For every escaping or unstructured task, identify:

- creator and owner;
- cancellation trigger;
- completion observation;
- priority and isolation inheritance;
- captured object lifetime;
- whether the task survives workspace/window/provider teardown.

Use structured concurrency when the child lifetime belongs to the current operation. Keep detached tasks only when the isolation and lifetime break is intentional and documented.

## Continuations and streams

Audit:

- synchronous callback completion during setup;
- cancellation before and after registration;
- duplicate callbacks;
- teardown without callback;
- buffering and backpressure;
- checked continuation exactly-once completion;
- stream termination and retained producer state.

Do not block an executor waiting for async completion.

## UI publication

Compute off-main with immutable or `Sendable` snapshots, or with compiler-proven `sending`/region-isolated transfers that leave no concurrent aliases. Publish app-visible state at an explicit main-actor synchronization point, preferably coalesced when updates are frequent.

Do not move a whole service onto `MainActor` merely because one callback updates UI.

## Locks and queues

Locks and serial queues can be valid for short synchronous state protection or imported APIs. Require:

- one lock/queue authority for all mutable access;
- no `await`, blocking async wait, or unknown/user callback in the critical section;
- documented lock ordering if more than one lock is involved;
- no accidental main-thread or cooperative-pool blocking.

## Validation

Use conductor-coordinated commands from the migration skill's `references/validation-matrix.md`. Favor gates, explicit continuations, controllable clocks, and observable state over sleeps or probabilistic stress alone.
