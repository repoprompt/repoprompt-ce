import Foundation

extension RepoPromptWorkflowPrompts {
	// MARK: - Review

	/// The rp-review slash command - code review workflow (MCP variant).
	static let rpReview = rpReview(variant: .mcp)

	/// Generate rp-review for a specific variant.
	static func rpReview(variant: WorkflowPromptVariant) -> String {
		let suffix = variant == .cli ? " (CLI)" : ""
		let toolDesc = variant == .cli ? "rpce-cli" : "RepoPrompt MCP tools"

		return """
\(frontmatter(name: "rp-review", description: "Code review workflow using \(toolDesc) git tool and context_builder", variant: variant))

# Code Review Mode\(suffix)

Review: $ARGUMENTS

You are a **Code Reviewer** using \(toolDesc). Your workflow: understand the scope of changes, gather context, and provide thorough, actionable code review feedback.

\(variant.preamble)\(rpReviewCore(variant: variant))
"""
	}

	/// CLI variant of rp-review.
	static var rpReviewCLI: String { rpReview(variant: .cli) }

	/// Core review workflow content.
	static func rpReviewCore(variant: WorkflowPromptVariant) -> String {
		let builderName = variant == .cli ? "`builder`" : "`context_builder`"
		let chatToolName = variant == .agent ? "ask_oracle" : "oracle_send"
		let isAgent = variant == .agent

		return """
## Protocol
\(isAgent ? "" : "\n0. **Verify workspace** – Confirm the target codebase is loaded\(variant == .cli ? " and identify the correct window" : "").")
1. **Survey changes** – Check git state and recent commits to understand what's changed.
2. **Determine scope** – Infer the comparison scope from the user's request. Only ask for clarification if the scope is ambiguous or unspecified.
3. **Deep review** – Run \(builderName) with `response_type: "review"`, explicitly specifying the confirmed comparison scope.
4. **Fill gaps** – If the review missed areas, run focused follow-up reviews explicitly describing what was/wasn't covered.

---
\(workspaceVerificationBlock(variant: variant, heading: "## Step 0", beforeAction: "git operations", nextStep: "Step 1"))
## Step 1: Survey Changes
\(example(variant,
	mcp: """
```json
{"tool":"git","args":{"op":"status"}}
{"tool":"git","args":{"op":"log","count":10}}
{"tool":"git","args":{"op":"diff","detail":"files"}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'git status'
rpce-cli -w <window_id> -e 'git log --count 10'
rpce-cli -w <window_id> -e 'git diff --detail files'
```
"""))

\(reviewScopeConfirmationBlock(variant: variant))

## Step 3: Deep Review (via \(builderName) - REQUIRED)

⚠️ Don't skip this step. Call \(builderName) with `response_type: "review"` for proper code review context.

Include the confirmed comparison scope in your instructions so the context builder knows exactly what to review.

Use XML tags to structure the instructions:
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Review changes comparing <current_branch> against <confirmed_comparison_target>. Focus on correctness, security, API changes, error handling.</task>\n\n<context>Comparison: <confirmed_scope> (e.g., 'uncommitted', 'main', 'staged')\nCurrent branch: <branch_name>\nChanged files: <list key files from git diff></context>\n\n<discovery_agent-guidelines>Focus on the directories containing changes.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task>Review changes comparing <current_branch> against <confirmed_comparison_target>. Focus on correctness, security, API changes, error handling.</task>

<context>Comparison: <confirmed_scope> (e.g., uncommitted, main, staged)
Current branch: <branch_name>
Changed files: <list key files></context>

<discovery_agent-guidelines>Focus on directories containing changes.</discovery_agent-guidelines>" --response-type review'
```
"""))
\(variant == .cli ? "\n**Tab routing:** The builder response returns a `tab_id` — pass `-t <tab_id>` in follow-up `chat` invocations to continue the same conversation.\n" : "")
## Optional: Clarify Findings

After receiving review findings, you can ask clarifying questions in the same chat:
\(example(variant,
	mcp: """
```json
{"tool":"\(chatToolName)","args":{
  "chat_id":"<from context_builder>",
  "message":"Can you explain the security concern in more detail? What's the attack vector?",
  "mode":"chat",
  "new_chat":false
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -t '<tab_id>' -e 'chat "Can you explain the security concern in more detail? What'\\''s the attack vector?" --mode chat'
```

> Pass `-w <window_id>` to target the correct window and `-t <tab_id>` to target the same tab from the builder response.
"""))

## Step 4: Fill Gaps

If the review omitted significant areas, run a focused follow-up. **Explicitly describe** what was already covered and what needs review now (\(builderName) has no memory of previous runs):
\(example(variant,
	mcp: """
```json
{"tool":"context_builder","args":{
  "instructions":"<task>Review <specific area> in depth.</task>\n\n<context>Previous review covered: <list files/areas reviewed>.\nNot yet reviewed: <list files/areas to review now>.</context>\n\n<discovery_agent-guidelines>Focus specifically on <directories/files not yet covered>.</discovery_agent-guidelines>",
  "response_type":"review"
}}
```
""",
	cli: """
```bash
rpce-cli -w <window_id> -e 'builder "<task>Review <specific area> in depth.</task>

<context>Previous review covered: <list files/areas reviewed>.
Not yet reviewed: <list files/areas to review now>.</context>

<discovery_agent-guidelines>Focus specifically on <directories/files not yet covered>.</discovery_agent-guidelines>" --response-type review'
```
"""))

---

## Anti-patterns to Avoid

- 🚫 Proceeding with an ambiguous scope – if the user didn't specify a comparison target and it's unclear from context, you must ask before calling \(builderName)
- 🚫 Skipping \(builderName) and attempting to review by reading files manually – you'll miss architectural context
- 🚫 Calling \(builderName) without specifying the confirmed comparison scope in the instructions
- 🚫 Doing extensive file reading before calling \(builderName) – git status/log/diff is sufficient for Step 1
- 🚫 Providing review feedback without first calling \(builderName) with `response_type: "review"`
- 🚫 Assuming the git diff alone is sufficient context for a thorough review
- 🚫 Reading changed files manually instead of letting \(builderName) build proper review context\(variant == .cli ? "\n- 🚫 **CLI:** Forgetting to pass `-w <window_id>` – CLI invocations are stateless and require explicit window targeting" : "")

---

## Output Format (be concise, max 15 bullets total)

- **Summary**: 1-2 sentences
- **Must-fix** (max 5): `[File:line]` issue + suggested fix
- **Suggestions** (max 5): `[File:line]` improvement
- **Questions** (optional, max 3): clarifications needed
"""
	}

	static func reviewScopeConfirmationBlock(variant: WorkflowPromptVariant, heading: String = "## Step 2: Determine Comparison Scope") -> String {
		let isAgent = variant == .agent
		return """
\(heading)

Determine the comparison scope from the user's request and git state.

**If the user already specified a clear comparison target** (e.g., "review against main", "compare with develop", "review last 3 commits"), **skip confirmation and proceed** using the scope they specified.

**If the scope is ambiguous or not specified**, ask the user to clarify:
- **Current branch**: What branch are you on? (from git status)
- **Comparison target**: What should changes be compared against?
  - `uncommitted` – All uncommitted changes vs HEAD (default)
  - `staged` – Only staged changes vs HEAD
  - `back:N` – Last N commits
  - `main` or `master` – Compare current branch against trunk
  - `<branch_name>` – Compare against specific branch

\(isAgent ? """
If clarification is needed, use `ask_user`:

```json
{"tool":"ask_user","args":{
  "question":"You're on branch `feature/xyz`. What should I compare against?\\n- `uncommitted` (default) - review all uncommitted changes\\n- `main` - review all changes on this branch vs main\\n- Other branch name?"
}}
```
""" : """
**Example prompt to user (only if scope is unclear):**
> "You're on branch `feature/xyz`. What should I compare against?
> - `uncommitted` (default) - review all uncommitted changes
> - `main` - review all changes on this branch vs main
> - Other branch name?"

**If you need to ask, STOP and wait for user confirmation before proceeding.**
""")
"""
	}

}
