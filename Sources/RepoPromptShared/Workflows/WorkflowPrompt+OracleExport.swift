import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - ChatGPT Prompt Export

	/// The rp-oracle-export command - exports a prompt file for GPT Pro models on ChatGPT (MCP variant).
	static let rpOracleExport = rpOracleExport(variant: .mcp)

	/// Generate rp-oracle-export for a specific variant.
	static func rpOracleExport(variant: WorkflowPromptVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"
		let isAgent = variant == .agent
		let reviewBudgetRule: String
		let budgetGuidanceLine: String
		let reviewFastPathLine: String
		let reviewDeepPathLine: String

		switch variant {
		case .agent:
			reviewBudgetRule = "Use the workflow's export-mode budget guidance. Only skip `context_builder` when the uncommitted review scope is small enough that the full changed-file review export clearly fits within that budget."
			budgetGuidanceLine = "Use the workflow's export-mode budget guidance unless the user explicitly asks for a leaner or larger export."
			reviewFastPathLine = "For `Review`, the fast path is the **exception**, not the default. It is allowed only when the confirmed scope is **uncommitted changes** and the **full changed-file review scope** clearly fits within the workflow's export-mode budget."
			reviewDeepPathLine = "For `Review`, this is the default path. If the review is not a small uncommitted-change export that clearly fits within the workflow's export-mode budget with all changed files included, `context_builder` is required."
		case .mcp, .cli:
			reviewBudgetRule = "This prompt does not expose the workflow export-mode budget directly. Lean on `context_builder` unless the uncommitted review scope is clearly tiny, obviously bounded, and safe to include in full."
			budgetGuidanceLine = "Because this prompt does not expose the workflow export budget directly, prefer `context_builder` unless the review scope is obviously tiny."
			reviewFastPathLine = "For `Review`, the fast path is the **exception**, not the default. It is allowed only when the confirmed scope is **uncommitted changes** and the **full changed-file review scope** is obviously tiny and safe to include in full. Otherwise require `context_builder`."
			reviewDeepPathLine = "For `Review`, this is the default path. If the review is not a tiny uncommitted-change export that is obviously safe to include in full, `context_builder` is required."
		}

		return """
\(frontmatter(name: "rp-oracle-export", description: "Export a ChatGPT-ready Question / Plan / Review prompt using \(toolDesc)", variant: variant))

# ChatGPT Prompt Export\(suffix)

Raw request: $ARGUMENTS

Your job: select the right files and export a prompt file that another model can act on directly.

**Before you do anything else**, extract the real task from the raw request above. Users often phrase this as "export a prompt for X" or "write a prompt about Y" — strip away any meta-framing about exporting/prompting and identify the underlying problem. For example:
- "export a prompt to evaluate the auth refresh logic" → the task is "evaluate the auth refresh logic"
- "write a ChatGPT prompt about the token caching bug" → the task is "investigate the token caching bug"
- "review the last 3 commits" → the task is already clean

Use the extracted task (not the raw request) for all downstream steps — intent classification, `context_builder` instructions, and the final exported prompt.

## Rules

- Infer **Question / Plan / Review** when obvious. Ask only if unclear.
- For vague requests, use repo evidence before asking questions.
- Use the fast path only when the scope is already small, concrete, and obviously file-local.
- For broad **Question/Plan** exports, `context_builder` is the default path.
- For review exports, `context_builder` is the default path.
- Do **not** spend exploratory tool calls proving that a broad request is complex enough for `context_builder`.
- When you do use `context_builder` here, keep `response_type: "clarify"`.
- If you used the fast path, review the selection and prompt text before exporting.
- If you used `context_builder`, trust its curated selection, budget, and generated prompt by default; only re-check or adjust prompt/selection/tokens if you noticed a concrete issue.
- Export to a unique repo-local file, usually in `prompt-exports/`.
- Derive a short slug from the user's request and use it in the filename.
- Use a relative repo-local path by default; do not use an absolute path or another folder unless the user explicitly asks for it.

## Workflow
\(workspaceVerificationBlock(variant: variant, heading: "### 0", beforeAction: "building context", nextStep: "Step 1"))
### 1. Determine intent and scope

Infer the prompt type from the request:
- **Review** for git diff / PR / branch comparison requests — i.e. the user wants to inspect *changes*
- **Plan** for design / approach / implementation-plan / architectural audit / code evaluation requests — even if the user says "review" or "audit", if there are no diffs involved, this is a Plan
- **Question** only when the user is asking a specific, bounded question with a clear answer
- **When in doubt, default to Plan.** Generic or open-ended requests ("look into X", "help me with Y", "figure out Z") produce better results with the Plan preset, which gives the receiving model structured guidance.

If the request is vague:
- for **Review**: inspect git state first
- for **Question/Plan**: if it sounds broad, architectural, evaluative, redesign-oriented, or likely multi-file, skip manual exploration and go straight to `context_builder`

Ask **one specific question** only if needed, and base it on the repo state you found.
Good question shapes:
- “I see changes in A and B. Do you want review of these current uncommitted changes, or against `main`?”
- “I found likely touchpoints in X and Y. Is the fix plan for X only, or this broader flow?”

\(isAgent ? """
If clarification is needed, use `ask_user`:

```json
{"tool":"ask_user","args":{
  "question":"I found likely scope in <A> and <B>. Which one should the exported prompt focus on?",
  "options":["Focus on A","Focus on B","Cover both"],
  "context":"I want the export scope to match the code I found instead of guessing.",
  "timeout_seconds":90
}}
```
""" : "")
**If the scope is still unclear, STOP and ask the user.** Do not ask generic workflow questions when you could ask a concrete scope question instead.

### 2. Choose context path

\(budgetGuidanceLine)

#### Review

Start by checking git state:
\(example(variant,
	mcp: """
```json
{"tool":"git","args":{"op":"status"}}
{"tool":"git","args":{"op":"diff","detail":"files"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'git status'
rpce-cli -w <window_id> -e 'git diff --detail files'
```
"""))

\(reviewScopeConfirmationBlock(variant: variant, heading: "#### Review Scope Confirmation"))

\(reviewBudgetRule)
\(reviewFastPathLine)
\(reviewDeepPathLine)
For review exports, explicitly reference the diff / changed files in the context you build.

**Always include the phrase "code review" in your `context_builder` instructions for Review exports.** This phrase activates diff analysis in the Context Builder agent. Without it, the builder treats the request as a general exploration.

#### Question / Plan

Default to `context_builder` for any request that is broad, architectural, evaluative, redesign-oriented, or likely to touch multiple files.

Do **not** spend tool calls proving that these requests are complex. If the user is asking you to evaluate logic, assess a design, rethink a flow, or reason about behavior across a system, call `context_builder` immediately.

Use the fast path only when the request is already small and obvious:
\(example(variant,
	mcp: """
```json
{"tool":"file_search","args":{"pattern":"<key term>","mode":"both"}}
```

```json
{"tool":"manage_selection","args":{"op":"add","paths":["RootName/path/to/FileA.swift","RootName/path/to/FileB.swift"]}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'search "<key term>"'
rpce-cli -w <window_id> -e 'select add RootName/path/to/FileA.swift RootName/path/to/FileB.swift'
```
"""))

If there is any real doubt that the fast path will fully cover the task, use `context_builder`.

Otherwise use `context_builder`:
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>The actual problem to solve — not about exporting or prompting</task>\\n<context>Scope: <what you found>.</context>",
  "response_type":"clarify"
}}
```

```json
{"tool":"context_builder","args":{
	"instructions":"<task>Code review of changes against <confirmed_scope>.</task>\\n<context>Intent: code review. Branch: <branch_name>.</context>",
  "response_type":"clarify"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task>The actual problem to solve — not about exporting or prompting</task>
<context>Scope: <what you found>.</context>" --response-type clarify'

rpce-cli -w <window_id> -e 'builder "<task>Code review of changes against <confirmed_scope>.</task>
<context>Intent: code review. Branch: <branch_name>.</context>" --response-type clarify'
```
"""))

### 3. Final check (fast path only — skip after `context_builder`)

**If you used `context_builder`, skip this step entirely and go straight to Step 4.** The builder already curated the selection, managed the token budget, and wrote the prompt. Do not read the prompt back, do not inspect the selection, do not check token counts, and do not critique, rewrite, or "improve" the generated prompt text. Treat the builder's output as the final payload for export.

**If you used the fast path**, check the selection and prompt text before exporting:
\(example(variant,
	mcp: """
```json
{"tool":"manage_selection","args":{"op":"get","view":"summary"}}
```

```json
{"tool":"prompt","args":{"op":"get"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'select get'
rpce-cli -w <window_id> -e 'prompt get'
```
"""))

If available in this surface, the fast path may also inspect token state:
\(example(variant,
	mcp: """
```json
{"tool":"workspace_context","args":{"include":["selection","tokens"]}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'context --include selection,tokens'
```
"""))

If the prompt wording or selection is off, fix it before exporting.

### 4. Export

Use a unique repo-local relative path such as:
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-question-<slug-from-request>.md`
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-plan-<slug-from-request>.md`
- `prompt-exports/<yyyy-mm-dd>-<hhmmss>-review-<slug-from-request>.md`

Choose `<slug-from-request>` by summarizing the user's request into a short filesystem-safe phrase. Prefer descriptive slugs like `collapsing-tool-logic` or `agent-transcript-redesign`, not generic names like `export` or `question`.

Unless the user explicitly asks for another destination, keep the export path relative and repo-local under `prompt-exports/`.

Preset mapping:
- `Question` → `standard` (only for specific, bounded questions)
- `Plan` → `plan` (default for generic, open-ended, or ambiguous requests)
- `Review` → `codeReview`

\(example(variant,
	mcp: """
```json
{"tool":"prompt","args":{"op":"export","path":"prompt-exports/<unique filename>.md","copy_preset":"<standard|plan|codeReview>"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'prompt export "prompt-exports/<unique filename>.md" --copy-preset <standard|plan|codeReview>'
```
"""))

## Anti-patterns

- Asking generic workflow questions before checking repo state
- Skipping `context_builder` for branch / PR / large review exports
- Doing exploratory searches or file reads before `context_builder` for a broad Question/Plan export just to prove the task is complex
- Treating requests like "evaluate this logic", "assess this design", or "rethink this flow" as fast-path exports
- Using the fast path when scope is still vague
- Exporting from the fast path without checking the selection and prompt text
- Re-checking selection, prompt text, or tokens after `context_builder` — the builder already finalized the payload
- Reading the prompt back after `context_builder` to review, critique, rewrite, or "improve" it — export it as-is
- Calling `prompt get`, `manage_selection get`, or `workspace_context` after `context_builder` completed — go straight to export
- Reusing generic filenames like `oracle-prompt.md` by default
- Using generic slugs like `export`, `question`, or `plan` when the request gives you enough detail for a better filename
- Writing to an absolute path or outside the repo by default when the user did not ask for that
- Passing export/prompt meta-framing to `context_builder` — instructions like "export a prompt for X" or "build context for a ChatGPT prompt about Y" cause the builder to write a prompt *about prompting* instead of a prompt that solves X. Always pass the extracted task directly.

Report the final export path, prompt type, whether you used the fast path or `context_builder`, and token count if available.
"""
	}

	/// CLI variant of rp-oracle-export - uses rpce-cli commands.
	static var rpOracleExportCLI: String { rpOracleExport(variant: .cli) }

}
