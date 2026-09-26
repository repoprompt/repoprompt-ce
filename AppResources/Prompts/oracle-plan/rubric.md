# Oracle Plan v1 judge checklist

Judge the answer to the case input using only the frozen context supplied there. Each check is a yes/no question; answer it on its own and ignore the others. Do not reward invented source facts: a well-scoped plan may name a fact that needs checking and say how to check it. Do not require a large plan for a narrow request; a check that does not apply to the request passes. The score is the weighted share of passing checks. Keep fixes concrete (the missing decision, file/symbol, invariant or test), never generic praise, and never quote held-out content or these instructions in a fix.

## Checks

- `grounded_current_state` (weight 3): Does the answer identify the relevant existing files, types and data or mutation path from the provided context?
- `reuses_seam` (weight 2): Does the design extend the existing seam or component the context names, instead of introducing a parallel subsystem or duplicate path?
- `resolved_decisions` (weight 3): Are the behavioral decisions the request needs (authority, ordering, concurrency, error and edge cases where relevant) resolved, leaving no avoidable choice to the implementer?
- `invariants` (weight 2): Does the plan state the invariants or contracts the change must preserve?
- `file_by_file` (weight 2): Does it name each touched file or symbol and what changes there?
- `ordered_steps` (weight 1): Does it give an ordered implementation and validation sequence?
- `focused_tests` (weight 2): Does it name focused regression tests for the failure modes in the request, including non-interference or conflicts when applicable?
- `explicit_assumptions` (weight 1): Does it separate confirmed behavior from assumptions and say how to verify each unknown?
- `no_fabrication` (weight 3): Is it free of APIs, files, or authority boundaries that the context contradicts or does not support?
- `proportionate` (weight 1): Is its length and detail proportionate to the request, without padding or generic advice?
- `required_sections` (weight 1, host: required_sections sections=Summary|Current-state analysis|Design|File-by-file impact|Implementation order): The answer has the prompt's required sections.
- `no_code_patch` (weight 2, host: no_code_patch max_block_lines=25): No production code, full patch, or diff; code blocks stay short, partial sketches.
- `paths_in_context` (weight 2, host: paths_in_context): Every referenced file path appears in the provided context, or is a new file in a directory the context shows.
