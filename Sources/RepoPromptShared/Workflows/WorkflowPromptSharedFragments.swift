import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Example Generators

	/// Returns the appropriate code example based on variant.
	/// Agent uses the same MCP JSON syntax, so it falls through to the mcp branch.
	static func example(_ variant: WorkflowPromptVariant, mcp: String, cli: String) -> String {
		switch variant {
		case .mcp, .agent: return mcp // Agent uses MCP tool syntax
		case .cli: return cli
		}
	}

	/// Generates the workspace verification block for Phase 0 / Step 0.
	/// Returns empty string for agent variant (workspace is auto-mapped).
	/// - Parameters:
	///   - variant: The tool variant
	///   - heading: Section heading including markdown level, e.g. "## Phase 0" or "### Phase 0"
	///   - beforeAction: What comes after "Before any", e.g. "exploration", "investigation"
	///   - nextStep: Where to proceed after verification, e.g. "Phase 1", "Step 1"
	static func workspaceVerificationBlock(
		variant: WorkflowPromptVariant,
		heading: String = "Phase 0",
		beforeAction: String = "exploration",
		nextStep: String = "Phase 1"
	) -> String {
		guard variant != .agent else { return "" }
		return """

\(heading): Workspace Verification (REQUIRED)

Before any \(beforeAction), bind to the target codebase using its working directory:

\(example(variant,
	mcp: """
```json
{"tool":"bind_context","args":{"op":"bind","working_dirs":["/absolute/path/to/project"]}}
```
This auto-resolves to the window containing your project. No need to list windows first.
""",
	cli: """
```bash
# First, list available windows to find the right one
rpce-cli -e 'windows'

# Then check roots in a specific window (REQUIRED - CLI cannot auto-bind)
rpce-cli -w <window_id> -e 'tree --type roots'
```
"""))

\(variant == .mcp ? """
**If binding succeeds** → proceed to \(nextStep)
**If no match** → the codebase isn't loaded. Find and open the workspace:
```json
{"tool":"manage_workspaces","args":{"action":"list"}}
{"tool":"manage_workspaces","args":{"action":"switch","workspace":"<workspace_name>","open_in_new_window":true}}
```
Then retry the `working_dirs` bind.
""" : """
**Check the output:**
- If your target root appears in a window → note the window ID and proceed to \(nextStep)
- If not → the codebase isn't loaded in any window

**CLI Window Routing:**
- CLI invocations are stateless—you MUST pass `-w <window_id>` to target the correct window
- Use `rpce-cli -e 'windows'` to list all open windows and their workspaces
- Always include `-w <window_id>` in ALL subsequent commands\(beforeAction == "exploration" ? "\n- Without `-w`, commands may target the wrong workspace" : "")
""")

---
"""
	}

	// MARK: - Orchestration Shared Content

	/// Decomposition guidance shared between orchestration-shaped workflows.
	/// Emits the "for each item, note: goal / done-when / key files / dependencies / size" bullets plus
	/// the 2-3 sweet spot rule and the "1 item = skip ceremony" escape hatch.
	/// - Parameters:
	///   - variant: Tool variant (reserved for future example-bearing variations).
	///   - taskNoun: Singular noun describing what an item produces (e.g. `"item"`, `"refactoring"`).
	///     Substituted into the `Goal` bullet only — the rest uses generic "item"/"task" wording.
	static func sharedDecompositionGuidance(variant: WorkflowPromptVariant, taskNoun: String) -> String {
		_ = variant
		return """
For each item, note:
- **Goal**: What this \(taskNoun) accomplishes (1-2 sentences)
- **Done when**: Concrete completion criteria — what should be true when this item is finished
- **Key files/modules**: Where the work happens
- **Dependencies**: Which other items must complete first, if any
- **Size**: Small (focused change) or large (multi-file, architectural)

Most tasks decompose into **2-3 items** — that's the sweet spot. If you're reaching for 4-5, consider whether some items can be combined. If you're beyond 5, you're decomposing too finely — raise the abstraction level.

If the task naturally decomposes into **1 item**, skip the orchestration overhead — just dispatch it directly. Don't create ceremony for simple work.
"""
	}

	/// "Check which model is powering a role" block plus the Codex-family extended-steering caveat.
	static func sharedRolesOnlyCheck(variant: WorkflowPromptVariant) -> String {
		return """
To check which model is powering a role:

\(example(variant,
	mcp: """
```json
{"tool":"agent_manage","args":{"op":"list_agents","roles_only":true}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_manage op=list_agents roles_only=true'
```
"""))

A role whose display name starts with `Codex CLI` (or an explicit `model_id` with a `codexExec:*` prefix) signals the role is well-suited to extended steering.
"""
	}

	/// Parallel dispatch guidance: sibling-warning quote block, `detach:true` requirement,
	/// `session_ids` wait semantics, poll option, and "be a pipeline, not a sequential loop" framing.
	/// - Parameters:
	///   - variant: Tool variant — affects MCP vs CLI example syntax.
	///   - defaultRole: `model_id` used in the concurrent-dispatch example (e.g. `"pair"`, `"engineer"`).
	static func sharedParallelDispatchBlock(variant: WorkflowPromptVariant, defaultRole: String) -> String {
		return """
If dispatching independent items as fresh agents concurrently, **each agent's brief must mention the sibling**:

> "Another agent is concurrently working on <brief description of sibling task> in <modules>. Avoid modifying files in that area. If you find yourself blocked by or conflicting with that work, stop and report back rather than pushing through."

**Use `detach: true`** when dispatching concurrent items — otherwise the orchestrator blocks on the first agent and can't start the second.

Then pass `session_ids` (array) to `agent_run op=wait` to block until the **first** session finishes or needs input. The response tells you which session won and which are still pending.

\(example(variant,
	mcp: """
```json
// Dispatch both concurrently
{"tool":"agent_run","args":{"op":"start","model_id":"\(defaultRole)","session_name":"1/N: <goal A>","message":"<brief A>","detach":true}}
{"tool":"agent_run","args":{"op":"start","model_id":"\(defaultRole)","session_name":"2/N: <goal B>","message":"<brief B>","detach":true}}

// Then wait for the first session that needs attention
{"tool":"agent_run","args":{"op":"wait","session_ids":["<session_id_A>","<session_id_B>"],"timeout":60}}

// Or poll all current snapshots without blocking
{"tool":"agent_run","args":{"op":"poll","session_ids":["<session_id_A>","<session_id_B>"]}}
```
""",
	cli: """
```bash
# Dispatch both concurrently
rpce-cli -w <window_id> -e 'agent_run op=start model_id=\(defaultRole) session_name="1/N: <goal A>" message="<brief A>" detach=true'
rpce-cli -w <window_id> -e 'agent_run op=start model_id=\(defaultRole) session_name="2/N: <goal B>" message="<brief B>" detach=true'

# Then wait for the first session that needs attention
rpce-cli -w <window_id> -e 'agent_run op=wait session_ids=["<uuid1>","<uuid2>"] timeout=60'

# Or poll all current snapshots without blocking
rpce-cli -w <window_id> -e 'agent_run op=poll session_ids=["<uuid1>","<uuid2>"]'
```
"""))

Handle the finished agent, then wait again on the remaining `pending_session_ids`. While waiting, summarize completed work or prepare the next brief — be a pipeline, not a sequential loop.
"""
	}

	/// Dispatch-brief guidance: "scope is your most important job", paraphrase/point/boundary patterns,
	/// include/don't-include lists, and "pass forward discoveries, not instructions".
	static func sharedDispatchBriefGuidance(variant: WorkflowPromptVariant) -> String {
		_ = variant
		return """
The agents you dispatch are fully capable — they have tools, they'll read AGENTS.md and project instructions, they can explore and reason. Your job is to orient them, not direct them.

**Scope is your most important job.** When you pass a plan export, the sub-agent can see the full plan — but it doesn't know which part is its responsibility unless you say so. Always be explicit about what it should do *now* and what it should leave alone. A few patterns:

- **Paraphrase for narrow tasks**: If the work is small and self-contained, just describe it in the dispatch message. The agent doesn't need the full plan.
- **Point to a section for broader tasks**: Reference the plan path in the `message` and tell the agent which part to focus on (e.g. "Read the plan at <path> with read_file first. Your job is item 2 in the plan. Items 1 and 3 are handled separately.").
- **State the boundary**: "Do only X. Stop when X is done." is more effective than hoping the agent infers scope from context.

You can always steer additional work later, or spin up a separate agent for the next item.

**Include:** The goal, relevant file paths/modules, and discoveries from planning that the agent wouldn't find on its own. If a separate user plan file exists, point to the relevant section. For small tasks, tell the agent to skip oracle review.

**Don't include:** Project conventions already in CLAUDE.md, step-by-step instructions, or code snippets the agent can read itself.

**Pass forward discoveries, not instructions.**

**Two conversations, kept separate.** You hold one conversation with the user (preferences, course corrections, meta-instructions about how *you* should behave) and a separate one with each peer agent (purely the technical task). When the user steers you, translate the actionable parts into the next brief — never forward their words verbatim, and never narrate what the user told you about your own conduct. If a brief you already dispatched carried that kind of commentary, cancel it and re-send clean.
"""
	}

	/// Final rollup bullets emitted after all work items complete.
	/// - Parameter taskNoun: Singular noun describing each item (e.g. `"item"`). Substituted into the
	///   "After all Xs complete" and "What was accomplished per X" lines.
	static func sharedFinalRollupBlock(variant: WorkflowPromptVariant, taskNoun: String) -> String {
		_ = variant
		return """
After all \(taskNoun)s complete, give the user a **final rollup**:
- What was accomplished per \(taskNoun)
- Any failures or partial completions
- Any conflicts or coordination issues that surfaced
- Suggested follow-ups if anything was deferred
"""
	}

	/// Monitor-and-verify pattern: verify each agent's output against the plan's "done when" criteria,
	/// steer a correction if something's off, and summarize status to the user.
	static func sharedMonitorAndVerifyBlock(variant: WorkflowPromptVariant) -> String {
		return """
You own the plan. It's your job to ensure each phase respected it.

As each agent completes:

1. **Verify against the plan.** Check the agent's output against the "done when" criteria from the plan. Don't just skim — confirm the goal was actually met. A quick `read_file` or `file_search` on key deliverables costs little and catches drift before it compounds. If the plan said "add error handling to all three endpoints" and the agent only touched two, that's your catch. Mark the item as done (or note gaps) in the export file so you have a running record.
2. **If something's off**, steer a correction before moving on — never proceed with unresolved gaps:
\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"The goal was X but Y appears to be missing. Please address that before wrapping up.",
	"wait":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="The goal was X but Y appears missing." wait=true'
```
"""))
3. **Summarize to the user**: Brief status update — what completed, what's still running.
"""
	}

	/// Gentle housekeeping hint for dismissing completed agent sessions after their
	/// output has been recorded. Sessions persist by default; cleanup is optional but
	/// keeps the session list tidy during multi-agent workflows.
	static func sharedSessionCleanupHint(variant: WorkflowPromptVariant) -> String {
		return """
Sessions persist after agents finish — useful when you might revisit output, but they pile up over a multi-agent workflow. Once you've recorded what an agent produced, you can dismiss its session:

\(example(variant,
	mcp: """
```json
{"tool":"agent_manage","args":{"op":"cleanup_sessions","session_ids":["<session_id>"]}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_manage op=cleanup_sessions session_ids=["<session_id>"]'
```
"""))

Explore-agent sessions are good to dismiss right away — narrow reconnaissance, no follow-up value. Keep heavier agent sessions if you might revisit them.
"""
	}

	/// Gentle housekeeping hint for removing stray plan/review export files that were
	/// generated during a multi-agent workflow but are no longer relevant to the task
	/// (superseded drafts, one-shot oracle consultations, exports whose work has already
	/// been merged). Keeps `prompt-exports/` focused on live, in-progress plans.
	static func sharedStrayPlanExportCleanupHint(variant: WorkflowPromptVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let oracleName: String
		switch variant {
		case .cli: oracleName = "`chat`"
		case .agent: oracleName = "`ask_oracle`"
		case .mcp: oracleName = "`oracle_send`"
		}
		return """
Plan and review exports generated during orchestration (via `export_response:true` on \(builderName) or \(oracleName)) accumulate under `prompt-exports/` as files like `oracle-plan-<date>-<slug>.md` or `oracle-review-<date>-<slug>.md`. Once an export has been superseded by a newer plan, consumed by the sub-agent it was meant for, or otherwise made irrelevant by completed work, delete it so the folder reflects only live, in-progress plans. `file_actions.delete` requires a true absolute filesystem path, not the relative display path shown under `prompt-exports/`; use `get_file_tree` with `type:"roots"` if you need the loaded root's absolute path. When unsure, leave it.

\(example(variant,
	mcp: """
```json
{"tool":"file_actions","args":{"action":"delete","path":"/absolute/path/to/repo/prompt-exports/<stale-export>.md"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'call file_actions {"action":"delete","path":"/absolute/path/to/repo/prompt-exports/<stale-export>.md"}'
```
"""))
"""
	}

	static func sharedSessionCleanupSection(
		variant: WorkflowPromptVariant,
		heading: String,
		includeSessionCleanupGuidance: Bool,
		includeStrayPlanExportCleanup: Bool = false
	) -> String {
		guard includeSessionCleanupGuidance else { return "" }
		var blocks: [String] = [sharedSessionCleanupHint(variant: variant)]
		if includeStrayPlanExportCleanup {
			blocks.append(sharedStrayPlanExportCleanupHint(variant: variant))
		}
		return """
\(heading)

\(blocks.joined(separator: "\n\n"))

"""
	}

}
