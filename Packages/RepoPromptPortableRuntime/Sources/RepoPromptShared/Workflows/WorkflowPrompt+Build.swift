import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Shared Core Content

	/// Core MCP Builder workflow content - shared across slash commands, MCP prompts, and copy presets.
	/// Does NOT include surface-specific content like YAML frontmatter or embedded file tree mentions.
	public static let rpBuildCore = rpBuildCore(variant: .mcp)

	/// Generate build workflow content for a specific variant.
	static func rpBuildCore(variant: WorkflowPromptVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatName: String
		let chatToolName: String
		switch variant {
		case .cli: chatName = "`chat`"; chatToolName = "chat"
		case .agent: chatName = "`ask_oracle`"; chatToolName = "ask_oracle"
		case .mcp: chatName = "`oracle_send`"; chatToolName = "oracle_send"
		}
		let isAgent = variant == .agent

		return """
## The Workflow
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded")
1. **Quick scan** – Understand how the task relates to the codebase
2. **Context builder** – Call \(builderName) with a clear prompt to get deep context + an architectural plan
3. **Only if needed, ask \(chatName)** – Use it when navigating the selected code is difficult or the plan leaves a concrete unresolved gap
4. **Implement directly** – Use editing tools to make changes once the plan is clear

---

## Before you implement

Work through the phases in order:
\(isAgent ? "" : "1. Completed Phase 0 (Workspace Verification)\n")\
\(isAgent ? "1" : "2"). Completed Phase 1 (Quick Scan)
\(isAgent ? "2" : "3"). Called \(builderName) and received its plan

The quick scan is orientation only — \(builderName) does the deep exploration and produces the plan. Skipping it tends to produce shallow implementations that miss architectural patterns and edge cases.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Phase 0", beforeAction: "exploration", nextStep: "Phase 1"))
## Phase 1: Quick Scan

Keep this phase brief — \(builderName) handles the deep exploration.

Start by getting a lay of the land with the file tree:
\(example(variant,
	mcp: """
```json
{"tool":"get_file_tree","args":{"type":"files","mode":"auto"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'tree'
```
"""))

Then use targeted searches to understand how the task maps to the codebase:
\(example(variant,
	mcp: """
```json
{"tool":"file_search","args":{"pattern":"<key term from task>","mode":"path"}}
{"tool":"get_code_structure","args":{"paths":["RootName/likely/relevant/area"]}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'search "<key term from task>"'
rpce-cli -w <window_id> -e 'structure RootName/likely/relevant/area/'
```
"""))

Use what you learn to **reformulate the user's prompt** with added clarity—reference specific modules, patterns, or terminology from the codebase.

Your goal is orientation, not deep understanding — \(builderName) does the heavy lifting.

---

## Phase 2: Context Builder

Call \(builderName) with your informed prompt. Use `response_type: "plan"` to get an actionable architectural plan.

\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<reformulated prompt with codebase context>",
  "response_type":"plan"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<reformulated prompt with codebase context>" --response-type plan'
```
"""))

**What you get back:**
- Smart file selection (automatically curated within token budget)
- Architectural plan grounded in actual code
- \(variant == .cli ? "Chat session" : "`chat_id`") for follow-up conversation
\(variant == .cli ? "- `tab_id` for targeting the same tab in subsequent CLI invocations" : "")

\(variant == .cli ? """
**Tab routing:** Each `rpce-cli` invocation is a fresh connection. To continue working in the same tab across separate invocations, pass `-t <tab_id>` (the tab ID returned by builder).
""" : "")
**Trust \(builderName)** – it explores deeply, aggregates the relevant context, and selects intelligently. Default to trusting the plan it returns. The \(chatName) follow-up only reasons over that selected context; it cannot fill coverage gaps on its own.

---

## Phase 3: Ask \(chatName) only if needed

\(chatName) deep-reasons over the files selected by \(builderName). It sees those selected files **completely** (full content, not summaries), but it **only sees what's in the selection** — nothing else.

**This phase is optional.** If the builder's plan is already clear and navigation through the selected code is straightforward, proceed straight to Phase 4.

Bring a follow-up to \(chatName) only when:
- Navigating the selected code proves difficult even with the builder's plan
- You need cross-file reasoning over the files already selected
- The plan leaves a concrete unresolved gap you cannot close by reading the selected files directly

If the answer depends on files outside the current selection, \(chatName) cannot answer it from thin air. Do **not** turn this workflow into manual selection management by default — if coverage is materially wrong, prefer rerunning \(builderName) with a better prompt.

\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"The plan points me to X and Y, but I'm still having trouble tracing how they connect across these selected files. What am I missing, and what edge cases should I watch for?",
  "mode":"plan",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rpce-cli -t '<tab_id>' -e 'chat "The plan points me to X and Y, but I'\''m still having trouble tracing how they connect across these selected files. What am I missing, and what edge cases should I watch for?" --mode plan'
```

> **Note:** Pass `-t <tab_id>` to target the same tab across separate CLI invocations.
"""))

**\(chatName) excels at:**
- Deep reasoning over the context_builder output and selected files
- Spotting cross-file connections that piecemeal reading might miss
- Answering targeted "what am I missing in this selected context" questions

**Don't expect:**
- Knowledge of files outside the selection
- Repository exploration or missing-file discovery — that's \(builderName)'s job
- Implementation — that's your job

---

## Phase 4: Direct Implementation

Before implementing, verify you have:
- [ ] \(variant == .cli ? "A builder result available (`tab_id` if follow-up is needed)" : "A builder result available (`chat_id` if follow-up is needed)")
- [ ] An architectural plan grounded in actual code

If a specific point is still unclear, use \(chatName) to clarify before proceeding.

Implement the plan directly with the editing tools; use \(chatName) only for reasoning over the selected context.

**Primary tools:**
\(example(variant,
	mcp: """
```json
// Modify existing files (search/replace)
{"tool":"apply_edits","args":{"path":"Root/File.swift","search":"old","replace":"new","verbose":true}}

// Create new files (auto-added to selection)
{"tool":"file_actions","args":{"action":"create","path":"Root/NewFile.swift","content":"..."}}

// Read specific sections during implementation
{"tool":"read_file","args":{"path":"Root/File.swift","start_line":50,"limit":30}}
```
""",
	cli: """
```bash
# Modify existing files (search/replace) - JSON format required
rpce-cli -w <window_id> -e 'call apply_edits {"path":"Root/File.swift","search":"old","replace":"new"}'

# Multiline edits
rpce-cli -w <window_id> -e 'call apply_edits {"path":"Root/File.swift","search":"old\\ntext","replace":"new\\ntext"}'

# Create new files
rpce-cli -w <window_id> -e 'file create Root/NewFile.swift "content..."'

# Read specific sections during implementation
rpce-cli -w <window_id> -e 'read Root/File.swift --start-line 50 --limit 30'
```
"""))

**Ask \(chatName) only when navigation or cross-file reasoning is the bottleneck:**
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<same chat_id>",
  "message":"I'm implementing X. The plan does not fully explain Y, and reading the selected files still leaves a gap. What pattern or connection am I missing here?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -t '<tab_id>' -e 'chat "I'\''m implementing X. The plan does not fully explain Y, and reading the selected files still leaves a gap. What pattern or connection am I missing here?" --mode chat'
```
"""))

---

## Key Guidelines

**Token limit:** Stay under ~160k tokens. Check with \(variant == .cli ? "`select get`" : "`manage_selection(op:\"get\")`") if unsure. Context builder manages this, but be aware if you add files.

**Selection coverage:**
- \(builderName) should already have selected the files needed for the plan
- \(chatName) can reason only over that selected context; it cannot discover missing files on its own
- If a material coverage gap blocks you, prefer rerunning \(builderName) with a better prompt over hand-curating selection
- Use `manage_selection` only as a last resort for a very small, targeted addition

**\(chatName) sees only the selection:** If the answer depends on files outside the selection, \(chatName) cannot provide it until coverage changes — and in this workflow, coverage changes should usually come from \(builderName), not from manual curation.

---

## Anti-patterns to Avoid

- 🚫 Asking \(chatName) to implement changes for you – implement directly with editing tools
- 🚫 Asking \(chatName) about files it cannot see in the current selection
- 🚫 Treating Phase 3 as mandatory when the builder's plan is already clear
- 🚫 Reopening or second-guessing the builder's plan by default instead of trusting it
- 🚫 Leaning on manual `manage_selection` work to patch coverage gaps that should be handled by \(builderName)
- 🚫 Skipping \(builderName) and going straight to implementation – you'll miss context
- 🚫 Using `manage_selection` with `op:"clear"` – this undoes \(builderName)'s work; only use small targeted additions if absolutely necessary
- 🚫 Exceeding ~160k tokens – use slices if needed
- 🚫 Extended reading before calling \(builderName) – a quick skim is fine; let the builder do the heavy lifting
- 🚫 Reading full file contents during Phase 1 – save that for after \(builderName) builds context
- 🚫 Convincing yourself you understand enough to skip \(builderName) – you don't\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")

---

**Your job:** Get a solid plan from \(builderName), trust it by default, use \(chatName) only when navigating the selected code proves difficult or the plan leaves a concrete unresolved gap, then implement directly and completely.
"""
	}

	/// The rp-build slash command - context builder workflow (MCP variant).
	static let rpBuild = rpBuild(variant: .mcp)

	/// Generate rp-build for a specific variant.
	static func rpBuild(variant: WorkflowPromptVariant) -> String {
		let suffix: String
		let title: String
		switch variant {
		case .cli: suffix = " (CLI)"; title = "CLI Builder Mode"
		case .agent: suffix = ""; title = "Builder Mode"
		case .mcp: suffix = ""; title = "MCP Builder Mode"
		}
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"

		return """
\(frontmatter(name: "rp-build", description: "Build with \(toolDesc) context builder plan → implement", variant: variant))

# \(title)\(suffix)

Task: $ARGUMENTS

Build deep context via \(builderName) to get a plan, then implement directly. Use follow-up reasoning only when navigating the selected code proves difficult or the plan leaves a concrete gap.

\(variant.preamble)\(rpBuildCore(variant: variant))
"""
	}
}
