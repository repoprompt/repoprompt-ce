# Migration inventory

Store the live inventory in a task-specific plan or local `docs/investigations/` artifact. Do not commit investigation artifacts unless explicitly requested. Keep raw logs in conductor job storage and summarize only durable evidence.

## Inventory schema

| Field | Purpose |
|---|---|
| Package / target | Compilation and configuration boundary |
| File / declaration | Exact owning source |
| Diagnostic / category | Global state, sendability, isolation, task capture, continuation, interop, or other stable family |
| Current settings | Language mode, strict checking, default isolation, upcoming features |
| Isolation boundary | Main actor, global actor, actor instance, nonisolated, task capture, global state, C/Objective-C |
| Runtime risk | Race, stale state, deadlock, lost cancellation, leak, ordering, UI violation, compile-only |
| Root-cause confidence | Confirmed, plausible, or unknown |
| Proposed fix class | Static isolation, value snapshot, ownership, synchronization, API adjustment, dependency |
| Escape hatch | Existing, proposed, or none; include invariant and removal/audit condition |
| Dependency / blocker | Upstream target, imported API, package, or phase |
| Phase / status | Baseline, active, fixed, deferred, blocked |
| Validation evidence | Conductor ticket, log path, focused suite, profile artifact |

## Baseline checklist

- Record Xcode, Swift, SDK, and manifest revisions.
- Capture current coordinated builds before enabling new checks.
- Record pre-existing warnings and failures.
- Map the package/target dependency graph.
- Count findings by category without treating count as severity.
- Identify public API and mixed-language boundaries.
- Record existing escape-hatch invariants before changing them.
- Establish performance baselines only for user-visible or scale-sensitive paths.

## Phase entry template

- **Scope:** package, targets, and diagnostic family
- **Settings before:** language mode, checking, isolation, upcoming features
- **Invariant:** behavior that must remain true
- **Non-goals:** adjacent cleanup intentionally excluded
- **Baseline evidence:** conductor ticket/log and focused tests
- **Expected crossings:** actors, tasks, callbacks, processes, C/Objective-C, dependencies
- **Exit gate:** compile, tests, escape-hatch review, public API review

## Phase exit report

Report settings after the phase; findings fixed, deferred, and exposed; behavior or API changes; escape-hatch changes and invariants; validation evidence; blockers; risks; next phase; and explicit non-goals.
