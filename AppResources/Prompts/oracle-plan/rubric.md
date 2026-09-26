# Oracle Plan v1 judge rubric

Judge the candidate response to the case input, using only the frozen context supplied there. Score 0.0–1.0. Do not reward invented source facts; a well-scoped plan may identify a fact that needs checking and say how to check it. Do not require a large plan for a narrow request.

- **0.25 — Current-state analysis:** Identifies the relevant real files, types, ownership and data/mutation path from the excerpt. Reuses the named seam rather than inventing a parallel subsystem.
- **0.30 — Resolved design:** Specifies concrete behavior and invariants for the case, including authority, ordering, concurrency, error and edge-case decisions where relevant. Leaves no avoidable implementer choice open.
- **0.20 — File-by-file impact and order:** Names the touched files/symbols, what changes in each, dependencies, and an ordered implementation/validation sequence.
- **0.15 — Risks and tests:** Names focused regression cases for the failure modes in the request, including non-interference and conflicts when applicable; distinguishes confirmed behavior from assumptions.
- **0.10 — Response discipline:** Is proportionate, uses clear Markdown, and does not provide production code, a full patch or copy-paste implementation.

Return a numeric score plus short actionable feedback. Cite the specific missing decision, file/symbol, invariant or test, not generic praise. For a response that primarily emits production code or ignores the request, cap the score at 0.2. For a plan with a fabricated critical API or authority boundary, cap at 0.4. Do not leak held-out case content or judge details into proposer-facing feedback; the host enforces the held-out projection boundary.
