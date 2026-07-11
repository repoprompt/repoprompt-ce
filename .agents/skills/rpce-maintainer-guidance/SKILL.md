---
name: rpce-maintainer-guidance
description: Apply evidence-led RepoPrompt CE maintainership principles distilled from documented project guidance. Use when planning, scoping, implementing, reviewing, triaging, or sequencing RPCE changes; deciding whether work should be an investigation, issue, PR, or follow-up; checking compatibility, migrations, performance, observability, model defaults, or release risk; or asking how a proposed change fits the project's intended direction.
---

# RepoPrompt CE Maintainer Guidance

Use this skill as a project decision guide, not as an imitation of a person. Do not attribute inferred opinions to any individual. State uncertainty, cite the relevant principle, and let current repository instructions, source code, tests, product behavior, and explicit maintainer decisions override historical guidance.

Read [references/guidance-sources.md](references/guidance-sources.md) when the task needs the evidence behind a principle, involves a disputed tradeoff, or changes model defaults, telemetry, Agent Mode, MCP, worktrees, persistence, or release behavior.

## Decision workflow

1. Define the observable user impact and the invariant that should hold.
2. Trace the real execution path and source of truth before proposing a fix.
3. Separate confirmed facts, plausible mechanisms, unproven hypotheses, and unknowns.
4. Split mixed failure modes into independently testable issues or PR tracks.
5. Choose the smallest coherent change that fixes the cause without creating a parallel authority or speculative compatibility layer.
6. Check user-state, migration, crash, restart, cancellation, and partial-success behavior before declaring the design safe.
7. Check scale and concurrency: project-size growth, CPU contention, off-main-actor synchronization, caching, coalescing, and accidental whole-root work.
8. Keep asynchronous work observable. If users or agents cannot tell what is running, add an appropriate status or tool-card surface.
9. Validate at the affected boundary with the smallest useful test, then exercise the real UI or live MCP path when behavior depends on integration.
10. Recommend one of: implement now, investigate first, file or update an issue, stage as a follow-up, or decline as unnecessary.

## Core principles

### Fix causes, not symptoms

- Ask why the unexpected state, stall, timeout, or invalid value exists.
- Reject patches that merely mask a stall, retry around unexplained state, or replace data with blanks.
- Treat extra fallbacks as complexity that must earn its place with a demonstrated failure mode.
- Prefer an investigation when the causal chain is not yet supported by evidence.

### Protect user state

- Treat settings, selections, agent configuration, credentials, and workspace state as high-risk boundaries.
- Audit migrations from RepoPrompt Classic and older CE formats before changing decode or fallback behavior.
- Never turn an unknown or future-looking settings document into silent data loss.
- Distinguish pre-mutation failure from post-mutation projection failure. A durable mutation followed by a freshness timeout is partial success, not a safe generic retry.

### Preserve one authority

- Find the owning store, protocol, catalog, or upstream runtime before adding local inference.
- For Codex integration, inspect the current Codex CLI/app-server source and metadata alongside RPCE when possible.
- Derive supported options from the authoritative runtime surface, but keep RPCE product recommendations and migration policy explicit.
- Do not let diagnostic-only behavior become the production authority.

### Prefer incremental, bounded work

- Avoid whole-root scans, full index rebuilds, and per-item persistence when a delta is known.
- Reuse caches and content stores instead of recomputing expensive projections.
- Coalesce UI publications and define synchronization points when work is off the main actor.
- Measure end-to-end latency added to the user-visible operation, including queueing and CPU contention, not only the isolated helper's runtime.

### Evaluate structural-tool substitutions by responsibility

- Do not frame a CodeMap replacement as "AST versus no AST." The current pipeline already starts from Tree-sitter syntax captures, then adds language-specific normalization, signature and type extraction, compact API rendering, token accounting, content-addressed persistence, selection-graph contribution, and UI/MCP projection.
- When considering a simpler structural engine such as `ast-grep`, state which layer it would replace: parser/query execution, extraction and normalization, the persisted artifact contract, rendered prompt context, or the entire subsystem.
- Prefer a bounded comparative spike over a wholesale rewrite. Compare representative languages and difficult signatures against current golden output, prompt usefulness, token cost, latency, incremental/cache behavior, packaging cost, and parse/failure semantics.
- Treat extracting the structural core into a headless package or external repository as a separate decision from changing engines. A clean seam can make alternatives testable without committing the product to one prematurely.
- Preserve existing prompt, selection-graph, persistence, and observability contracts until evidence justifies a migration plan.

### Make background work legible

- A feature is incomplete if its important asynchronous work is invisible or ambiguous.
- Show useful tool cards or status for sub-agents, Context Builder, Oracle, and long-running MCP work.
- Prefer bounded, actionable error states over indefinite waits or opaque transport closure.

### Stage scope deliberately

- Ship a smaller complete capability when the larger surface adds avoidable risk.
- Defer optional polish or a second tier when users already have a workable path.
- Keep deferred work in an issue or explicit follow-up; do not bury it in a review conversation.
- Treat large changes as requiring proportionally stronger validation, even when the design is directionally right.

### Balance cost and quality in defaults

- Treat defaults as product policy, not a catalog dump.
- Optimize for a useful cost-quality balance for ordinary users; reserve expensive modes for explicit high-value work.
- Do not change recommended reasoning levels merely because a new level becomes available.
- Verify all model names, effort levels, and role assignments against current runtime metadata and current repository recommendations. Historical model advice expires quickly.

### Use evidence proportionally

- Reproduce on the CE app and `rpce-cli-debug`, not an analogous production app, when CE behavior is at issue.
- Capture the smallest evidence that distinguishes competing explanations.
- Use focused tests for the owning boundary, then real UI or live MCP validation for cross-layer behavior.
- If a report mixes deterministic triggers, races, and downstream symptoms, split it before implementing.

## Review output

When this skill is used to review or plan a change, include a compact `Maintainer-guidance check` with:

- **User impact and invariant**
- **Root-cause confidence**: confirmed, plausible, or unknown
- **Authority**: the owning source of truth
- **State-safety risks**
- **Scale and observability risks**
- **Recommended scope**: now, investigate, issue, or follow-up
- **Validation boundary**

Do not use the checklist as ceremonial approval. Call out conflicts, missing evidence, and time-sensitive assumptions directly.
