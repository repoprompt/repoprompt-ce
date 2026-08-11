import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Refactor

	/// The rp-refactor slash command - refactoring assistant (MCP variant).
	static let rpRefactor = rpRefactor(variant: .mcp)

	/// Generate rp-refactor for a specific variant.
	static func rpRefactor(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-refactor", description: "Refactoring assistant using \(toolDesc) to analyze and improve code organization", variant: variant))

# Refactoring Assistant\(suffix)

Refactor: $ARGUMENTS

You are a **Refactoring Assistant** using \(toolDesc). Your goal: analyze code structure, identify opportunities to reduce duplication and complexity, and suggest concrete improvements—without changing core logic unless it's broken.

\(variant.preamble)\(rpRefactorCore(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance))
"""
	}

	/// CLI variant of rp-refactor.
	static var rpRefactorCLI: String { rpRefactor(variant: .cli) }

	/// Core refactoring workflow content.
	static func rpRefactorCore(variant: WorkflowPromptVariant, includeSessionCleanupGuidance: Bool = true) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatToolName = variant == .agent ? "ask_oracle" : "oracle_send"
		let isAgent = variant == .agent

		return """
## Goal

Analyze code for redundancies and complexity, then orchestrate agents to implement improvements. **Preserve behavior** unless something is broken.

---

## Protocol
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded\(variant == .cli ? " and identify the correct window" : "").")
1. **Scope & Analyze** – Scout target areas with explore agents, then use \(builderName) with `response_type: "review"` informed by their findings.
2. **Plan** – Use \(builderName) with `response_type: "plan"` and `export_response: true` to generate and export a refactoring plan.
3. **Decompose & Dispatch** – Break the plan into ordered work items and dispatch agents to implement.
4. **Verify** – Check each completed item before proceeding to the next.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Step 0", beforeAction: "analysis", nextStep: "Step 1"))
## Step 1: Scope & Analyze

### 1a. Scout the territory with explore agents

Before calling \(builderName), dispatch explore agents to map the areas the user wants refactored. A quick `get_file_tree` or `file_search` orients you, then spawn 2–3 explore agents for the most relevant areas:

\(example(variant,
	mcp: """
```json
// Quick orientation
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}

// Dispatch explore agents to scout target areas
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Scout: <area 1>",
	"message":"Map <target area>: what are the key types, their responsibilities, and how do they interact? Note any obvious duplication or complexity.",
	"detach":true
}}
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"explore",
	"session_name":"Scout: <area 2>",
	"message":"Check <related area> — what patterns does it use? How does it relate to <area 1>? Any shared logic that could be consolidated?",
	"detach":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'tree'
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Scout: <area 1>" message="Map <area>: key types, responsibilities, interactions. Note duplication." detach=true'
rpce-cli -w <window_id> -e 'agent_run op=start model_id=explore session_name="Scout: <area 2>" message="Check <area> — patterns, relationship to <area 1>, shared logic." detach=true'
```
"""))

Keep each explore prompt **short and focused** — one area per agent. Good: "Map the auth module's types and interactions." Bad: "Find all refactoring opportunities in the codebase."

Collect results before proceeding:

\(example(variant,
	mcp: """
```json
{"tool":"agent_run","args":{"op":"wait","session_ids":["<id_1>","<id_2>"],"timeout":60}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'agent_run op=wait session_ids=["<id_1>","<id_2>"] timeout=60'
```
"""))

Not every refactor needs explore agents. If the user's request already names specific files and the scope is narrow, skip straight to 1b.

### 1b. Analyze with \(builderName) (REQUIRED)

⚠️ Don't skip this step. Use the explore agents' findings to write a well-informed \(builderName) call with `response_type: "review"`:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
	"instructions":"<task>Analyze for refactoring opportunities. Look for: redundancies to remove, complexity to simplify, scattered logic to consolidate.</task>\n\n<context>Target: <files, directory, or recent changes to analyze>.\nGoal: Preserve behavior while improving code organization.\n\nFrom initial scouting:\n- <key finding from explore agent 1>\n- <key finding from explore agent 2>\n- <patterns/duplication already identified></context>\n\n<discovery_agent-guidelines>Focus on <target directories/files informed by scouting>.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task>Analyze for refactoring opportunities. Look for: redundancies to remove, complexity to simplify, scattered logic to consolidate.</task>

<context>Target: <files, directory, or recent changes>.
Goal: Preserve behavior while improving code organization.

From initial scouting:
- <key finding from explore agent 1>
- <key finding from explore agent 2>
- <patterns/duplication already identified></context>

<discovery_agent-guidelines>Focus on <target directories/files informed by scouting>.</discovery_agent-guidelines>" --response-type review'
```
"""))

The explore agents' findings make this call more effective — \(builderName) knows where to look and what patterns to analyze instead of discovering everything from scratch.

Review the findings. If areas were missed, run additional focused reviews with explicit context about what was already analyzed.

## Optional: Clarify Analysis

After receiving analysis findings, you can ask clarifying questions in the same chat:
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"For the duplicate logic you identified, which location should be the canonical one?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -t '<tab_id>' -e 'chat "For the duplicate logic you identified, which location should be the canonical one?" --mode chat'
```

> Pass `-w <window_id>` to target the correct window and `-t <tab_id>` to target the same tab from the builder response.
"""))

## Step 2: Plan the Refactorings (via \(builderName) - REQUIRED)

Once you have a clear list of refactoring opportunities, use \(builderName) with `response_type: "plan"` and `export_response: true` to generate a concrete plan and export it for agents:

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Plan these refactorings in order:</task>\n\n<context>Refactorings to apply:\n1. <specific refactoring with file references>\n2. <specific refactoring with file references>\n\nPreserve existing behavior. Order by: safest/highest-value first, respecting dependencies between changes.</context>\n\n<discovery_agent-guidelines>Focus on files involved in the refactorings.</discovery_agent-guidelines>",
  "response_type":"plan",
  "export_response":true
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task>Plan these refactorings in order:</task>

<context>Refactorings to apply:
1. <specific refactoring with file references>
2. <specific refactoring with file references>

Preserve existing behavior. Order by: safest/highest-value first, respecting dependencies.</context>

<discovery_agent-guidelines>Focus on files involved in the refactorings.</discovery_agent-guidelines>" --response-type plan --export'
```
"""))

The tool returns `oracle_export_path` and `oracle_export_instruction`. Include `oracle_export_path` inside the `message` you send on your next `agent_run` `start` call. The `oracle_export_instruction` field is a ready-made sentence ("Read the Oracle export at `<path>` with `read_file` …") you can emit verbatim at the head of that `message`. The child agent opens the file with `read_file`.

## Step 3: Decompose & Dispatch

Take the plan and break it into **ordered work items**. Refactorings are usually sequential — later changes often depend on structures introduced by earlier ones.

\(sharedDecompositionGuidance(variant: variant, taskNoun: "item"))

### Sequential steering loop

Start a single agent and feed it work **one item at a time**. Refactorings usually compound — later items build on structures introduced in earlier ones — so steering keeps the relevant decisions in working memory, unlike `rp-orchestrate`'s fresh-per-item default.

\(example(variant,
	mcp: """
```json
// 1. Start with the first refactoring item
{"tool":"agent_run","args":{
	"op":"start",
	"model_id":"engineer",
	"session_name":"Refactor: <overall goal>",
	"message":"Read the refactoring plan at <plan path> with read_file first. Implement refactoring item 1: <brief>. Preserve existing behavior."
}}

// 2. Agent completes — verify the change preserves behavior.
//    Spot-check key files:
{"tool":"read_file","args":{"path":"<key file from item 1>"}}

// 3. If satisfied, steer the next item:
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 looks good. Moving on to item 2: <brief>. The structures from item 1 are now in place.",
	"wait":true
}}

// 4. If something's off, steer a correction first:
{"tool":"agent_run","args":{
	"op":"steer",
	"session_id":"<session_id>",
	"message":"Item 1 missed <specific gap>. Please fix before we continue.",
	"wait":true
}}
```
""",
	cli: """
```bash
# 1. Start with the first refactoring item
rpce-cli -w <window_id> -e 'agent_run op=start model_id=engineer session_name="Refactor: <goal>" message="Read the refactoring plan at <plan path> with read_file first. Implement item 1: <brief>. Preserve existing behavior."'

# 2. Verify, then steer the next item
rpce-cli -w <window_id> -e 'read "<key file from item 1>"'
rpce-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 looks good. Item 2: <brief>" wait=true'

# 3. If something's off, steer a correction
rpce-cli -w <window_id> -e 'agent_run op=steer session_id="<session_id>" message="Item 1 missed <gap>. Fix first." wait=true'
```
"""))

Verify each item against the plan's "done when" criteria before steering the next. A quick `read_file` or `file_search` on key files costs little and catches drift early.

**Use `engineer` role** for refactoring items — the plan already makes the path clear, so the agent just needs precise execution. Use `pair` only if an item involves architectural decisions not covered by the plan.

Since refactor relies on extended steering, it's worth checking whether the `engineer` role is powered by a Codex-family model (which handles long steering sessions best).

\(sharedRolesOnlyCheck(variant: variant))

### Writing the dispatch brief

\(sharedDispatchBriefGuidance(variant: variant))

### When to use parallel dispatch

Refactorings that touch **completely independent modules** can run concurrently.

\(sharedParallelDispatchBlock(variant: variant, defaultRole: "engineer"))

Only parallelize when items have **zero file overlap**. When in doubt, run sequentially — refactoring conflicts are painful to untangle.

\(sharedSessionCleanupSection(variant: variant, heading: "### Housekeeping", includeSessionCleanupGuidance: includeSessionCleanupGuidance))
## Step 4: Monitor & Verify

\(sharedMonitorAndVerifyBlock(variant: variant))

\(sharedFinalRollupBlock(variant: variant, taskNoun: "item"))

---

## Anti-patterns to Avoid

- 🚫 This workflow requires \(builderName) for both analysis (Step 1) and planning (Step 2) — don't skip either.\(isAgent ? "" : "\n- 🚫 Skipping Step 0 (Workspace Verification) – you must confirm the target codebase is loaded first")
- 🚫 Skipping Step 1's \(builderName) call with `response_type: "review"` and attempting to analyze manually
- 🚫 Skipping Step 2's \(builderName) call with `response_type: "plan"` — you need a concrete plan before dispatching agents
- 🚫 Extended reading before the first \(builderName) call – a quick skim is fine; let the builder do the heavy lifting
- 🚫 Implementing refactorings yourself — you are the coordinator; dispatch agents to do the work
- 🚫 Dispatching all items at once without verifying each one — refactorings compound; verify before proceeding
- 🚫 Parallelizing items that share files — sequential is safer for dependent refactorings
- 🚫 Forgetting to check on dispatched agents — they may block on permission approvals; poll periodically to keep them unblocked
- 🚫 Assuming you understand the code structure without \(builderName)'s architectural analysis\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")
"""
	}

}
