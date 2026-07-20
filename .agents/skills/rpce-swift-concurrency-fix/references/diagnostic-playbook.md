# Swift concurrency diagnostic playbook

Use exact compiler output and current settings. Similar wording can have different causes across Swift language modes and upcoming features.

Detailed local examples are split by boundary: `isolation-sendability-samples.md`, `tasks-cancellation-continuations-samples.md`, and `synchronization-interop-samples.md`. Load only the file matching the traced diagnostic family.

| Diagnostic family | First questions | Preferred fix direction | Avoid |
|---|---|---|---|
| Main-actor member from nonisolated context | Is the caller actually UI/main-actor owned? Is the call synchronous or async? | Isolate the correct caller/API, or make the boundary async when a real actor hop is required. | Blanket `@MainActor`, scattered runtime assertions |
| Non-Sendable value risks data races | Which value crosses which isolation boundary? Can it remain isolated or become an immutable snapshot? | Keep access in one domain or transfer a genuinely Sendable value. | `@unchecked Sendable` without a synchronization invariant |
| Global/static mutable state | Who owns mutation and who reads it? Is it UI-owned, actor-owned, locked, or immutable after setup? | Express the true global actor or encapsulate synchronization. | `nonisolated(unsafe)` as a default |
| Actor-isolated protocol conformance | Must every use of the conformance stay on that actor? Do generic/nonisolated consumers require broader use? | Use an explicit isolated conformance when the restricted contract is correct; otherwise redesign the witness boundary. | Making witnesses nonisolated while they still touch isolated state |
| Task capture or task-isolated value | Is the task structured? What isolation does it inherit? Who owns and cancels it? | Use structured tasks, immutable captures, or explicit task ownership. | Detached tasks used as diagnostic erasers |
| Continuation/sendability warning | Can completion occur synchronously, more than once, or during cancellation? | Centralize exactly-once state and make cancellation race-safe. | Resuming twice, leaking a continuation, blocking the executor |
| Lock/queue-protected reference type | Is every access protected by the same mechanism? Can user code or `await` occur while protected? | Keep critical sections synchronous, bounded, and single-authority. | Holding locks across suspension or calling unknown code under lock |
| Objective-C/delegate callback isolation | What queue/thread/actor contract does the imported API actually guarantee? | Encode a static actor contract where possible; bridge explicitly at the boundary. | Assuming callback queue from convention alone |
| Nonisolated async execution changes | Is `NonisolatedNonsendingByDefault` enabled? Did old code rely on leaving the actor? | Keep caller-actor execution unless measured work must be `@concurrent`. | Assuming `async` means background |
| Actor state after `await` | Which invariant could another task change while suspended? | Re-read or validate state after the suspension; use an operation token/version when needed. | Relying on a pre-await snapshot of mutable actor state |

## Fix review questions

- Does the new signature accurately communicate isolation and sendability to callers?
- Does cancellation terminate queued or long-running work?
- Can completion happen exactly once under all interleavings?
- Can the task outlive its owner or retain it indefinitely?
- Is main-actor work limited to UI-owned state and publication?
- Does an actor method preserve its invariant across suspension?
- Does synchronization have one clear authority?
- Did the fix change public API, ordering, priority, or executor behavior?
- Is the focused test deterministic and behavior-based?
