import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Deep Plan

	/// The rp-deep-plan slash command — deep, delegation-heavy planning workflow that
	/// ends at a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document (no implementation).
	static let rpDeepPlan = rpDeepPlan(variant: .mcp)

	/// Generate rp-deep-plan for a specific variant.
	static func rpDeepPlan(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-deep-plan", description: "Deep planning workflow using \(toolDesc): map seams, draft, critique, polish — produces a ready-to-execute plan document", variant: variant))

# Deep Plan Mode\(suffix)

Plan: $ARGUMENTS

You are a deep-planning orchestrator. Produce one polished, executable plan document at `docs/plans/<topic>-<YYYY-MM-DD>.md`. No code, no implementation, no half-built scaffolding — the workflow's own artifacts (plan export, Phase 6 critique) are expected, but the plan is the sole deliverable.

\(variant.preamble)\(rpDeepPlanCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// Core deep-plan workflow content.
	static func rpDeepPlanCore(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatTool: String
		let chatToolName: String
		switch variant {
		case .cli: chatTool = "`chat`"; chatToolName = "chat"
		case .agent: chatTool = "`ask_oracle`"; chatToolName = "ask_oracle"
		case .mcp: chatTool = "`oracle_send`"; chatToolName = "oracle_send"
		}
		_ = chatTool
		_ = chatToolName

		return """
This workflow is delegation-heavy. Explore agents map seams and pull external research. \(builderName) produces the draft plan in plan mode. A design agent does a bounded critique. **You own the writing**, the structure, and the final shape.

## Core principles

- **Plan only.** Implementation belongs in `rp-build` or `rp-orchestrate`. End at a polished document.
- **Delegate evidence, not voice.** Sub-agents gather; you write.
- **The \(builderName) export is the preservation baseline, not an authority over code or explicit user decisions.** Preserve every supported implementation-bearing fact, decision, rationale, constraint, edge case, sequencing requirement, and verification requirement. A detail is *supported* when explicit requirements, observed code, established repository patterns, or sound architectural reasoning about the task justifies it — a proposed design need not already exist in the code to be supported.
- **Removal needs evidence; consolidation must be lossless.** Remove or replace a baseline detail only when code, user direction, or task scope shows it is incorrect, unsupported, out of scope, or duplicated — or when you can name a simpler design that meets the same requirements with the same verification coverage. Consolidation is lossless when the same facts, decisions, rationale, constraints, and verification stay equally easy to find; never generalize accurate detail merely for brevity.
- **Reference, don't reproduce.** Point to `file:line` and external links. Don't paste full source files, raw transcripts, or tool dumps into the plan.
- **Ground every user question in something you found.** Generic interview questions waste the user's time.
- **Honor the involvement promise.** Once the user has picked **Up front** or **Mid-flow**, every downstream `ask_user` is a checkpoint they asked for. If one returns `timed_out: true`, **halt** — don't proceed with assumed answers and silently break the promise. Resume from the same prompt when the user replies. (Phase 1 itself is exempt: a timeout on the involvement-mode question means "no signal yet," and the documented Hands-off default applies.) `skipped: true` is always an explicit user choice and falls back to documented defaults.
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "the involvement question", nextStep: "Phase 1"))
## Phase 1: User Involvement Decision (REQUIRED — first interactive action)

Before any exploration, ask the user how involved they want to be. This is the **only** mandatory user prompt — the rest of the run pauses for input only at the chosen checkpoint.

\(example(variant,
	mcp: """
```json
{"tool":"ask_user","args":{
	"question":"How involved would you like to be while I shape this plan?",
	"options":[
		"Up front — I want to clarify the prompt before exploration begins.",
		"Mid-flow — check in with me before the design agent reviews the draft.",
		"Hands-off — surface the plan when it is ready, then we can refine it interactively."
	],
	"context":"This decides where I pause for your input. The default if you skip or don't reply is hands-off.",
	"timeout_seconds":120
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'call ask_user {"question":"How involved would you like to be while I shape this plan?","options":["Up front — I want to clarify the prompt before exploration begins.","Mid-flow — check in with me before the design agent reviews the draft.","Hands-off — surface the plan when it is ready, then we can refine it interactively."],"context":"This decides where I pause for your input. The default if you skip or don'\''t reply is hands-off.","timeout_seconds":120}'
```
"""))

The answer drives the rest of the run:

| Mode | Where you pause for the user |
|------|------------------------------|
| **Up front** | Phase 1.5 — grounded interview before broad exploration |
| **Mid-flow** | Phase 5 — review the draft before the design critique |
| **Hands-off** | Phase 7 — final hand-off, then interactive refinement |

### Handling the answer

Inspect the `ask_user` result before moving on:

- **Answered** (one of the three options, or a freeform reply) → set the involvement mode and continue. If they picked **Up front** or **Mid-flow**, treat that as a promise: a timeout at the chosen checkpoint later means **halt**, not "default and keep going".
- **`skipped: true`** (user explicitly skipped) → fall back to **Hands-off** and continue. The user has signaled they don't want to be involved.
- **`timed_out: true`** (no reply) → fall back to **Hands-off** and continue. A timeout here means no signal yet — don't stall the workflow before any direction has been given. (This is the **only** `ask_user` in this workflow where a timeout is treated as a default-fallback. Once the user has picked Up front or Mid-flow, downstream timeouts halt instead.)

When you do involve the user, ask **2–4 thoughtful, plan-shaping questions** — questions that surface a real ambiguity in the work. If you couldn't have asked the question without first looking at the code or current draft, it's probably a good question. Generic workflow meta-questions ("what's the priority?") and unfocused asks ("what do you want?") don't count.

### Phase 1.5: Grounded Interview (only if "Up front")

Don't jump to questions. Dispatch 1–2 narrow explore agents first, **scoped to ambiguity-finding**, not seam mapping (Phase 2 does the broad map):

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Ambiguity scout: <area>",
	"message":"What existing patterns or conventions in <area> might apply to <user task>? Report 2–3 concrete patterns with file:line refs and a one-sentence description of each. Don't propose solutions.",
	"detach":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Ambiguity scout: <area>" message="What existing patterns or conventions in <area> might apply to <user task>? Report 2–3 concrete patterns with file:line refs and a one-sentence description. Don'\\''t propose solutions." detach=true'
```
"""))

When the explores return, ask 2–4 questions the findings made askable. Good shapes:

- *"Two existing patterns could apply: `<patternA>` in `<file>` and `<patternB>` in `<file>`. Which fits — or does this need a new pattern?"*
- *"Current behavior assumes `<invariant>`. Is that load-bearing, or are you open to changing it?"*
- *"This work could land in `<module A>` or `<module B>`. Any preference on scope?"*

Use `ask_user` per question, or batch related ones. Wait for answers; fold them into your working understanding before Phase 2.

The user picked **Up front** — they explicitly asked to be involved here. If any `ask_user` returns `timed_out: true`, **halt** — don't fold a non-answer in, don't proceed to Phase 2 with an assumed answer, don't silently demote them to Hands-off. Report you're waiting on the outstanding question(s) and stop. Resume Phase 1.5 from the same prompt when the user replies. (`skipped: true` is fine — treat it as the user opting out of that one question and continue with what you know.)

---

## Phase 2: Map the Seams

Dispatch explore agents in parallel to map the surface area the plan will touch. Three lanes — use only what's relevant:

| Lane | When to use | Question shape |
|------|-------------|----------------|
| **In-workspace seams** | Always | "How does `<subsystem>` connect to `<adjacent area>`? Key types, extension points, file:line refs." |
| **External research** | Only when the plan depends on external APIs, libraries, standards, or behaviour outside the repo | "Look up <library/API/RFC>. Report current behavior, version notes, and links." |
| **Prior art** | When the area has likely been touched before | "Check `docs/plans/`, `docs/completed/`, recent commits in `<area>`. Anything similar tried? Summarize." |

Each explore gets ONE narrow question. Spawn with `detach: true`, then wait on the batch.

\(example(variant,
	mcp: """
```json
// In-workspace seam probe
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Seams: <area>",
	"message":"How does <subsystem> connect to <adjacent area>? Key types, extension points, file:line refs. No proposals.",
	"detach":true
}}

// External research probe (only if relevant)
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"External: <topic>",
	"message":"Look up <library/API/RFC>. Report current behavior, version notes, and 2–3 links.",
	"detach":true
}}

{"tool":"agent_run","args":{"op":"wait","session_ids":["<id1>","<id2>"],"timeout":120}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Seams: <area>" message="How does <subsystem> connect to <adjacent area>? Key types, extension points, file:line refs." detach=true'
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="External: <topic>" message="Look up <library/API/RFC>. Report current behavior, version notes, and 2–3 links." detach=true'
rpce-cli -w <window_id> -e 'agent_run op=wait session_ids=["<id1>","<id2>"] timeout=120'
```
"""))

> ⚠️ **Detached agents may block on permission approvals.** Poll periodically or use `op=wait` so you can approve and keep them unblocked.

Skip lanes that don't apply. **Don't dispatch external research just because you can** — the relevance trigger is "the plan depends on facts I can't see in this workspace."

**Capture the findings — don't just absorb them.** The explore agents did real reconnaissance, but they also return a lot. Curate: distill the *load-bearing* evidence — file:line refs, type names, extension points, links, prior art (including anything useful the Phase 1.5 ambiguity scouts surfaced) — into the plan's `## Background` when you scaffold the file next. The goal is enough grounding that \(builderName) doesn't re-derive seams from scratch — not a verbatim dump of every agent's output. When unsure whether a concrete reference matters, keep it; leave the raw transcripts and narration behind.

---

## Phase 3: Scaffold the Plan File

Create `docs/plans/<topic>-<YYYY-MM-DD>.md`. Seed it with a **lightweight pre-draft scaffold** containing **Goal**, **Background**, **Open Questions**, and **References**, with `## Background` populated substantively from the curated Phase 2 findings. This scaffold is input to \(builderName), not the final plan schema — Phase 4 replaces it with the export's full set of substantive sections. The background is distilled evidence — not draft prose or raw agent output — and the goal stays a sentence or two until the planning export is integrated.

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{
	"action":"create",
	"path":"docs/plans/<topic>-<YYYY-MM-DD>.md",
	"content":"# <Topic>: Plan\\n\\n## Goal\\n<1–2 sentence restatement in the codebase's actual terms>\\n\\n## Background\\n<key findings from Phase 2 explores: file:line refs, links, prior art>\\n\\n## Open Questions\\n<anything still unresolved after Phase 1 / Phase 2>\\n\\n## References\\n<external links, prior plans, supporting docs>\\n"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'file create docs/plans/<topic>-<YYYY-MM-DD>.md "# <Topic>: Plan

## Goal
<1–2 sentence restatement in the codebase'\\''s actual terms>

## Background
<key findings from Phase 2 explores: file:line refs, links, prior art>

## Open Questions
<anything still unresolved after Phase 1 / Phase 2>

## References
<external links, prior plans, supporting docs>
"'
```
"""))

Don't write the Approach or Work Items yet — \(builderName) produces those.

---

## Phase 4: \(builderName) Plan Pass

Call \(builderName) in plan mode with `export_response: true`. Request the full implementation-ready specification — don't narrow the builder to a short approach or checklist — and point it at the plan file so it builds on the explore findings in `## Background`:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
	"instructions":"<task><user task, restated in the codebase's terms></task>\\n\\n<context>See the in-progress plan at `docs/plans/<topic>-<YYYY-MM-DD>.md` — its `## Background` section holds the curated explore-agent findings (seams, file:line refs, prior art, external research), plus the goal and open questions gathered so far. Build on that context rather than re-deriving it.\\n\\nFollow the full output structure and specificity requirements of your planning instructions. Produce a complete implementation-ready specification, not only an approach and ordered work items. Preserve detailed current-state analysis, component and interface design, file-by-file impact, state and data flow, errors and edge cases, tradeoffs, risks, implementation order, and verification wherever applicable.</context>",
	"response_type":"plan",
	"export_response":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task><user task, restated in the codebase'\\''s terms></task>

<context>See the in-progress plan at docs/plans/<topic>-<YYYY-MM-DD>.md. Its Background section holds the curated explore-agent findings, plus the goal and open questions gathered so far. Build on that context rather than re-deriving it.

Follow the full output structure and specificity requirements of your planning instructions. Produce a complete implementation-ready specification, preserving current-state analysis, component and interface design, file-by-file impact, state and data flow, errors and edge cases, tradeoffs, risks, implementation order, and verification wherever applicable.</context>" --response-type plan --export'
```
"""))

The tool returns `oracle_export_path`. **Use the export's generated plan as the preservation baseline.** Export files may open with the composed prompt and a selected-file dump; the baseline is the generated response that follows, not that context echo. The codebase and explicit user decisions stay authoritative.

1. Read the complete export with `read_file`; if a read is truncated, continue in chunks until every line has been read. While reading, build a compact coverage ledger of the baseline: each section and its concrete implementation-bearing items (facts, decisions, rationale, constraints, edge cases, sequencing, verification), a few words apiece. Phase 7.5 walks this ledger.
2. Integrate all substantive, supported plan content rather than mining the export for a shorter summary. Preserve applicable current-state analysis, design, file-by-file impact, tradeoffs, risks, implementation order, and verification. Exclude only tool wrappers, raw transcripts, raw file dumps, and other non-plan artifacts.
3. Fold the scaffold's `## Goal`, curated `## Background`, user answers, open questions, and references into that body.
4. Check the export's claims against the code and the user's answers. Correct or remove a detail only under the removal standard in Core principles, and note what changed and why so a corrected item doesn't later read as a dropped one.
5. Add an execution index using **Goal**, **Done when**, **Key files**, **Dependencies**, and **Size** for each work item. This index organizes the detailed specification rather than replacing it.
6. Normalize headings and phrasing, integrate Phase 2 evidence, and fill genuine gaps. Do not collapse distinct behavior cases or replace concrete detail with broad instructions such as “update callers” or “add tests.”
7. Keep the export through the Phase 6 critique and Phase 7.5 fidelity check; delete it only after that check passes.

\(example(variant,
	mcp: """
```json
{"tool":"read_file","args":{"path":"<oracle_export_path>"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'read <oracle_export_path>'
```
"""))

The Phase 6 critique checks correctness, completeness, and preservation against this baseline.

---

## Phase 5: Mid-flow Check-in (only if "Mid-flow")

Read your own draft. Identify 2–4 ambiguities — places where \(builderName) hedged ("could go either way"), tradeoffs without a pick, or assumptions the user might want to weigh in on. Ask via `ask_user`. Fold answers in before Phase 6.

The user picked **Mid-flow** — they explicitly asked to be involved here. If any `ask_user` returns `timed_out: true`, **halt** — don't push to Phase 6 (the design critique) with unresolved ambiguities, don't silently demote them to Hands-off. Report you're waiting on the outstanding question(s) and stop. Resume Phase 5 from the same prompt when the user replies. (`skipped: true` means the user is fine with your current draft on that point — continue.)

---

## Phase 6: Bounded Completeness and Design Critique

Dispatch a design agent **once**, with tight scope, to check the plan against both the codebase and the original \(builderName) export. The design agent is a correctness and completeness critic, not a co-author.

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"design",
	"session_name":"Plan critique: <topic>",
	"message":"Read the plan at `docs/plans/<topic>-<YYYY-MM-DD>.md` and the complete original context_builder export at `<oracle_export_path>` — treat only its generated plan response as the baseline; any composed prompt or selected-file dump it opens with is context, not plan content. Produce a focused critique under `docs/reviews/`. Cover ONLY:\\n1. Implementation-bearing content from the export that is missing, weakened, or generalized in the plan\\n2. Under-specified seams, unresolved material decisions, contradictions, incorrect references, or missing dependencies\\n3. Plan or export details that the code disproves, the task does not require, or a named simpler design fully replaces — give the precise correction and its justification\\n4. Requirements, edge cases, dependencies, or architectural problems absent from both the export and the plan — ownership, lifecycle, failure behavior, cancellation, testability\\n5. Questions whose answers would materially change the design or implementation order\\n\\nDo not recommend removing accurate content merely because it is specific or low-level. Do not expand user scope, rewrite the plan, or perform broad codebase exploration unless one named seam needs a focused spot-check.",
	"wait":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=start model_id=design session_name="Plan critique: <topic>" message="Read the plan at docs/plans/<topic>-<YYYY-MM-DD>.md and the complete original builder export at <oracle_export_path> — treat only its generated plan response as the baseline; any composed prompt or selected-file dump is context, not plan content. Check for implementation-bearing content missing, weakened, or generalized; under-specified seams, contradictions, or incorrect references; details the code disproves, the task does not require, or a named simpler design replaces (give the correction); requirements or architectural problems absent from both — ownership, lifecycle, failure behavior, cancellation, testability; and material questions. Do not remove accurate content merely because it is specific or low-level, expand scope, rewrite the plan, or explore broadly." wait=true'
```
"""))

Apply verified findings rather than pasting the critique into the plan. Restore supported omissions, resolve material ambiguities and contradictions, and correct or remove content under the same removal standard as Phase 4. Keep the export until the Phase 7.5 fidelity check passes.

---

## Phase 7: Fidelity-Preserving Editorial Polish + Final Hand-off

Make the plan clear and executable. Fidelity is about preserving supported content, not preserving wording or maximizing length.

- Remove generic filler, raw artifacts, and semantic duplication; keep any consolidation lossless.
- Preserve concise rationale for the chosen approach and its most plausible rejected alternative when that rationale guides implementation or review.
- Verify every `file:line` reference, symbol name, command, and external link that the plan relies on.
- Scan for accidental generalization: phrases such as “update callers,” “handle errors,” or “add tests” must not replace named call sites, failure behavior, or verification cases.

**Acceptance criteria for the final plan:**

- [ ] Lives at `docs/plans/<topic>-<YYYY-MM-DD>.md` and retains every applicable substantive section of the export — current-state analysis, detailed design, file-by-file impact, tradeoffs, risks, implementation order, verification — not collapsed into only a summary and work-item list
- [ ] Passes the Phase 7.5 fidelity check against the export
- [ ] Resolves every material design decision that current evidence makes resolvable and names the tests, commands, and manual checks that prove completion
- [ ] Contains no transcript dumps, raw agent output, generic advice, or repeated narration
- [ ] Retains only material open questions and can be executed by a reader without prior conversation context

## Phase 7.5: Final Fidelity Check and Cleanup

Walk the coverage ledger from Phase 4 — no need to reread both documents cold. Confirm the final plan keeps each ledger item equally explicit and discoverable, losslessly consolidated, or corrected or removed under the removal standard in Core principles. Restore anything that became weaker or merely implied, and spot-check the export directly wherever the ledger feels thin. This is a fidelity check, not a length target.

Delete the export only after this check passes:

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{"action":"delete","path":"<oracle_export_path>"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'call file_actions {"action":"delete","path":"<oracle_export_path>"}'
```
"""))

If the user picked **Hands-off**, surface the plan now and offer interactive refinement: *"Plan is at `<path>`. Want me to revise any section, expand scope, or trim anything?"* Treat each round as a focused edit pass on the file, not a re-plan.

For **all** modes, report:

- Plan path
- 2–3 sentence summary
- Any open questions that survived the polish pass
- Suggested next workflow (`rp-build` for direct implementation, `rp-orchestrate` for multi-agent execution)

The current Phase 4 export is not fully consumed until the Phase 7.5 fidelity check passes, so no earlier housekeeping rule may delete it.

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance, includeStrayPlanExportCleanup: true))
---

## Anti-patterns

- 🚫 Skipping the involvement-level question — always ask first; the answer changes the run
- 🚫 Asking generic or thin questions when in "Up front" / "Mid-flow" mode — questions must be informed by exploration findings or by the current draft's ambiguities
- 🚫 More than 4 questions per checkpoint — interrogation isn't shaping
- 🚫 Implementing code — this workflow ends at a plan
- 🚫 Pasting full file contents into the plan — refer to `file:line`, don't reproduce
- 🚫 Losing the Phase 2 findings or dumping raw explore-agent output into `## Background` — preserve distilled, load-bearing evidence
- 🚫 Summarizing or generalizing supported implementation-bearing content merely for brevity — lossless consolidation is fine, lossy is not
- 🚫 Letting the design critique reopen settled decisions without evidence, expand scope, or rewrite the plan
- 🚫 Deleting the \(builderName) export before the Phase 7.5 fidelity check passes
- 🚫 Dispatching external/web research when the plan only depends on in-repo facts — the trigger is real external dependency
- 🚫 Doing broad codebase reading yourself instead of dispatching an explore agent — keep your context lean for writing
- 🚫 Forgetting to poll dispatched agents — they may block on permission approvals
- 🚫 Silently demoting an Up-front / Mid-flow user to Hands-off when their checkpoint `ask_user` times out — they asked to be involved; honor it. Halt and resume when they reply. (Phase 1's involvement-mode prompt is the one exception: a timeout there is treated as "no signal" and falls through to the Hands-off default.)\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` — CLI invocations are stateless and require explicit window targeting" : "")

---

Now begin with Phase 0.\(variant == .cli ? " First run `rpce-cli -e 'windows'` to find the correct window." : "")
"""
	}

	/// Token-efficient reminder to use RepoPrompt tools (MCP variant).
	/// No arguments - just a gentle nudge to prefer RP tools over built-in alternatives.
}
