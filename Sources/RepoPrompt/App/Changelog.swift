//
//  Changelog.swift
import Foundation
import MarkdownUI
import SwiftUI

struct Version: Identifiable {
    let id: String
    let buildNumber: Int
    let date: Date
    let changes: String
}

class Changelog {
    static let current = Version(
        id: "2.1.24",
        buildNumber: 326,
        date: ISO8601DateFormatter().date(from: "2026-05-09T00:00:00Z") ?? Date(),
        changes: """
        ## [2.1.24] - 2026-05-09

        ### Improvements
        - Codex /goal now works alongside selected app workflows, and typed goal objectives appear immediately as user bubbles in Agent Mode
        - Staged /goal drafts are now visible in the Agent Mode status row
        - ask_user prompts no longer expire while you're typing your answer
        - Faster file tree updates during heavy filesystem activity
        - Updated Z.ai GLM defaults to GLM-5.2 with 1M-context Claude Code routing support

        ### Fixes
        - Fixed file tree churn when folders changed on disk
        - Fixed Oracle preview transcripts showing in the wrong chat
        - Fixed the prompt export copy button disappearing in long Agent Mode sessions
        - Fixed Codex goal tracking when using /goal control actions
        - Deep Plan now waits for you instead of silently defaulting when an involvement checkpoint times out

        ### Notes
        - The agent_run MCP/CLI surface no longer accepts the native_workflow parameter — Codex /goal and /computer-use remain available as in-app slash commands
        """
    )

    static let _210 = Version(
        id: "2.1.0",
        buildNumber: 302,
        date: ISO8601DateFormatter().date(from: "2026-04-02T00:00:00Z") ?? Date(),
        changes: """
        ## [2.1.0] - 2026-04-02

        ### New Features
        - MCP-controlled agents and sub-agents — start and steer Agent Mode sessions from external MCP clients or the CLI, with cross-family sub-agent support (Claude can steer Codex, Codex can steer Claude)
        - Agent role defaults — configure default models per agent role (explore, engineer, pair, design) with per-role override controls

        ### Improvements
        - Faster window restore — consolidated session data loading for less main-thread blocking
        - Cleaner MCP API — dedicated manage_selection and prompt tools replace context_state; chat tools renamed to oracle for consistency
        - New context_bind tool — easier workspace binding via working directories
        - Cmd+W now stashes compose tabs instead of closing them

        ### Fixes
        - Improved app stability — fixed crashes on deeply nested directory trees
        - Fixed memory retention issues for large repositories
        - Fixed file_search hanging on regex patterns with .* or .+ quantifiers
        - Fixed detached transcript jump-to-top restore
        """
    )

    static let history: [Version] = [
        Version(
            id: "2.1.24",
            buildNumber: 326,
            date: ISO8601DateFormatter().date(from: "2026-05-09T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.24] - 2026-05-09

            ### Improvements
            - Codex /goal now works alongside selected app workflows, and typed goal objectives appear immediately as user bubbles in Agent Mode
            - Staged /goal drafts are now visible in the Agent Mode status row
            - ask_user prompts no longer expire while you're typing your answer
            - Faster file tree updates during heavy filesystem activity
            - Updated Z.ai GLM defaults to GLM-5.2 with 1M-context Claude Code routing support

            ### Fixes
            - Fixed file tree churn when folders changed on disk
            - Fixed Oracle preview transcripts showing in the wrong chat
            - Fixed the prompt export copy button disappearing in long Agent Mode sessions
            - Fixed Codex goal tracking when using /goal control actions
            - Deep Plan now waits for you instead of silently defaulting when an involvement checkpoint times out

            ### Notes
            - The agent_run MCP/CLI surface no longer accepts the native_workflow parameter — Codex /goal and /computer-use remain available as in-app slash commands
            """
        ),
        Version(
            id: "2.1.23",
            buildNumber: 325,
            date: ISO8601DateFormatter().date(from: "2026-05-08T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.23] - 2026-05-08

            ### New Features
            - Added Deep Plan, a new Agent Mode workflow for more thorough planning sessions
            - Added Codex /goal support so you can set or update a Codex thread goal directly from Agent Mode
            - Added Agent Workflows settings for managing built-in workflow visibility, featured workflows, custom workflow markdown, and cleanup guidance
            - Added Codex and Claude permission/runtime controls directly in CLI Providers settings

            ### Improvements
            - Reduced memory retained by codemap scanning in large workspaces
            - Faster rendering for long Agent Mode assistant transcripts
            - More compact file_search results with less noisy nested path output
            - Gemini headless agents now use the shared ACP path for more consistent permission handling
            - Updated agent defaults and recommendations to prefer GPT-5.5 Low for lighter-weight Explore and Engineer work
            - Clearer, more user-focused Agent Mode workflow descriptions
            """
        ),
        Version(
            id: "2.1.22",
            buildNumber: 324,
            date: ISO8601DateFormatter().date(from: "2026-05-07T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.22] - 2026-05-07

            ### Improvements
            - Faster Agent Mode sidebar in large workspaces
            - Codex agent thread names now stay in sync with Agent Mode session names
            - Cleaner, more focused chat mode responses
            - Gemini agents now launch in untrusted workspaces when MCP is configured
            - Clearer error messages when agents fail to delete files
            - Improved coordination when agents delegate work to other agents

            ### Fixes
            - Fixed startup crashes related to socket setup
            - Fixed crashes when launching Codex, Claude, or Gemini agents
            - Fixed wrong file tree root labels in multi-root Agent Mode sessions
            - Gemini agent errors now show useful detail instead of "Internal error"
            """
        ),
        Version(
            id: "2.1.21",
            buildNumber: 323,
            date: ISO8601DateFormatter().date(from: "2026-05-06T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.21] - 2026-05-06

            ### New Features
            - Codex auto review permission mode — automatically grants safe approvals during code review runs
            - Codex now supports a wider range of permission prompts in Agent Mode

            ### Improvements
            - Much faster workspace switching, especially when restoring chat sessions
            - Much faster chat token previews in large workspaces
            - Font scaling fixes — large and normal presets now update live across Agent Mode, Chat, file trees, Settings, workspace pickers, and Oracle without clipped or bloated layouts
            - Sub-agent permission settings now apply consistently to agents started over MCP
            - Oracle review status stays scoped to the originating Agent Mode thread instead of leaking into other tabs
            - Hardened Cursor / OpenCode lifecycle — addresses the crash reported in 2.1.20
            - Stronger MCP routing isolation — restricted agents are no longer asked to call hidden routing tools, and stale clients can no longer claim run policies
            - Safer steering — Claude interrupts now wait for in-flight child agent waits to drain
            - Cleaner sidebar status plate — MCP-controlled rows align consistently with regular rows; running spinner no longer shows a disc behind the arc

            ### Fixes
            - Fixed Codex file-change approval stalls — agents now resume immediately after you approve
            - Tolerate Codex versions that don't yet support the optional memory mode
            - Fixed the agent image attachment picker — now opens for new compose tabs and anchors to the right window
            - Protected Codex model selections from being downgraded by older settings
            - Fixed MCP sub-agent permission activation
            """
        ),
        Version(
            id: "2.1.20",
            buildNumber: 322,
            date: ISO8601DateFormatter().date(from: "2026-04-24T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.20] - 2026-04-24

            ### Improvements
            - Agent Mode sidebar shows persistent attention badges when background tabs complete, fail, or start waiting — so status changes in collapsed or off-screen sessions aren't missed
            - Faster session switching in Agent Mode — eliminated duplicate transcript and runtime refreshes when flipping between running sessions
            - Agent logs (`get_log`) now preserve assistant narration in correct chronological order around tool calls
            - Tightened agent sidebar row density, with collapsed threads propagating unseen status counts
            - Added debug-only Agent Mode diagnostics (Claude raw event logging, performance metrics)

            ### Fixes
            - Fixed multi-session agent waits waking prematurely on transient instruction-delivered or steering events
            - Fixed Claude tool cards staying stuck when provider completion IDs didn't align with MCP tracker IDs
            - Full agent session UUIDs are now preserved in multi-session tool output (previously truncated to 8 characters, breaking follow-up wait/poll calls)
            - Fixed stale workspace bindings left behind after MCP cleanup of child agent sessions
            - Stabilized runtime sidebar when collapsing/expanding session details
            """
        ),
        Version(
            id: "2.1.19",
            buildNumber: 321,
            date: ISO8601DateFormatter().date(from: "2026-04-24T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.19] - 2026-04-24

            ### New Features
            - New rp-optimize skill — iterative performance optimization workflow with a measure-first loop and scoreboard tracking
            - Collapse/expand-all-threads button in the Agent Mode sidebar — tuck away nested sub-agent chats in one click

            ### Improvements
            - UX cleanup of the Agent Mode sidebar and composer
            - Reduced CPU usage from the cancel affordance animation and sidebar refresh

            ### Fixes
            - Quick Apply All recommendations now recomputes state so still-unsatisfied items remain visible
            - Chat session model selection no longer rewrites the global compose default
            - Codex apply-patch disable now uses the canonical override
            - Fixed Agent Mode compose button icon optical centering
            - Fixed rp-orchestrate/rp-refactor Codex-family role check
            """
        ),
        Version(
            id: "2.1.18",
            buildNumber: 320,
            date: ISO8601DateFormatter().date(from: "2026-04-23T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.18] - 2026-04-23

            ### New Features
            - GPT-5.5 Codex models — new High/Medium variants, now preferred over GPT-5.4 across defaults and recommendations
            - Oracle support for Claude-compatible providers — Kimi and Custom backends are now selectable Oracle models
            - Collapsible sub-agent threads in the Agent Mode sidebar
            - Auto-archive of stale agent sessions, with Today/Yesterday/Previous date separators
            - MCP file deletes now go to Trash instead of being permanently removed
            - Optional MCP onboarding — Pro setup now leads with CLI Providers; Skip All drops you straight into Agent Mode

            ### Improvements
            - New "Agent Models" setting to prevent models from picking random models via MCP agent tools
            - Faster session list restore

            ### Fixes
            - Fixed Oracle recommendation upgrade detection — users on Gemini now correctly prompted to upgrade to Codex GPT-5.5 High after connecting Codex CLI
            - Fixed OpenCode ACP empty responses with Kimi K2.6
            - Fixed Claude MCP steering queue race that could report accepted steers as failed
            - Fixed Claude Code model ordering
            """
        ),
        Version(
            id: "2.1.17",
            buildNumber: 319,
            date: ISO8601DateFormatter().date(from: "2026-04-22T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.17] - 2026-04-22

            ### New Features
            - New Claude Code-compatible backends: CC Moonshot (Kimi), CC Custom, and CC Zai
            - New "Agent cleanup guidance" setting

            ### Improvements
            - Performance improvements to UI responsiveness and workspace opening
            - Improved investigate workflow with better sub-agent management
            - Improved sub-agent guidance to better coordinate with the orchestrator when help is required
            - Cleaner Agent Mode Overview settings page
            - Command execution now captures complete terminal output before finalizing

            ### Fixes
            - Fixed Claude steering queue race
            - Fixed session reuse issues when switching Claude backend variants
            """
        ),
        Version(
            id: "2.1.16",
            buildNumber: 318,
            date: ISO8601DateFormatter().date(from: "2026-04-21T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.16] - 2026-04-21

            ### New Features
            - Design-role agents now produce a structured markdown report (Context, Findings, Recommendations) for review, architecture-critique, and analysis tasks. The report path is surfaced in the final summary so you can open it directly.

            ### Improvements
            - Expanded explore-agent dispatch guidance so agents make better judgment calls about when to spawn a sub-agent versus reading files inline
            - Progress updates now stream across all agent providers (previously Codex-only), so you see interleaved status messages regardless of model
            - Tightened role guidance in rp-orchestrate — smaller models stay within the assigned role (pair/engineer/design/explore) instead of fabricating model-based downgrades
            - Cleaner, grouped summaries in the agent control row
            - Quieter, coalesced status messages when running Context Builder with OpenCode

            ### Fixes
            - Fixed a crash when an agent message mentioned the same file more than once
            - Fixed sub-agent lineage mapping in the sidebar
            """
        ),
        Version(
            id: "2.1.15",
            buildNumber: 317,
            date: ISO8601DateFormatter().date(from: "2026-04-21T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.15] - 2026-04-21

            ### Fixes
            - Fixed a deadlock that could hang the app when running multiple parallel agents (e.g. concurrent orchestration or investigation workflows). Force Quit was sometimes required to recover.
            - Agent handoff/fork from historical messages now uses the authoritative transcript, so forks no longer incorrectly include the latest conversation state
            - Invalid handoff cutoff IDs are rejected up front
            - OpenCode Context Builder Agent logs no longer flooded by context builder noise
            - Z.ai GLM activation and settings discoverability restored in CLI Providers

            ### Improvements
            - Agent Mode sidebar consolidated into two popovers: **Models** (Oracle/Plan model, Context Builder, sub-agent role defaults) and **Permissions** (sub-agent policy picker with deep links)
            - Agent Permissions Overview groups Direct and Sub-Agent scopes under one card, with the active sub-agent policy shown inline
            - Per-provider sub-agent permission levels — choose each provider's native permission levels instead of abstract policies
            - Agent Models settings surfaces related cross-links (Oracle Model Presets, Delegated Edits, Benchmark Model) in a Related Settings section
            """
        ),
        Version(
            id: "2.1.14",
            buildNumber: 316,
            date: ISO8601DateFormatter().date(from: "2026-04-20T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.14] - 2026-04-20

            ### New Features
            - Redesigned Settings with a dedicated window, modernized sidebar, and agent-first organization that progressively reveals advanced options
            - Agent Models settings — a new home for configuring recommendations and model selection per agent role
            - Agent Permissions settings with separate scopes for direct and sub-agent permissions, and a tri-state sub-agent policy
            - Toolbar update pill — surfaces available Sparkle updates directly in the toolbar
            - App Settings MCP tool — query and update app preferences from MCP clients and the CLI, with an `options` op for discovering allowed values
            - Agent Explore tool — a lightweight, read-only exploration tool for sub-agent contexts

            ### Improvements
            - Secure storage for agent and provider permission preferences
            - Global settings now backed by JSON in Application Support; presets moved alongside
            - Refined Settings typography, spacing, and section layouts throughout
            - Claude reasoning now shown in live agent status
            - Claude Code auto permission mode supported for Opus 1M
            - Cleaner update notifications with separate passive vs. user-initiated flows
            - Copy button on agent error bubbles
            - Reorganized orchestration skills (rp-orchestrate, rp-investigate) for clearer delegation
            - Updated Gemini recommendation defaults

            ### Fixes
            - Hardened MCP transport lifecycle and compatibility edge cases
            - Agent file mention display and caret placement
            - Claude auto permission fallback behavior
            - `file_actions` now requires absolute paths to prevent ambiguity
            - `app_settings` accepts string-encoded booleans and numbers from MCP clients
            """
        ),
        Version(
            id: "2.1.13",
            buildNumber: 315,
            date: ISO8601DateFormatter().date(from: "2026-04-17T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.13] - 2026-04-17

            ### New Features
            - Option to disable Code Maps in Advanced Settings — turn off code map generation across all workspaces
            - Codex "fast" model variants for GPT-5.3+ — pick fast variants directly in the model picker; replaces the separate fast mode toggle
            - Granular Claude Code CLI model options — more model choices in the Claude Code picker
            - Live Claude flag updates — permission and flag changes apply mid-session without restarting

            ### Improvements
            - Reduced VCS status command storms — fewer redundant git/jj status refreshes on large repos
            - Investigation, refactor, and orchestrate workflows now remind the caller agent to periodically poll sub-agents so pending permission approvals don't stall progress
            - Reordered agent composer capsules for clearer grouping — Pair/Interview/Workflow on the left, Oracle next to Fast/context on the right

            ### Fixes
            - Fixed crash when MCP file reads received paths containing NUL characters
            - Fixed Claude Code Auto (Preview) permissions not always initializing correctly on new sessions
            - Now warns when an MCP steer call's timeout is silently ignored
            """
        ),
        Version(
            id: "2.1.11",
            buildNumber: 313,
            date: ISO8601DateFormatter().date(from: "2026-04-16T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.11] - 2026-04-16

            ### New Features
            - Claude Code Auto (Preview) permissions mode — auto-approves tool calls that pass background safety checks (research preview; behavior may change)
            - Compose tab capacity policy — background agent tabs can exceed the normal soft tab limit with auto-stashing that protects active or pinned agent sessions from eviction
            - Orchestration-style refactor workflow — redesigned around analyze → plan → dispatch → verify, with parallel agents for independent modules
            - Parallel exploration in the investigate workflow — dispatch explore agents alongside your own research to test hypotheses faster
            - Explore agents can now be used proactively without explicit invocation (engineer, pair, and design still require opt-in)

            ### Improvements
            - Faster sidebar loading via a new agent session metadata index
            - Long agent chats are better optimized — transcript handling stays responsive as conversations grow
            - Folder list in workspace roots now scrolls gracefully when many folders are present
            - Claude model picker ordering refinements and effort-level filtering aligned to supported models

            ### Fixes
            - Fixed MCP composer chrome tab switching
            - Fixed context builder cancel controls
            - Fixed Codex watchdog falsely triggering during agent_run waits
            """
        ),
        Version(
            id: "2.1.10",
            buildNumber: 312,
            date: ISO8601DateFormatter().date(from: "2026-04-15T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.10] - 2026-04-15

            ### New Features
            - Global keyboard shortcuts — rebindable hotkeys for Agent new chat and sidebar toggle
            - Dedicated Keyboard Shortcuts settings tab with a full rebindable catalog
            - Cursor ACP full access permissions
            - Claude Code XHigh effort tier
            - Claude Code model picker lists pinned Sonnet/Opus/Haiku 4.5, 4.6, and 4.7 full model IDs alongside the generic "Latest" aliases

            ### Improvements
            - Claude model pickers now let you choose model and effort together, matching Codex picker grouping
            - Claude Code defaults to Opus Latest instead of the vague "Default" placeholder, and the generic aliases read as "Sonnet Latest", "Opus Latest", "Haiku Latest", and "Opus Latest (1M)"
            - Live steering for ACP agents — safely interrupt and re-prompt active sessions; multiple steering prompts are queued and delivered in order
            - Scoped deep-link routing — clicking an agent notification opens the correct window, workspace, tab, and session
            - Agent handoff picker now reconciles with available agents and models, disabling unavailable options with clear UI feedback
            - Unified provider preferences — consistent permission handling across all agent providers
            - Cleaner transcripts — empty or whitespace-only assistant messages no longer appear in transcripts or summaries
            - Cleaner Cursor ACP tool cards — placeholder tool events are filtered out
            - Gemini session safety — model selection is locked during Gemini runs to prevent accidental overrides on resumed chats
            """
        ),
        Version(
            id: "2.1.9",
            buildNumber: 311,
            date: ISO8601DateFormatter().date(from: "2026-04-14T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.9] - 2026-04-14

            ### Fixes
            - Fixed Cursor MCP configuration — removed transient project config writes during Cursor ACP launch to avoid unnecessary filesystem side effects
            """
        ),
        Version(
            id: "2.1.8",
            buildNumber: 310,
            date: ISO8601DateFormatter().date(from: "2026-04-14T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.8] - 2026-04-14

            ### New Features
            - Cursor CLI agent support — full Agent Mode integration with dynamic model discovery, auto model fallback, and ACP session management
            - Workspace hiding — hide and restore workspaces from the manager
            - Agent handoff export — new MCP surfaces for exporting agent transcripts between windows and agents

            ### Improvements
            - Bounded memory usage in codemap and ignore caches for large repos
            - Generalized ACP tool lifecycle handling for more consistent tool cards across providers
            - Cleaner RepoPrompt tool name parsing from ACP session titles
            - OpenCode running tool updates render more smoothly
            - Suppressed noisy session resume replay events when reopening ACP agents
            - Selection CLI output respects full paths when requested

            ### Fixes
            - Fixed Tree-sitter scan crash
            - Fixed ACP auto-approval for RepoPrompt tools
            - Fixed stale codemap cache reuse across worktrees
            - Fixed OpenCode "none" variant grouping in model picker
            - Fixed agent input capsule vertical offset
            - Fixed markdown code block spacing
            - Restored persisted tool result subtitles after transcript reload
            - Fixed path regex anchor search in file finder

            ### Removed
            - Removed diff capability allowlists — model diff support is now universal
            """
        ),
        Version(
            id: "2.1.7",
            buildNumber: 309,
            date: ISO8601DateFormatter().date(from: "2026-04-13T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.7] - 2026-04-13

            ### New Features
            - MCP permission override — new setting to turn off the enforced safe permission defaults for MCP sub-agents
            - Workspace cleanup UI — collapse duplicate workspace records and clean up stale entries
            - ACP image attachments — send images through ACP-connected agents

            ### Improvements
            - Much faster codemap generation
            - Faster search across large repos
            - Faster transcript refresh in long chats
            - Faster gitignore matching
            - Faster file edits
            - OpenCode models grouped by provider in model pickers for easier selection
            - Faster OpenCode/ACP model picker — model cache now warms in the background
            - Agent mode polish — stable attachment composer, refined window tint and titles
            - Better MCP regex errors — clearer compile error messages and more reliable auto-detection

            ### Fixes
            - Fixed OpenCode permission controls
            - Fixed agent sidebar rename
            - Fixed expanded user bubble height
            - Fixed Codex empty base instructions
            - Fixed Claude skill discovery roots
            - Fixed provider ID fallback from display name in model catalog
            - Sanitized persisted transcript tool payloads
            - Improved gitignore unignore handling
            - Blocked MCP agent runs without a workspace open
            """
        ),
        Version(
            id: "2.1.6",
            buildNumber: 308,
            date: ISO8601DateFormatter().date(from: "2026-04-10T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.6] - 2026-04-10

            ### New Features
            - OpenCode Agent Provider — full support for OpenCode as an Agent Mode provider, including ACP integration, dynamic model polling, settings, and discovery

            ### Improvements
            - Agent providers gated by connected CLIs — Agent Mode only shows providers whose CLIs are actually available
            - Codex CLI path preflight — validates the Codex executable before launching, with clearer error messages when the CLI isn't found
            - Improved Codex connection flow — clearer setup and authentication UI for Codex
            - Improved CLI process launching — better detection of your PATH variables ensures CLI providers launch more reliably

            ### Fixes
            - Fixed agent transcript scrolling — restored transcripts now scroll correctly
            - Fixed prompt export — exports now correctly use the workspace root
            - Fixed Codex error reporting — errors are now shown instead of failing silently

            ### Removed
            - Sidebar terminal — removed the integrated terminal from the sidebar
            """
        ),
        Version(
            id: "2.1.5",
            buildNumber: 307,
            date: ISO8601DateFormatter().date(from: "2026-04-08T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.5] - 2026-04-08

            ### New Features
            - context_builder and oracle can now export their responses directly
            - Orchestrate workflow available as an MCP prompt and installable managed skill
            - GPT-5.4 Mini API model variants with low, high, and xhigh reasoning tiers

            ### Improvements
            - Agent mode elapsed timer stays accurate when steering active sessions
            - Improved scroll behavior in agent transcripts — better detection of manual scroll intent
            - Smarter workspace binding — bind_context falls back to repo_paths superset matching when no exact match exists
            - Orchestrate workflow uses phased verify-then-steer loop for more reliable agent delegation

            ### Fixes
            - Fixed Codex not being able to perform edits in Delegated Edit mode
            - Fixed several issues related to ACP
            - Fixed stale agent sessions after app restart — orphaned active states are now properly cancelled
            """
        ),
        Version(
            id: "2.1.4",
            buildNumber: 306,
            date: ISO8601DateFormatter().date(from: "2026-04-08T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.4] - 2026-04-08

            ### New Features
            - Gemini CLI now uses ACP — text streaming, permission support, bash tool access, automatic model detection, and significantly better performance
            - Orchestrate workflow — new agent workflow for planning tasks and delegating to sub-agents
            - Interview mode — agents can ask clarifying questions before starting a workflow to ensure clarity on the task
            - Reasoning levels for OpenAI custom models — choose reasoning effort when using custom OpenAI Responses API models
            - Claude CLI system prompt options — control how the RepoPrompt system prompt is delivered, including passing it as a user message
            - Provider filtering in recommendations — temporarily filter out providers hitting rate limits so the recommendation system steers you elsewhere
            - Await multiple agents — `agent_manage` tool can now wait on multiple running agent sessions simultaneously

            ### Improvements
            - Elapsed runtime display on active agent runs
            - Run-scoped cancel button for active MCP tool cards
            - Per-provider model registry with persistence and dynamic picker
            - Improved sidebar session ordering and session state filtering
            - Agent views performance improvements

            ### Fixes
            - Fixed schema definition for a tool that caused intermittent issues with some agents
            - Fixed workspace restore session binding during tab switches
            - Fixed MCP agent sub-agent spawning permissions and approval handling
            - Added a fix button to unstick the agent scrollview when it gets stuck
            """
        ),
        Version(
            id: "2.1.3",
            buildNumber: 305,
            date: ISO8601DateFormatter().date(from: "2026-04-04T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.3] - 2026-04-04

            ### Improvements
            - Smarter workspace binding — `bind_context` now resolves workspaces by matching repo paths against open folders
            - Auto-switches workspace in the target window when the matched workspace isn't already active
            - Clearer `bind_context` responses showing match method, candidate counts, and actionable error messages

            ### Fixes
            - Fixed branch comparison diffs showing wrong files — review mode and MCP diff tools now use merge-base semantics, preventing base branch changes from being misattributed as your work
            - Fixed bash tool cards auto-expanding when the agent stream returned to idle
            - Filtered noisy diagnostic output from Context Builder agent logs
            """
        ),
        Version(
            id: "2.1.2",
            buildNumber: 304,
            date: ISO8601DateFormatter().date(from: "2026-04-03T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.2] - 2026-04-03

            ### Improvements
            - Restored backwards compatibility for `list_tabs` and `select_tab` actions, easing migration from 2.0.x
            - Unified MCP client ID matching for more reliable tool connections across different client variants
            - RepoPrompt MCP tool permissions are now auto-approved, reducing manual approval prompts during agent runs
            - Clearer error messages when MCP tools can't find a valid context

            ### Fixes
            - Fixed permissions not being properly handled for sub-agents in some cases
            - Fixed steering sub-agents not working correctly in some cases
            - Fixed only being able to start one sub-agent at a time via MCP
            - Fixed stale terminal snapshots from previous agent runs interfering with new runs
            """
        ),
        Version(
            id: "2.1.1",
            buildNumber: 303,
            date: ISO8601DateFormatter().date(from: "2026-04-02T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.1] - 2026-04-02

            ### Fixes
            - Fixed Claude Code support over MCP
            """
        ),
        Version(
            id: "2.1.0",
            buildNumber: 302,
            date: ISO8601DateFormatter().date(from: "2026-04-02T00:00:00Z") ?? Date(),
            changes: """
            ## [2.1.0] - 2026-04-02

            ### New Features
            - MCP-controlled agents and sub-agents — start and steer Agent Mode sessions from external MCP clients or the CLI, with cross-family sub-agent support (Claude can steer Codex, Codex can steer Claude)
            - Agent role defaults — configure default models per agent role (explore, engineer, pair, design) with per-role override controls

            ### Improvements
            - Faster window restore — consolidated session data loading for less main-thread blocking
            - Cleaner MCP API — dedicated manage_selection and prompt tools replace context_state; chat tools renamed to oracle for consistency
            - New context_bind tool — easier workspace binding via working directories
            - Cmd+W now stashes compose tabs instead of closing them

            ### Fixes
            - Improved app stability — fixed crashes on deeply nested directory trees
            - Fixed memory retention issues for large repositories
            - Fixed file_search hanging on regex patterns with .* or .+ quantifiers
            - Fixed detached transcript jump-to-top restore
            """
        ),
        Version(
            id: "2.0.31",
            buildNumber: 301,
            date: ISO8601DateFormatter().date(from: "2026-03-30T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.31] - 2026-03-30

            ### Improvements
            - Restored GLM 5.0 as an API provider model for Oracle and Chat alongside 5.1
            - Prompt export now strips meta-framing and defaults ambiguous requests to Plan mode

            ### Fixes
            - Fixed legacy chat markdown rendering at incorrect widths
            """
        ),
        Version(
            id: "2.0.30",
            buildNumber: 300,
            date: ISO8601DateFormatter().date(from: "2026-03-30T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.30] - 2026-03-30

            ### Improvements
            - Smoother, more responsive chat scrolling with less jitter during streaming
            - Session handoff now preserves richer context when forking conversations
            - Collapsed history summaries render faster with precomputed details

            ### Fixes
            - Fixed chat scroll views getting stuck or not following new content
            - Fixed inconsistent transcript rendering when switching sessions
            """
        ),
        Version(
            id: "2.0.29",
            buildNumber: 299,
            date: ISO8601DateFormatter().date(from: "2026-03-27T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.29] - 2026-03-27

            ### New Features
            - Codex agent mode now supports user input requests for clarification and approval

            ### Improvements
            - Improved transcript auto-scroll reliability with better layout settling and viewport detection

            ### Fixes
            - Fixed apply_patch tool cards reverting from completed to running state when late output arrives
            - Fixed bash tool cards not auto-expanding inside grouped transcript blocks
            - Fixed Codex reconnection interrupting active threads
            """
        ),
        Version(
            id: "2.0.28",
            buildNumber: 298,
            date: ISO8601DateFormatter().date(from: "2026-03-27T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.28] - 2026-03-27

            ### New Features
            - Added GPT-5.4 Fast service tier support for Codex CLI provider
            - Added GLM 5.1 model support for Z.AI
            - Tool search is now a separate preference in Claude Code agent mode, independent from MCP strict mode

            ### Improvements
            - Better tool result preservation during session handoff and migration
            - Improved transcript scrolling performance

            ### Fixes
            - Fixed Codex rejecting MCP tool calls when running context builder by adding proper operation annotations
            - Fixed crash when viewing archived sessions with duplicate sidebar tabs
            - Fixed Claude context usage displaying inflated values
            - Fixed crash in text editor when handling mention inputs
            - Fixed potential race condition in token calculations
            - Improved file system event handling stability and reduced memory allocations
            """
        ),
        Version(
            id: "2.0.27",
            buildNumber: 297,
            date: ISO8601DateFormatter().date(from: "2026-03-27T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.27] - 2026-03-27

            ### Fixes
            - Fixed a regression from 2.0.26 that could strip detail from transcript turns during compaction
            - Disabled Codex app server elicitation support to prevent connection issues
            """
        ),
        Version(
            id: "2.0.26",
            buildNumber: 296,
            date: ISO8601DateFormatter().date(from: "2026-03-26T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.26] - 2026-03-26

            ### New Features
            - Effort level picker — Choose between Low, Medium, High, and Max effort levels for Claude directly from the input bar
            - MCP strict mode toggle — Control whether Claude Code runs in strict MCP mode; disabling allows additional MCP servers

            ### Improvements
            - Smarter session sidebar — Better prioritization of active and archived sessions
            - Reduced memory usage — Older transcript content is now compacted more aggressively to keep sessions lightweight
            - Smoother scrolling — Fixed several scroll state bugs and improved scroll reliability

            ### Fixes
            - Fixed workflow and attachments lost on first message — Selected workflow and pending attachments now carry over correctly when starting a new session
            - Fixed MCP server registration — Corrected an issue where --env flags weren't parsed correctly when adding Claude MCP servers
            """
        ),
        Version(
            id: "2.0.25",
            buildNumber: 295,
            date: ISO8601DateFormatter().date(from: "2026-03-23T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.25] - 2026-03-23

            ### Improvements
            - Improved chat auto-scroll reliability — auto-follow now recovers correctly after content settles
            - Streaming assistant responses render more smoothly with less layout thrashing
            - Improved performance and reliability of file tree updates, especially in large repos

            ### Fixes
            - Fixed auto-scroll getting stuck after streaming activity settles
            - Fixed unwanted scroll-to-bottom while actively scrolling
            """
        ),
        Version(
            id: "2.0.24",
            buildNumber: 294,
            date: ISO8601DateFormatter().date(from: "2026-03-20T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.24] - 2026-03-20

            ### Improvements
            - Editor tabs preserved on close — tabs are now stashed by default when closing, so your workspace is restored next time
            - Agent Oracle pill — Updated to use a brain icon for better clarity
            - Improved Claude Code integration — Better MCP environment defaults for more reliable connections
            - Agent mode performance — Improved scroll stability and reduced unnecessary re-renders during long sessions
            - Refined tool cards — Improved summaries and status indicators for agent tool results

            ### Fixes
            - Fixed transcript scroll getting stuck during long agent conversations
            - Fixed window session state not saving correctly on app quit
            - Fixed skill/command names failing with strict validators
            """
        ),
        Version(
            id: "2.0.23",
            buildNumber: 293,
            date: ISO8601DateFormatter().date(from: "2026-03-19T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.23] - 2026-03-19

            ### New Features
            - GLM 5 Turbo support — New model option available for Claude Code integrations, with updated defaults (GLM 5 Turbo for Sonnet tier, GLM 4.7 for Haiku tier)
            - Codex automatic auth recovery — RepoPrompt now detects ChatGPT authentication failures and surfaces a login prompt to recover the session without manually reconnecting

            ### Improvements
            - Richer agent tool cards — Tool results show more status detail and better visual indicators during and after execution
            - Bash result cards auto-expand — Recent and in-progress bash commands automatically expand in the tool panel for easier monitoring
            - Smarter session creation — New tabs no longer create blank agent sessions when opened outside of agent mode
            """
        ),
        Version(
            id: "2.0.22",
            buildNumber: 292,
            date: ISO8601DateFormatter().date(from: "2026-03-18T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.22] - 2026-03-18

            ### Improvements
            - Further improved auto-follow scroll behavior in agent chat when reaching the end of a run
            - Improved scroll behavior in unified diff views

            ### Fixes
            - Fixed missing session metadata causing incorrect sidebar titles and sort order for older sessions
            """
        ),
        Version(
            id: "2.0.21",
            buildNumber: 291,
            date: ISO8601DateFormatter().date(from: "2026-03-17T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.21] - 2026-03-17

            ### New Features
            - Pin compose tabs to keep important sessions at the top of the sidebar
            - Confirmation prompt before closing windows with active MCP connections (Cmd+W)
            - Confirmation prompt before deleting a workspace to prevent accidental deletions

            ### Improvements
            - Improved unified diff rendering with accurate hunk positioning and line change stats
            - Better session continuity when interrupting and resuming Claude runs
            - Optimized agent mode chat view and improved scrolling behavior

            ### Fixes
            - Fixed skills being auto-invoked by Codex when they should require explicit invocation
            - Fixed active tab state not restoring correctly after switching sessions
            - Fixed auto-selected files losing their full selection when reading slices
            - Improved reliability and performance of git diff review workflows
            """
        ),
        Version(
            id: "2.0.20",
            buildNumber: 290,
            date: ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.20] - 2026-03-12

            ### Fixes
            - Fixed architect prompt being too language-specific
            """
        ),
        Version(
            id: "2.0.19",
            buildNumber: 289,
            date: ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.19] - 2026-03-12

            ### Improvements
            - Much improved scroll stability during agent runs

            ### Fixes
            - Fixed token count inflation in Manual preset when codemap was disabled
            - Fixed agent file tag context selection

            ### Agent Workflows
            - Refreshed agent workflow tooltips and descriptions for clarity

            ### MCP
            - New MCP commands for creating and closing compose tabs
            - MCP agents can now access chats scoped to the current compose tab
            """
        ),
        Version(
            id: "2.0.18",
            buildNumber: 288,
            date: ISO8601DateFormatter().date(from: "2026-03-10T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.18] - 2026-03-10

            ### Fixes
            - Fixed several performance and stability issues introduced in the previous update
            - Fixed agent transcript rendering accuracy and tool execution state consistency
            - Fixed copy-to-clipboard button for generated plans in the Context Builder agent
            """
        ),
        Version(
            id: "2.0.17",
            buildNumber: 287,
            date: ISO8601DateFormatter().date(from: "2026-03-10T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.17] - 2026-03-10

            ### New Features
            - Agent transcript now uses a structured turn-based model with smart compaction, keeping your most important context while managing long sessions efficiently
            - ChatGPT export now supports planning and code review workflows, designed for use with GPT-4.5 Pro

            ### Improvements
            - Transcript export now includes grouped history summaries with condensed tool previews
            - Tool previews in export now exclude failed or cancelled executions for cleaner output
            - Improved architect system prompt
            - Workflow selection UI improvements

            ### Fixes
            - Fixed git tool not using the system PATH, which could prevent tools like git LFS from being found
            - Fixed a breaking change with the Codex app server
            """
        ),
        Version(
            id: "2.0.16",
            buildNumber: 286,
            date: ISO8601DateFormatter().date(from: "2026-03-05T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.16] - 2026-03-05

            ### Fixes
            - Fixed session scroll in Codex agent mode
            - Fixed tool boundary isolation for Codex
            """
        ),
        Version(
            id: "2.0.15",
            buildNumber: 285,
            date: ISO8601DateFormatter().date(from: "2026-03-05T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.15] - 2026-03-05

            ### New Features
            - Added GPT-5.4 model support
            - Added Codex fast mode toggle and compact command

            ### Improvements
            - Improved search with smarter pattern matching and warnings when a search is auto-corrected
            - Codex reasoning messages are no longer shown in the feed
            - Agent instruction files are excluded from auto-selection
            - Performance improvements across file browsing, selection, and git diff operations

            ### Fixes
            - Fixed context builder token budget drift when called via MCP
            - Fixed crash when opening the workflows popover
            - Fixed Codex approval failures due to wire format mismatch
            - Fixed bash liveness detection causing hangs
            - Fixed agent mode model picker appearing too narrow
            """
        ),
        Version(
            id: "2.0.14",
            buildNumber: 284,
            date: ISO8601DateFormatter().date(from: "2026-03-04T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.14] - 2026-03-04

            ### Improvements
            - **Agent Mode (Codex)**: Revamped system prompt encourages natural preamble output; reasoning messages now update the status bar instead of flooding the chat; improved tool card rendering
            - **Architect/Plan prompt** modernized for agentic workflows with better guidance for multi-step planning
            - **Plan & Build / rp-build** workflow is now more efficient
            - **MCP tool improvements**: Fixed incorrect search failures; improved path semantics across all tools in multi-root workspaces for more consistent behavior
            - Oracle Export is now clearly labeled as **ChatGPT Prompt Export**, making its purpose more obvious for ChatGPT Pro users
            - ChatGPT Prompt Export tool card now includes a **Copy Prompt button** for easily passing prompts from Agent Mode into external tools
            - Cleaner UX around model selection in Agent Mode
            - Codex provider stability improvements

            ### Fixes
            - Removed deprecated Gemini 3.0 Pro (being shut down)
            """
        ),
        Version(
            id: "2.0.13",
            buildNumber: 283,
            date: ISO8601DateFormatter().date(from: "2026-03-02T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.13] - 2026-03-02

            ### New Features
            - Added Claude GLM as a Claude Code option using your confirmed Z.ai API key with native Claude environment support

            ### Improvements
            - Codex agent timeouts are now logged as warnings in the agent log instead of failing the run

            ### Fixes
            - Fixed delegate edit so file changes are reported more reliably
            - OpenRouter settings now update more reliably when configuration changes

            ### Note
            - If recent Codex CLI changes are causing connectivity issues, we currently recommend rolling back to Codex CLI 104
            """
        ),
        Version(
            id: "2.0.12",
            buildNumber: 282,
            date: ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.12] - 2026-03-01

            ### Improvements
            - Codex agent sessions now detect stalls and automatically recover
            - Codex resume timeouts now fall back to a fresh session instead of getting stuck
            - Codex model list now syncs more reliably without unnecessary reloads

            ### Fixes
            - Fixed agent sessions showing errors when switching tabs or restarting; sessions now recover automatically
            - Fixed background processes not cleaning up properly on exit
            - Fixed occasional hangs when closing windows or quitting the app
            - Fixed occasional UI glitches in the toolbar and MCP server panel
            """
        ),
        Version(
            id: "2.0.11",
            buildNumber: 281,
            date: ISO8601DateFormatter().date(from: "2026-02-27T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.11] - 2026-02-27

            ### New Features
            - **Agent session handoff** — Transfer an agent chat transcript and context to a new tab or a different agent, preserving full conversation continuity
            - **Fork sessions from the transcript** — Create a new agent session branching from any message bubble in a transcript
            - **Agent-scoped slash command discovery** — Slash commands and skills are now discovered based on the active agent (Claude Code uses `.claude/commands/`, Codex/Gemini use `.agents/slash/`)
            - **Remember last-used agent** — New agent tabs now open with your previously selected agent (Claude/Codex/Gemini) instead of always defaulting to Claude Code

            ### Improvements
            - Significantly reduced token usage in Codex agent sessions
            - Greatly improved Codex session stability and recovery, including better cancellation handling and recovery from unresponsive states

            ### Fixes
            - Fixed Oracle UI and workflow selections leaking between multiple chat tabs
            - Fixed autocomplete suggestion overlay rendering at the wrong size when the first result set is empty
            - Fixed a race condition where Claude could miss tool results when steering interrupts were sent quickly
            - Transient stream connection errors are now handled gracefully instead of failing the request
            """
        ),
        Version(
            id: "2.0.10",
            buildNumber: 280,
            date: ISO8601DateFormatter().date(from: "2026-02-25T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.10] - 2026-02-25

            ### New Features
            - **File tagging in agent chat** — Type `@filename` in agent messages to attach file contents directly as context. Includes a smart suggestion overlay with fuzzy matching and disambiguation for duplicate filenames
            - **Support for skills via `/` commands** — Skill files are now detected from all loaded workspace directories and the global skills folder, and can be invoked with `/skillname` in agent input with autocomplete suggestions
            - **GLM5 support in ZAI provider** — GLM5 is now available for chat and oracle

            ### Improvements
            - Steering messages to Claude now wait for active tool calls to finish before sending, preventing crashes and ensuring correct message ordering
            - Cancelled or failed steering drafts are restored to the input bar instead of being lost
            - Improved Codex stability and addressed hanging output

            ### Fixes
            - Fixed Claude tool call requests including wrong tools, causing prolonged and failing discovery and delegate edit runs
            - Fixed Context Builder agent not receiving the correct timeout setting
            """
        ),
        Version(
            id: "2.0.9",
            buildNumber: 279,
            date: ISO8601DateFormatter().date(from: "2026-02-23T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.9] - 2026-02-23

            ### New Features
            - **Claude Agent Out of Beta** — Full support for native reasoning traces, steering, bash tool calls, and approval flows, powered by the headless CLI you already have installed
            - Added Gemini 3.1 Pro Preview model support

            ### Improvements
            - **Revamped Bash Tool Call Cards** — New cards for both Codex and Claude with auto-expansion for the latest completed command, better output rendering, and improved status tracking
            - Revamped Review prompt and tightened rp-review prompt
            - Reasoning effort preference is now saved across sessions
            - Tool configuration panels replaced with integrated menus for a cleaner, faster workflow

            ### Fixes
            - Fixed Codex agent failing to reconnect properly after disconnects
            - Fixed history panel auto-revealing during active agent runs or streaming
            """
        ),
        Version(
            id: "2.0.8",
            buildNumber: 278,
            date: ISO8601DateFormatter().date(from: "2026-02-18T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.8] - 2026-02-18

            ### Improvements
            - Improved Codex agent connection routing reliability in multi-window environments
            - Enhanced connection recovery and session continuity during reconnects
            """
        ),
        Version(
            id: "2.0.6",
            buildNumber: 276,
            date: ISO8601DateFormatter().date(from: "2026-02-18T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.6] - 2026-02-18

            ### Fixes
            - Reverted some Codex changes that caused instability
            """
        ),
        Version(
            id: "2.0.5",
            buildNumber: 275,
            date: ISO8601DateFormatter().date(from: "2026-02-18T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.5] - 2026-02-18

            ### New Features
            - **Custom Agent Workflows** — Create, clone, and configure custom agent workflows with a new workflow manager UI
            - **Oracle Chat Log Tool** — New oracle_chat_log tool gives agents read-only access to recent chat history for better context recovery
            - **Context Builder Plan Streaming** — Context builder plans now stream in real-time with cancellation support

            ### Improvements
            - **Codex Streaming** — When using Codex CLI for oracle/chat models, responses now stream in real time instead of completing all at once
            - **Image Paste** — Reworked agent mode image pasting to resolve many cases of failed pastes
            - **Session Resume** — Improved agent session resume stability
            - **Skills Rework** — Skills for MCP/CLI have been reworked to use the correct structure

            ### Fixes
            - Fixed a rare crash with Codex
            - Fixed app hangs when scrolling back up through old sessions
            - Fixed an issue with Codex where third-party MCP tools were getting filtered out
            """
        ),
        Version(
            id: "2.0.4",
            buildNumber: 274,
            date: ISO8601DateFormatter().date(from: "2026-02-14T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.4] - 2026-02-14

            ### Fixes
            - Fixed context builder calls failing to resolve the correct tab during agent mode chats
            """
        ),
        Version(
            id: "2.0.3",
            buildNumber: 273,
            date: ISO8601DateFormatter().date(from: "2026-02-14T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.3] - 2026-02-14

            ### Fixes
            - Fixed dropped messages in Codex agent mode chats
            - Fixed memory leaks in agent mode during extended sessions with heavy tool usage
            - Improved event stream stability to prevent concurrency issues during agent runs
            """
        ),
        Version(
            id: "2.0.2",
            buildNumber: 272,
            date: ISO8601DateFormatter().date(from: "2026-02-13T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.2] - 2026-02-13

            ### New Features
            - **Image pasting support** - Paste images directly into conversations
            - **Improved image support for Claude and Gemini**

            ### Improvements
            - **Significantly improved command execution reliability in Codex Agent Mode** - More accurate tracking of running processes, cleaner output display, and better session stability with retry logic
            - **Toggle to always expand tool cards in Agent Mode** - Available in the new agent settings menu
            - **Improved diff rendering** - More context lines and cleaner hunk separation
            - **Smoother UI performance** - Reduced unnecessary UI refreshes, optimized loading indicator, and improved autoscrolling behavior
            - **Improved model selection sorting** - Models sorted by version families with better default collapsing

            ### Fixes
            - Fixed auto model retrieval for Codex
            """
        ),
        Version(
            id: "2.0.1",
            buildNumber: 271,
            date: ISO8601DateFormatter().date(from: "2026-02-11T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0.1] - 2026-02-11

            ### New: Repo Prompt Agent
            A completely new way to use Repo Prompt. Repo Prompt Agent is a fully integrated agent harness that brings interactive, agentic coding sessions directly into the app.

            - **Full native support for Codex** - Rich integration with the Codex app server for the best agent experience
            - **Beta support for Claude Code and Gemini** - Interactive agentic sessions via headless CLIs (long chats may have limitations)
            - **First-class Context Builder integration** - Agents can leverage Repo Prompt's context building workflows for deeper codebase understanding
            - **Optional edit review** - Review and approve each edit the agent makes before it's applied
            - **Image support** - Paste or drag-and-drop images into agent conversations
            - **Session management** - Resume sessions, track token usage, and manage multiple agent conversations
            - **Configurable tool preferences (Codex)** - Control which tools agents can use, including approval policies and sandbox modes
            - **Selectable reasoning effort (Codex)** - Fine-tune agent behavior with adjustable reasoning effort levels

            ### New: Agent Onboarding
            - Guided onboarding wizard for setting up Agent Mode, including license activation, provider testing, and MCP server configuration
            """
        ),
        Version(
            id: "2.0",
            buildNumber: 270,
            date: ISO8601DateFormatter().date(from: "2026-02-11T00:00:00Z") ?? Date(),
            changes: """
            ## [2.0] - 2026-02-11

            ### New: Repo Prompt Agent
            A completely new way to use Repo Prompt. Repo Prompt Agent is a fully integrated agent harness that brings interactive, agentic coding sessions directly into the app.

            - **Full native support for Codex** - Rich integration with the Codex app server for the best agent experience
            - **Beta support for Claude Code and Gemini** - Interactive agentic sessions via headless CLIs (long chats may have limitations)
            - **First-class Context Builder integration** - Agents can leverage Repo Prompt's context building workflows for deeper codebase understanding
            - **Optional edit review** - Review and approve each edit the agent makes before it's applied
            - **Image support** - Paste or drag-and-drop images into agent conversations
            - **Session management** - Resume sessions, track token usage, and manage multiple agent conversations
            - **Configurable tool preferences (Codex)** - Control which tools agents can use, including approval policies and sandbox modes
            - **Selectable reasoning effort (Codex)** - Fine-tune agent behavior with adjustable reasoning effort levels

            ### New: Agent Onboarding
            - Guided onboarding wizard for setting up Agent Mode, including license activation, provider testing, and MCP server configuration
            """
        ),
        Version(
            id: "1.6.14",
            buildNumber: 269,
            date: ISO8601DateFormatter().date(from: "2026-02-06T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.14] - 2026-02-06

            ### New Features (CLI)
            - **Machine-readable tool schemas** - New `--tools-schema` flag and `tools --schema` command for structured JSON output of tool definitions, enabling integration with external systems
            - **JSON file/stdin support** - Pass JSON arguments via `@file` or `@-` (stdin) for easier handling of complex payloads

            ### Improvements
            - **Improved git tool diff detail levels** - New "patches" detail level for truncated diffs; "full" now provides complete untruncated output
            - **Better Context Builder agent guidance** - Context builder now explores more broadly and effectively when analyzing codebases
            - **Smarter CLI JSON parsing** - Auto-detects JSON files and auto-repairs common formatting issues from LLM outputs

            ### Fixes
            - **Fixed silent failures in apply_edits replace-all** - Now shows a clear error when no matches are found instead of silently succeeding
            """
        ),
        Version(
            id: "1.6.13",
            buildNumber: 268,
            date: ISO8601DateFormatter().date(from: "2026-02-05T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.13] - 2026-02-05

            ### Improvements
            - **Updated to GPT-5.3 Codex and Claude Opus 4.6** - Upgraded to the latest models for improved coding performance and context building

            ### Fixes
            - **Fixed MCP server approval flow** - Resolved issues with stale auto-denials and duplicate approval requests
            - **Improved MCP connection management** - Better handling of connection slots when at capacity
            - **Fixed folder management for system workspaces** - Prevented folders from being incorrectly added to or loaded in system workspaces
            - **Fixed proxy mode startup** - Resolved false exits caused by MCP host delays
            """
        ),
        Version(
            id: "1.6.12",
            buildNumber: 266,
            date: ISO8601DateFormatter().date(from: "2026-02-04T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.12] - 2026-02-04

            ### New Features
            - **Select as Codemap** - New context menu option to mark files or folders as codemap-only directly from the file tree
            - **Tab management** - Added "Close All Tabs" and "Clear All Stashed Tabs" actions for better tab control
            - **Skills installer** - Renamed "Commands" to "Skills" with support for both project-local and global (`~/.agents/skills/`) installation for cross-agent compatibility

            ### Improvements
            - **Workspace switching confirmation** - Prompts before switching workspaces if active chat sessions or context builders could be disrupted
            - **Faster workspace exit** - Improved performance when closing workspaces with many folders
            - **Better context menu organization** - Reordered and grouped context menu items with separators for clarity
            - **MCP connection reliability** - Added health checks, auto-restart, and retry logic for more robust MCP connections
            - **Large table rendering** - Tables with many rows now render more efficiently with a simpler fallback
            - **Improved rp workflows** - Updated prompts for better code generation guidance
            - **Window tools always available** - List and select window tools now always exposed, with list windows showing all opened roots for easier binding

            ### Fixes
            - **Sidebar resize fix** - Fixed UI indicator that was preventing sidebar from being resized
            - **Thread safety improvements** - Fixed various async/concurrency issues throughout the app
            """
        ),
        Version(
            id: "1.6.11",
            buildNumber: 265,
            date: ISO8601DateFormatter().date(from: "2026-02-02T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.11] - 2026-02-02

            ### Improvements
            - **MCP server self-healing** - Automatically recovers MCP server connections when they drop unexpectedly
            - **Smarter file search** - Auto-detects regex patterns vs literal text, making searches more intuitive
            - **Whole-word matching** - New option for precise searches that match complete words only
            - **Improved edit reliability** - Automatically handles escaped characters (like \\n) in edit operations without manual intervention
            - **Better search guidance** - Suggests exploring file tree when search returns empty due to path filters

            ### Fixes
            - **Fixed potential edit failures** - Edit operations now work correctly when search text contains escape sequences
            """
        ),
        Version(
            id: "1.6.10",
            buildNumber: 264,
            date: ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.10] - 2026-02-01

            ### Improvements
            - **Better TypeScript/TSX code maps** - Improved parsing and signature extraction for TypeScript and TSX files, with better handling of multi-line function signatures, type annotations, and React components
            - **Improved MCP connection stability** - Fixed issues where long-lived idle connections could cause session blocking or connection capacity exhaustion, now with keepalive pings and automatic cleanup of stale connections
            - **Auto-approved MCP clients** - Built-in clients like Claude Code are now automatically approved without manual addition to the allow-list

            ### Fixes
            - **Fixed UI freezing during startup**
            - **Fixed MCP reconnection issues** - Improved handling of reconnects and transient denials to prevent unnecessary session blocking
            - **Fixed type detection regression for auto codemaps**
            """
        ),
        Version(
            id: "1.6.9",
            buildNumber: 263,
            date: ISO8601DateFormatter().date(from: "2026-01-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.9] - 2026-01-31

            ### New Features
            - **Ruby language support** - Code structure analysis now supports Ruby files with Tree-sitter integration
            - **OpenAI service tier variants** - Choose service tier (auto, default, flex) per-model in the model picker, with a new global default tier setting

            ### Improvements
            - **Code structure enhancements**
              - Line numbers now included for function/method definitions, helping AI models locate and read code more efficiently
              - Improved parsing accuracy for Swift, TypeScript, JavaScript, C/C++, Dart, and other languages
              - Better handling of complex signatures, nested types, and class/interface boundaries
              - Performance improvements with regex caching and optimized line handling
            - **Model picker refinements** - Cleaner UI with legacy models hidden, unified planning model handling, and improved model selection consistency
            - **Path resolution improvements** - Root folder names now work as aliases in search filters and file resolution
            - **API fixes** - Temperature parameter no longer sent to reasoning models (which don't support it)
            """
        ),
        Version(
            id: "1.6.8",
            buildNumber: 262,
            date: ISO8601DateFormatter().date(from: "2026-01-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.8] - 2026-01-28

            ### Fixes
            - Fixed inconsistent handling of file creation and moving in multi-root workspaces
            """
        ),
        Version(
            id: "1.6.7",
            buildNumber: 261,
            date: ISO8601DateFormatter().date(from: "2026-01-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.7] - 2026-01-27

            ### Fixes
            - Fixed MCP compatibility with Codex by adding resource handling support
            """
        ),
        Version(
            id: "1.6.6",
            buildNumber: 260,
            date: ISO8601DateFormatter().date(from: "2026-01-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.6] - 2026-01-27

            ### Fixes
            - Fixed token reporting for context builder
            - Fixed potential hangs in Context Builder agent when errors occurred during streaming
            - Improved agent lifecycle management to prevent stale routing state
            """
        ),
        Version(
            id: "1.6.5",
            buildNumber: 259,
            date: ISO8601DateFormatter().date(from: "2026-01-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.5] - 2026-01-26

            ### Improvements
            - Folder sorting operations are now much faster
            - File system operations are more efficient
            - Symlink traversal can now be enabled for folders (note: folders outside the repo may not have their updates tracked correctly)
            - Optimized apply_edits diff logic

            ### Fixes
            - Stability fixes for MCP connectivity
            - Miscellaneous performance and stability improvements
            """
        ),
        Version(
            id: "1.6.4",
            buildNumber: 258,
            date: ISO8601DateFormatter().date(from: "2026-01-23T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.4] - 2026-01-23

            ### New Features
            - **Git Worktree Support** - Compare diffs across worktrees and linked checkouts, with worktree info displayed in git operations (branch names, main checkout references). Use "main" or "trunk" aliases in compare specs for intuitive diff comparisons.

            ### Improvements
            - Better file creation handling in multi-root workspaces - paths with folder aliases now resolve correctly
            - Git diff caching is more accurate, detecting file changes better and avoiding stale results
            - Codex CLI is now prioritized as the recommended chat backend for better cost efficiency
            - MCP tool connections are now more reliable - tools only become available once fully initialized
            - Improved tool documentation for better clarity and usability

            ### Fixes
            - Fixed Codex CLI not being able to use the git tool in some cases
            - Fixed apply_edits line count reporting - changed line counts now accurately reported
            - Fixed lingering tools in Context Builder (Claude Code) - tools properly cleaned up after Context Builder runs
            - Fixed race condition where MCP clients could receive incomplete tool lists on fast connections
            """
        ),
        Version(
            id: "1.6.3",
            buildNumber: 257,
            date: ISO8601DateFormatter().date(from: "2026-01-23T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.3] - 2026-01-23

            ### New Features
            - **Selectable follow-up types in Context Builder** - Choose between Plan, Review, or Question modes when auto-generating from discovery results

            ### Improvements
            - **Optimized Context Builder streaming** - Improved performance of the Context Builder view during streaming responses
            - **Better markdown table display** - Tables now render in a horizontally scrollable view, preserving column alignment without wrapping

            ### Fixes
            - Fixed Review mode not working when started from the Context Builder interface
            - Fixed delegate edit tools not appearing in Delegated Edit mode in some cases
            - Fixed git tool not being available to external agents (Codex)
            """
        ),
        Version(
            id: "1.6.1",
            buildNumber: 255,
            date: ISO8601DateFormatter().date(from: "2026-01-22T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.1] - 2026-01-22

            ### New Features
            - **Jujutsu (jj) VCS Support** - RepoPrompt now supports Jujutsu version control alongside Git, with automatic detection and seamless switching between backends

            ### Improvements
            - **file_search is now 80% more token efficient** - Optimized search result formatting significantly reduces token usage
            - Upgraded MCP backend to better support coding agents that do MCP tool search
            - Improved search result formatting with hierarchical file tree view for easier navigation
            - Better handling of workspaces with multiple git repositories
            - Performance improvements for file sorting operations

            ### Fixes
            - Fixed git tool support when used in a worktree
            - Fixed context builder settings getting reset after app restart
            """
        ),
        Version(
            id: "1.6.0",
            buildNumber: 254,
            date: ISO8601DateFormatter().date(from: "2026-01-20T00:00:00Z") ?? Date(),
            changes: """
            ## [1.6.0] - 2026-01-20

            ### Deep Code Reviews
            This release introduces powerful code review capabilities powered by a new unified git tool:
            - **Context Builder Review Mode** - New response type for deep code reviews that analyzes your code with full codebase context
            - **New Slash Commands** - `rp-review` for comprehensive code reviews and `rp-refactor` for finding refactoring opportunities
            - **Unified Git Tool** - New MCP tool for git operations (status, diff, log, show, blame) with token-efficient output and built-in safety features
            - **Git Diff Artifact Publishing** - Generate and publish git diff snapshots directly from the UI for sharing with AI agents

            ### Improvements
            - Streamlined Context Builder UI
            - Improved CLI tab awareness and streamlined help documentation
            - CLI now requires JSON format for `apply_edits` and `file_actions` for better escape handling with multiline content
            - Performance optimizations for file sorting operations
            """
        ),
        Version(
            id: "1.5.68",
            buildNumber: 253,
            date: ISO8601DateFormatter().date(from: "2026-01-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.68] - 2026-01-16

            ### New Features
            - **OpenCode CLI installer** - Install MCP server configuration for OpenCode CLI from settings
            - **claude-rp CLI wrapper** - An alias for running Claude Code with RepoPrompt's MCP tools, disabling clashing built-in tools
            - **MCP Tools settings** - New settings tab to toggle individual MCP tools per-window with search (Pro)
            - **Window management for MCP/CLI** - MCP and CLI can now automatically open and close windows when creating, switching, or deleting workspaces

            ### Improvements
            - Cleaned up MCP settings UI
            - Smarter CLI command management - respects user-removed commands and won't re-add them on updates
            - MCP question UI - questions asked during MCP operations now appear and work consistently

            ### Fixes
            - Fixed terminal crash during long terminal sessions
            """
        ),
        Version(
            id: "1.5.67",
            buildNumber: 251,
            date: ISO8601DateFormatter().date(from: "2026-01-13T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.67] - 2026-01-13

            ### Fixes
            - Fixed issue with Gemini CLI's stream getting cutoff mid-response
            - Fixed issue with OpenAI API where heartbeats were causing decode errors
            """
        ),
        Version(
            id: "1.5.66",
            buildNumber: 250,
            date: ISO8601DateFormatter().date(from: "2026-01-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.66] - 2026-01-12

            ### New Features
            - **Built-in Interview Prompt** - New interview prompt for Context Builder to guide implementation planning
            - **Pinnable Context Builder Prompts** - Pin your favorite prompts for quick access (shown first in the list)
            - **Collapsible Instructions Panel** - Collapse the instructions panel for a cleaner prompt view

            ### Improvements
            - Improved MCP and CLI tool schemas
            - Improved CLI documentation and help output
            - More flexible CLI invocation with support for various argument formats
            - Enhanced Context Builder Agent tool descriptions for better structure in agent/planner workflows
            - Improved Context Builder Agent prompt for smarter file selection
            - Better terminal stability with smoother resizing and scroll restoration

            ### Fixes
            - Fixed long-running MCP tool calls disconnecting prematurely
            - Fixed terminal keyUp recursion crash
            - Fixed chat sessions overwriting compose tab prompt IDs
            - Fixed workspace refresh issues with stale indices
            """
        ),
        Version(
            id: "1.5.65",
            buildNumber: 249,
            date: ISO8601DateFormatter().date(from: "2026-01-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.65] - 2026-01-08

            ### Fixes
            - Fixed tabs getting wiped on update
            """
        ),
        Version(
            id: "1.5.64",
            buildNumber: 248,
            date: ISO8601DateFormatter().date(from: "2026-01-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.64] - 2026-01-08

            ### New Features
            - **Customizable Context Builder Prompts** - Create and save custom prompts for the context builder to tailor how context is discovered for different tasks
            - **Remote Git Branches** - View and select remote branches alongside local ones; remote refs are now auto-fetched to stay current

            ### Improvements
            - **CLI Enhancements** - New --json flag for scripting, better flag parsing, and cleaner command syntax for the builder command
            - New compose tabs now preserve your current file tree expansion instead of collapsing everything

            ### Fixes
            - Fixed issue with context builder state getting wiped on tab switches
            - Fixed git diff not being included when it was supposed to
            - Fixed issue with model presets getting wiped
            """
        ),
        Version(
            id: "1.5.63",
            buildNumber: 247,
            date: ISO8601DateFormatter().date(from: "2026-01-07T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.63] - 2026-01-07

            ### Improvements
            - Code review mode now available via MCP tools
            - Changed default chat_send mode to "chat" for safer initial MCP interactions

            ### Fixes
            - Fixed tools timing out after 15 minutes, preventing long context builder runs
            - Fixed workspace tooling not working reliably from the CLI
            - Fixed folder picker sometimes blocking the app
            - Improved performance when expanding large workspaces
            """
        ),
        Version(
            id: "1.5.62",
            buildNumber: 246,
            date: ISO8601DateFormatter().date(from: "2026-01-05T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.62] - 2026-01-05

            ### CLI Improvements
            - **Tab targeting** - Target specific compose tabs via CLI flags for precise multi-window control
            - **Copy preset management** - List and select copy presets directly from CLI and MCP
            - **Progress notifications** - Shows progress updates during lengthy tasks to prevent timeouts
            - **Better multi-window guidance** - Help output includes contextual routing tips when multiple windows are detected

            ### App Improvements
            - **Shift+Command+W shortcut** - Close the active window quickly
            - **Improved tab cleanup** - Running tasks are properly stopped when tabs are closed, preventing resource leaks
            """
        ),
        Version(
            id: "1.5.61",
            buildNumber: 243,
            date: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.61] - 2026-01-01

            ### New Features
            - **Background Mode** - App stays active when you close windows, with a menu bar icon for quick restore or quit
            - **Chat UX Revamp** - Chats are now bound to tabs for easier session management, with support for multiple concurrent streaming conversations
            - **Prompt Export Tool** - New MCP tool to export complete clipboard content to a file (`prompt export <path>`)
            - **Oracle Export Command** - New `rp-oracle-export` prompt to run context builder and export for use with external oracle tooling
            - **File Actions** - Open files in default apps, copy absolute paths, and reveal in Finder from file tree and selected files

            ### Fixes
            - Improved cache cleanup to remove stale code maps for deleted folders
            """
        ),
        Version(
            id: "1.5.60",
            buildNumber: 242,
            date: ISO8601DateFormatter().date(from: "2025-12-22T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.60] - 2025-12-22

            ### New Features
            - **CLI command installation** - Added rp-investigate and rp-build CLI commands for easier use in Codex and Claude Code environments
            - **Per-tab auto-plan setting** - Auto-generate plan now works per-tab with workspace fallback for finer control

            ### CLI Improvements
            - **Raw JSON output mode** - New --raw-json flag returns pure JSON responses for easier scripting and automation
            - **Output redirection** - Commands now support shell-like > (overwrite) and >> (append) redirection to files
            - **Enhanced command parsing** - Extended flags and options across search, selection, file operations, and chat commands
            - **Smarter path resolution** - Improved handling of folder paths, workspace-relative paths, and root aliases across commands

            ### Improvements
            - **Better codemap management** - Files without codemap support are now properly filtered and reported instead of causing errors
            - **Improved custom text input UI** - Styled as a selectable option with visual feedback for better consistency

            ### Fixes
            - Fixed codemap demotion incorrectly removing files that don't support codemaps
            - Fixed path resolution edge cases in multi-root workspaces
            """
        ),
        Version(
            id: "1.5.59",
            buildNumber: 241,
            date: ISO8601DateFormatter().date(from: "2025-12-19T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.59] - 2025-12-19

            ### Fixes
            - **Fixed truncation of tool descriptions and workspace names** - Some content was incorrectly being cut off in command output and UI prompts
            - **Improved app quit stability** - Fixed potential crashes when quitting the app by preventing duplicate termination attempts
            - Cleaner CLI error messages
            """
        ),
        Version(
            id: "1.5.58",
            buildNumber: 240,
            date: ISO8601DateFormatter().date(from: "2025-12-19T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.58] - 2025-12-19

            ### Improvements
            - **Improved chat bubble performance** - Optimized text layout to reduce unnecessary UI updates and improve scrolling smoothness
            - **Updated MCP Builder workflow** - Consolidated and improved guidance for context building and implementation workflows

            ### Fixes
            - Fixed inconsistent CLI naming in help menu
            """
        ),
        Version(
            id: "1.5.57",
            buildNumber: 239,
            date: ISO8601DateFormatter().date(from: "2025-12-18T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.57] - 2025-12-18

            ### Major New Feature
            - **Interactive CLI** - New command-line interface for exploring and executing MCP tools directly from terminal. Includes shell-like aliases (ls, cd, cat), command history, output redirection, timing info, typo suggestions, tool group filtering, and exec mode for scripting. Easy one-click PATH installation from Settings.

            ### New Features
            - **MCP Slash Commands** - Key prompts (rp-build, rp-investigate) now automatically exposed to any connected MCP client as slash commands
            - **Path Paste Menu** - Quickly select files from a blob of text containing paths, available in More Actions
            - **OpenAI Service Tier** - New setting for OpenAI Responses API service tier

            ### Improvements
            - Improved tooltip positioning on hover and scroll
            - Enhanced window/tab routing for workspace tools
            - Auto-apply recommendations for new workspaces

            ### Fixes
            - Fixed infinite layout loop crashes in search file tree
            - Fixed recommendation invalidation issues
            - Improved MCP socket connection stability and handling
            - Misc UI fixes
            """
        ),
        Version(
            id: "1.5.56",
            buildNumber: 238,
            date: ISO8601DateFormatter().date(from: "2025-12-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.56] - 2025-12-11

            ### Improvements
            - Improved GPT-5.2 Pro support - Added background job support for Azure OpenAI and OpenAI providers, enabling stable use of GPT-5.2 Pro and other models that require asynchronous processing
            - Improved text editor stability - Fixed TextKit issues that could cause crashes or visual glitches during editing
            - Improved app stability - Various fixes to prevent crashes and improve reliability

            ### Fixes
            - Fixed high CPU usage - Resolved performance issue where the Context Builder Agent view could cause high CPU usage during extended runs
            """
        ),
        Version(
            id: "1.5.55",
            buildNumber: 237,
            date: ISO8601DateFormatter().date(from: "2025-12-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.55] - 2025-12-11

            ### New Features
            - Added GPT-5.2 support with XHigh reasoning variants

            ### Improvements
            - Context builder now shows your actual codemap preset settings alongside its normalized view
            - Background plan generation now runs independently per tab, enabling concurrent plans
            - Improved socket connection stability with better race condition handling

            ### Fixes
            - Fixed context builder and manage_selection tools not properly providing feedback when using codemap modes other than "auto"
            """
        ),
        Version(
            id: "1.5.54",
            buildNumber: 236,
            date: ISO8601DateFormatter().date(from: "2025-12-10T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.54] - 2025-12-10

            ### New Features
            - Added Claude Code slash commands with one-click installation from settings
            - New "MCP Builder" preset with four-phase workflow: quick scan, context building, chat refinement, and implementation
            - Context Builder agent can now ask clarifying questions during context building (optional setting)

            ### Improvements
            - Gemini CLI integration now uses persistent settings file for better reliability
            - Auto-focus window and switch to compose tab when clarifying questions are pending
            - Improved UI layout for Context Builder agent toggles

            ### Fixes
            - Fixed context bleed between tabs during discovery runs
            - Fixed text field scrolling issues on Intel Macs
            - Fixed potential MCP socket connection errors on systems with restrictive firewalls
            """
        ),
        Version(
            id: "1.5.53",
            buildNumber: 235,
            date: ISO8601DateFormatter().date(from: "2025-12-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.53] - 2025-12-08

            ### Improvements
            - Overhauled MCP transport architecture - replaced all local network communication with high-performance UNIX sockets, significantly reducing CPU overhead and improving connection stability
            - Removed network permission requirements - the app no longer needs Local Network access, eliminating authorization popups when connecting to MCP servers
            - Improved CLI provider initialization - changed where CLI providers are initialized to avoid unnecessary access popups for Apple Music and Documents folders
            - More reliable MCP connections - added robust reconnect logic with client identity caching, ensuring consistent connections during session recovery
            """
        ),
        Version(
            id: "1.5.52",
            buildNumber: 234,
            date: ISO8601DateFormatter().date(from: "2025-12-07T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.52] - 2025-12-07

            ### Fixes
            - Temporarily disabled filesystem transport due to CPU overhead - reworking the solution
            - Fixed tab related race conditions causing issues with MCP powered context building
            - Fixed context builder text state issues
            - Better handling of discovery runs where the agent doesn't leave a handoff prompt

            ### Improvements
            - Minor UI improvements
            """
        ),
        Version(
            id: "1.5.51",
            buildNumber: 233,
            date: ISO8601DateFormatter().date(from: "2025-12-06T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.51] - 2025-12-06

            ### Fixes
            - Fixed tab state not working correctly for context builder view
            """
        ),
        Version(
            id: "1.5.50",
            buildNumber: 232,
            date: ISO8601DateFormatter().date(from: "2025-12-06T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.50] - 2025-12-06

            ### New Features
            - Added reasoning/thinking display for plan generation - see the model's thought process in a collapsible section
            - Plan preset locking ensures consistent settings during context builder operations

            ### Improvements
            - Better cancellation support for async operations - more responsive UI when stopping queries
            - Improved streaming with proper cleanup to prevent hangs
            - Enhanced tab busy state indicators for plan generation
            - Better text sync behavior on tab changes

            ### Fixes
            - Fixed potential resource leaks during streaming cancellation
            - Fixed file deletion detection
            """
        ),
        Version(
            id: "1.5.49",
            buildNumber: 231,
            date: ISO8601DateFormatter().date(from: "2025-12-06T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.49] - 2025-12-06 (unreleased)

            ### New Features
            - Added reasoning/thinking display for plan generation - see the model's thought process in a collapsible section
            - Plan preset locking ensures consistent settings during context builder operations

            ### Improvements
            - Better cancellation support for async operations - more responsive UI when stopping queries
            - Improved streaming with proper cleanup to prevent hangs
            - Enhanced tab busy state indicators for plan generation
            - Better text sync behavior on tab changes

            ### Fixes
            - Fixed potential resource leaks during streaming cancellation
            """
        ),
        Version(
            id: "1.5.48",
            buildNumber: 211,
            date: ISO8601DateFormatter().date(from: "2025-12-05T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.48] - 2025-12-05

            ### Improvements
            - Further improved CPU utilization - found high churn areas that appeared after many hours of uptime
            - Improved UI for active discovery tabs

            ### Fixes
            - Fixed regressions in MCP connection stability
            """
        ),
        Version(
            id: "1.5.47",
            buildNumber: 210,
            date: ISO8601DateFormatter().date(from: "2025-12-05T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.47] - 2025-12-05

            ### Improvements
            - Reworked some file tree logic to optimize UI churn for extremely large repos
            - Reworked MCP lifecycle management to better handle closing connections and CPU usage
            - More fixes to parallel MCP-based plan/discovery queries
            """
        ),
        Version(
            id: "1.5.46",
            buildNumber: 209,
            date: ISO8601DateFormatter().date(from: "2025-12-03T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.46] - 2025-12-03

            ### New Models
            - Replaced Codex models from OpenAI with Codex-max

            ### Improvements
            - Optimized file-watcher logic so that it's a lot less CPU hungry

            ### Fixes
            - Polished recommendation wizard + small UI fixes
            - Fixed issues with parallel context builder plan generation
            - Fixed non-working GPT-5 mini models
            """
        ),
        Version(
            id: "1.5.45",
            buildNumber: 208,
            date: ISO8601DateFormatter().date(from: "2025-12-03T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.45] - 2025-12-03

            ### New Features
            - Context builder can now automatically generate a plan after completing its exploration
            - Improved MCP context builder tool to add followup chaining for questions or plans
            - Added Recommendation engine for auto model selection based on current configuration

            ### Improvements
            - file_search uses improved regex engine for better performance in large repos
            - Many CPU usage optimizations across the app
            - Git polling is disabled if set to none
            - Raised codex CLI chat response verbosity

            ### Fixes
            - Fixed MCP tool routing by using direct window_id and tab_id params to tools
            - Improved performance of Context Builder agent
            """
        ),
        Version(
            id: "1.5.44",
            buildNumber: 207,
            date: ISO8601DateFormatter().date(from: "2025-11-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.44] - 2025-11-29

            ### Fixes
            - Resolved issues with prompts getting reset on tab switches
            - Fixed UI issue for delegated edit settings
            - Discovery mcp tool now shows cancellation info
            """
        ),
        Version(
            id: "1.5.43",
            buildNumber: 206,
            date: ISO8601DateFormatter().date(from: "2025-11-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.43] - 2025-11-28

            ### Fixes
            - Resolved issue where context builder got stuck on the same tab for each run with the mcp
            - Added ability to add mcp meta data to any copy prompt
            """
        ),
        Version(
            id: "1.5.42",
            buildNumber: 205,
            date: ISO8601DateFormatter().date(from: "2025-11-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.42] - 2025-11-28

            ### Improvements
            - Context builder as an MCP tool!
            - Tab management now possible with MCP tooling
            - workspace tool can now create and edit workspaces with proper permission management

            ### Fixes
            - Numerous performance & stability fixes
            """
        ),
        Version(
            id: "1.5.41",
            buildNumber: 204,
            date: ISO8601DateFormatter().date(from: "2025-11-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.41] - 2025-11-26

            ### Improvements
            - Overhauled MCP connection management to better handle connection rebinding in multi window scenarios on app restart
            - Added new MCP connection status and management UI
            - Added ability to stash tabs, and raised tab limit to 25
            - Claude code as Context Builder agent now prints reasoning as it works

            ### Fixes
            - Optimized some performance issues with the new file system based mcp transport
            """
        ),
        Version(
            id: "1.5.40",
            buildNumber: 203,
            date: ISO8601DateFormatter().date(from: "2025-11-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.40] - 2025-11-24

            ### Improvements
            - Added support for Opus 4.5 across the app and different providers
            - Introduced zero-network MCP mode, that uses a filesystem based transport layer to work better in corporate networks & under strict firewalls. Will automatically be used if network mode is unavailable as a fallback. Can be enforced in the MCP server settings
            - Improved error messaging for MCP issues

            ### Fixes
            - Fixed issue where Sonnet 4.5 would be set as the chat model in cases where it shouldn't
            """
        ),
        Version(
            id: "1.5.39",
            buildNumber: 202,
            date: ISO8601DateFormatter().date(from: "2025-11-19T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.39] - 2025-11-19

            ### Improvements
            - Improved Codex CLI support to add max models + auto MCP truncation config
            - Improved Gemini CLI error handling
            - Workspaces now auto re-open on app reboot
            - Improved latency of tab switching
            - Re-added XML Edit Whole support via the Prompts button

            ### Fixes
            - Small fix related to manual preset restoring
            """
        ),
        Version(
            id: "1.5.38",
            buildNumber: 201,
            date: ISO8601DateFormatter().date(from: "2025-11-18T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.38] - 2025-11-18

            ### Fixes
            - Fixes to gemini cli tool handling and 404 errors
            - Fixes to file_search hangs with intense regex patterns
            - Improved tool cancellation handling
            - Fixed bug where presets manager would open in all windows
            """
        ),
        Version(
            id: "1.5.37",
            buildNumber: 200,
            date: ISO8601DateFormatter().date(from: "2025-11-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.37] - 2025-11-17

            ### Improvements
            - Added support for Gemini CLI for chat, discovery & delegate edits
            - Improved agentic delegate edit behavior
            - Misc stability improvements
            """
        ),
        Version(
            id: "1.5.36",
            buildNumber: 199,
            date: ISO8601DateFormatter().date(from: "2025-11-14T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.36] - 2025-11-14

            ### Improvements
            - Improved codex auto config and self-healing
            """
        ),
        Version(
            id: "1.5.35",
            buildNumber: 198,
            date: ISO8601DateFormatter().date(from: "2025-11-14T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.35] - 2025-11-14

            ### Fixes
            - Fixed support for newer codex versions that changed how streams are encoded for CLI provider
            - Fixed Claude Code test connection failure, and properly disable MCP servers when using it as a provider
            - Fixed bug causing folder expansion to improperly persist on workspace reloads in large folders
            - Misc perf improvements
            """
        ),
        Version(
            id: "1.5.34",
            buildNumber: 197,
            date: ISO8601DateFormatter().date(from: "2025-11-13T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.34] - 2025-11-13

            ### Improvements
            - Chat can now edit user messages to fork chats
            - All GPT-5 Models are now 5.1
            - Improved apply_edits MCP tool to account for GPT-5 malformed scenarios
            - Improved file search behavior in multi-root scenarios
            - Improved error messaging with delegated edits when no changes are made
            - Improved MCP Pair prompt
            - Default tab for pro users is Context Builder
            - Raised Codex CLI timeouts
            """
        ),
        Version(
            id: "1.5.33",
            buildNumber: 196,
            date: ISO8601DateFormatter().date(from: "2025-11-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.33] - 2025-11-12

            ### Codex CLI improvements
            - Improved codex MCP server management logic leading to errors in using the CLI
            - Improved codex connection error reporting

            ### Fixes
            - Improved tab context management for normal MCP use. Resolved 'zombie' state that left tools unresponsive in some cases
            - Improved file system watching management, addressing issues for users making massive file system churn and improving performance
            - Fix for Repo Bench CSV exporting incorrect temp
            """
        ),
        Version(
            id: "1.5.32",
            buildNumber: 195,
            date: ISO8601DateFormatter().date(from: "2025-11-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.32] - 2025-11-11

            ### Improvements
            - Improved file system loading to optimize memory use
            - Significantly improves memory use when processing file system deltas by the watcher
            - Improved negation ignore pattern support
            """
        ),
        Version(
            id: "1.5.31",
            buildNumber: 194,
            date: ISO8601DateFormatter().date(from: "2025-11-10T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.31] - 2025-11-10

            ### Fixes
            - Fixes to codeblock padding
            - Fixes to claude code parsing issue from dictionary decoding errors
            """
        ),
        Version(
            id: "1.5.30",
            buildNumber: 193,
            date: ISO8601DateFormatter().date(from: "2025-11-10T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.30] - 2025-11-10

            ### Hotfix
            - Resolved issue with clashing between Codex CLI models and Openai Models in the model picker
            """
        ),
        Version(
            id: "1.5.29",
            buildNumber: 192,
            date: ISO8601DateFormatter().date(from: "2025-11-10T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.29] - 2025-11-10

            ### Fixes
            - Fixed some issues with parsing codex toml which led to issues using codex as an api provider
            """
        ),
        Version(
            id: "1.5.28",
            buildNumber: 191,
            date: ISO8601DateFormatter().date(from: "2025-11-10T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.28] - 2025-11-10

            ### New Features
            - Codex CLI as an API provider: Use OpenAI models through your Plus or Pro plan via Codex CLI to make use of chat features, including the pair programming flow

            ### Improvements
            - Improved CLI path parsing to better handle fallback for users with complex aliasing options configured

            ### Fixes
            - Numerous perf and stability improvements
            """
        ),
        Version(
            id: "1.5.27",
            buildNumber: 190,
            date: ISO8601DateFormatter().date(from: "2025-11-09T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.27] - 2025-11-09

            ### Fixes
            - Stabilized potential instability related to popovers losing state and causing a full app crash (related macOS 26 swiftui changes)
            """
        ),
        Version(
            id: "1.5.26",
            buildNumber: 189,
            date: ISO8601DateFormatter().date(from: "2025-11-09T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.26] - 2025-11-09

            ### Improvements
            - Overhauled shell path discovery for claude and codex to more reliably find installations
            """
        ),
        Version(
            id: "1.5.25",
            buildNumber: 188,
            date: ISO8601DateFormatter().date(from: "2025-11-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.25] - 2025-11-08

            ### Fixes
            - Fixed some issues where path resolution was more strict than older versions for claude code and codex
            - Fixed some issues around error reporting for claude code and codex agent runners
            """
        ),
        Version(
            id: "1.5.24",
            buildNumber: 187,
            date: ISO8601DateFormatter().date(from: "2025-11-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.24] - 2025-11-08

            ### Fixes
            - Fixed several inefficiences causing potential hangs
            - Fixed layout thrashing of git pannel causing it to be unusable until a re-open
            - Fixed light theme inconsistencies in chat view
            """
        ),
        Version(
            id: "1.5.23",
            buildNumber: 186,
            date: ISO8601DateFormatter().date(from: "2025-11-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.23] - 2025-11-08

            ### Improvements
            - Added support for codex-mini to the Context Builder agent & delegated edit agents workflows

            ### Fixes
            - Hotfix for inconsistency introduced in discovery prompt
            """
        ),
        Version(
            id: "1.5.22",
            buildNumber: 185,
            date: ISO8601DateFormatter().date(from: "2025-11-07T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.22] - 2025-11-07

            ### Improvements
            - Optimized IPC allocation for headless agents to reduce overall memory usage during discovery and delegate edit agent runs
            - Streamlined multi window mode for MCP
            - Reworked chat ui to provide native markdown rendering
            - Improved fonts throughout the app
            - Improved behavior and stability of mention menu ui
            """
        ),
        Version(
            id: "1.5.21",
            buildNumber: 184,
            date: ISO8601DateFormatter().date(from: "2025-11-04T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.21] - 2025-11-04

            ### Context builder improvements
            - Files slices are no longer stored in your repo, and will auto migrate to Application Support
            - File previews with slices now render better

            ### UI Improvements
            - Fixed tab reflow math that caused some buttons to be hidden at times
            - Tabs now show full name on hover
            - Selected files list has been optimized to prevent a hang when doing mass selections/deselections
            - Files list in chat view now renders more clearly to better track what files are in your prompts

            ### Provider Improvements
            - Fireworks provider cleanup, refreshed models list
            - Anthropic & claude code now support haiku 4.5 -> removed deprecated Sonnet 3.5
            - Custom provider now supports endpoints with V4 or other numerical versions that previously caused errors
            """
        ),
        Version(
            id: "1.5.20",
            buildNumber: 183,
            date: ISO8601DateFormatter().date(from: "2025-11-02T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.20] - 2025-11-02

            ### Improvements
            - Improved manage_selection tool to better handle file slicing
            - Optimized discovery prompt to better fill token budget
            """
        ),
        Version(
            id: "1.5.19",
            buildNumber: 182,
            date: ISO8601DateFormatter().date(from: "2025-10-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.19] - 2025-10-31

            ### Fixes
            - Fixed some token counting issues with certain prompt modes
            - Fixed issue with over refreshing search/ file tree
            - Misc stability improvements
            """
        ),
        Version(
            id: "1.5.18",
            buildNumber: 181,
            date: ISO8601DateFormatter().date(from: "2025-10-30T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.18] - 2025-10-30

            ### Hotfix
            - Resolved issue where delegate edit agents would not run in parallel
            """
        ),
        Version(
            id: "1.5.17",
            buildNumber: 180,
            date: ISO8601DateFormatter().date(from: "2025-10-30T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.17] - 2025-10-30

            ### Fixes
            - Fixed some bugs related to manual preset state preservation
            - Fixed some issues with codemap settings not reflecting correctly in the ui
            - Fixed some connectivity issues around delegated edit agent mode
            - Fixed some state sync issues around file selection after using the chat_send mcp tool
            """
        ),
        Version(
            id: "1.5.16",
            buildNumber: 179,
            date: ISO8601DateFormatter().date(from: "2025-10-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.16] - 2025-10-29

            ### Fixes
            - Fixed path splitting issue with path resolution for codex and claude code
            - Improved delegate edit prompt
            """
        ),
        Version(
            id: "1.5.15",
            buildNumber: 178,
            date: ISO8601DateFormatter().date(from: "2025-10-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.15] - 2025-10-29

            ### New Features
            - Delegated Edit Agent mode: Use Claude Code or Codex with MCP tools to generate edits in paralllel with higher accuarcy, within a sandbox

            ### Improvements
            - Improved token accounting metrics context builder to more precisely hit targets

            ### Fixes
            - Fixed some regressions in CLI path resolution
            """
        ),
        Version(
            id: "1.5.14",
            buildNumber: 177,
            date: ISO8601DateFormatter().date(from: "2025-10-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.14] - 2025-10-28

            ### Improvements
            - Refined claude and codex path resolution to better handle aliases with custom args added
            - Codex now uses a streamlined discovery prompt to make it more efficient vs Claude Code

            ### Fixes
            - Resolved some inaccurate token presentation issues when using context builder
            - Fixes to delegated edits sometimes firing multiple identical queries
            - Improved mcp stability with chat_send tool
            """
        ),
        Version(
            id: "1.5.13",
            buildNumber: 176,
            date: ISO8601DateFormatter().date(from: "2025-10-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.13] - 2025-10-26

            ### Fixes
            - Fixed regressions in connection stability from the tabs update, leading to issues with general mcp use in multi window workflows
            - Fixed token counting regression, where settings changes dont update the counts
            - Fixed issue causing some shell path resolutions to fail
            """
        ),
        Version(
            id: "1.5.12",
            buildNumber: 175,
            date: ISO8601DateFormatter().date(from: "2025-10-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.12] - 2025-10-26

            ### Fixes
            - Resolved issue with multi-window routing with Context Builder agent
            - Reinforced tab connection stability for long running claude code agents
            """
        ),
        Version(
            id: "1.5.11",
            buildNumber: 174,
            date: ISO8601DateFormatter().date(from: "2025-10-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.11] - 2025-10-26

            ### Improvements
            - Reworked connection management for Codex with Context builder to make tool calls track much more reliably

            ### Fixes
            - Fixed issues with MCP server / multi window controls
            """
        ),
        Version(
            id: "1.5.10",
            buildNumber: 173,
            date: ISO8601DateFormatter().date(from: "2025-10-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.10] - 2025-10-25

            ### Fixes
            - Reworked connection book-keeping logic so that tabs and multi window workflows work a lot more reliably when running parallel discover operations
            """
        ),
        Version(
            id: "1.5.9",
            buildNumber: 172,
            date: ISO8601DateFormatter().date(from: "2025-10-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.9] - 2025-10-25

            ### Fixes
            - Further improvements to window and tab isolation to ensure no cross discovery contamination
            """
        ),
        Version(
            id: "1.5.8",
            buildNumber: 171,
            date: ISO8601DateFormatter().date(from: "2025-10-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.8] - 2025-10-25

            ### Fixes
            - Fixed issue with running discovery on multiple windows
            - Fixed ui issue where the view would reset on agent operations
            """
        ),
        Version(
            id: "1.5.7",
            buildNumber: 170,
            date: ISO8601DateFormatter().date(from: "2025-10-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.7] - 2025-10-25

            ### Fixes
            - Fixed incorrect token reporting and operations with context builder in parallel tabs
            - Fixed issue where keyboard shortcuts incorrectly consume inputs when the app is not focused
            - Fixed issue where tabs cannot have independent settings for context builder
            """
        ),
        Version(
            id: "1.5.6",
            buildNumber: 169,
            date: ISO8601DateFormatter().date(from: "2025-10-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.6] - 2025-10-24

            ### Fixes
            - Improved prompt around token budgetting for context builder
            - Raised claude code execution timeout
            """
        ),
        Version(
            id: "1.5.5",
            buildNumber: 168,
            date: ISO8601DateFormatter().date(from: "2025-10-21T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.5] - 2025-10-21

            ### Major Update: Compose Tabs!
            - Working multiple tasks in parallel, and setup multiple prompts and file selections at the same time
            - Spin up multiple discover tasks in parallel

            ### Context Builder Improvements
            - Enhanced prompts to be less opinionated
            - Added ability to change how prompt enhancement works, choosing between Replace, Augment, or Preserve
            - Desktop notification when context builder completes

            ### Performance Improvements
            - Enhanced performance of file selection view to better handle large selection sets

            ### Bug Fixes
            - Many improvements around file selection handling, with codemaps in particular
            """
        ),
        Version(
            id: "1.5.4",
            buildNumber: 167,
            date: ISO8601DateFormatter().date(from: "2025-10-20T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.4] - 2025-10-20

            ### Hotfix
            - Resolved issue where MCP is failing to properly manage auto codemaps
            """
        ),
        Version(
            id: "1.5.3",
            buildNumber: 166,
            date: ISO8601DateFormatter().date(from: "2025-10-20T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.3] - 2025-10-20

            ### Context Builder 2.0
            - Much better path resolution for codex + claude code
            - Better tool limiting for Context Builder agent, to ensure they cannot create files and do other things they shouldn't
            - Improved Codex handling when you have multiple mcp servers installed

            ### General Improvements
            - Better handling of paths with characters like parentheses
            - Manual mode now has sticky state so your state doesn't reset when switching to other presets and back
            - UI improvements and fixes around codemaps and selected files
            - Light mode fixes
            """
        ),
        Version(
            id: "1.5.2",
            buildNumber: 165,
            date: ISO8601DateFormatter().date(from: "2025-10-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.2] - 2025-10-17

            ### Context builder improvements
            - Context Builder agent can no longer call apply_edits or chat_send, and it's window is auto assigned
            - Reworked process spawning and destruction, addressing multi-run issues

            ### Azure Provider
            - Overhauled azure provider, with auto model detection and responses api support

            ### Fixes
            - CLI agent path resolution improved
            """
        ),
        Version(
            id: "1.5.1",
            buildNumber: 164,
            date: ISO8601DateFormatter().date(from: "2025-10-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5.1] - 2025-10-17

            ### Fixes
            - Fixed issue where stored prompts may get erased
            - Fixed timing validation for MCP tool setup with Codex
            - Raised timeout time for Context Builder agent
            """
        ),
        Version(
            id: "1.5",
            buildNumber: 163,
            date: ISO8601DateFormatter().date(from: "2025-10-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.5] - 2025-10-16

            ### Context Builder 2.0
            - Brand new agentic context builder that leverages either Claude Code or Codex, using your existing installation and subscription, to automate connecting Repo Prompt's MCP tools to a headless agent to act as a context scout, to select the right files, codemaps, and file slices, as well as write an optimized prompt, all fitting within a prescribed token budget
            - You can now granularly control files and codemaps, to tune in your prompt to the right size, which is especially useful for GPT-5 Pro's limited 60k token window

            ### Preset changes
            - Presets now have much more visibility, and it is now much easier to start from a preset and change just one thing to tune in your prompt to the right settings

            ### MCP Improvements
            - Overhauled file search tool to be much more token efficient and provide far better visibility to models trying to grasp surrounding context
            - Overhauled manage_selection tool to provide greater visibility into the overall prompt, and much finer grained control over how files are represented in the prompt

            ### Fixes
            - Stability improvements
            - Reduced memory allocations with MCP use
            """
        ),
        Version(
            id: "1.4.27",
            buildNumber: 162,
            date: ISO8601DateFormatter().date(from: "2025-10-07T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.27] - 2025-10-07

            ### Updates
            - Added support for GPT-5 Pro

            ### Fixes
            - Fixed hang with benchmark view
            - Misc perf improvements
            """
        ),
        Version(
            id: "1.4.26",
            buildNumber: 161,
            date: ISO8601DateFormatter().date(from: "2025-09-30T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.26] - 2025-09-30

            ### Benchmark Improvement

            ### Model Updates
            - Added GLM 4.6 alongside 4.5 from zAI
            """
        ),
        Version(
            id: "1.4.25",
            buildNumber: 160,
            date: ISO8601DateFormatter().date(from: "2025-09-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.25] - 2025-09-29

            ### New Features
            - Benchmark! Head to the settings to run the Repo Prompt benchmark on any model to see how it handles some of the most complex large context and file editing constraints that Repo Prompt can throw at a model.

            ### Improvements
            - Apply edit tool can now more precisely handle edits that involve correcting indentation

            ### Fixes
            - Fixed crash that occured during certain interactions
            """
        ),
        Version(
            id: "1.4.24",
            buildNumber: 159,
            date: ISO8601DateFormatter().date(from: "2025-09-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.24] - 2025-09-28

            ### Hotfix
            - Revert file system change that may lead to files not being found

            ### Improvements
            - Reject edit tool calls that stem from codex incorrectly including its chain of thought in the replacement field
            - Improve error messaging for claude code provider
            """
        ),
        Version(
            id: "1.4.23",
            buildNumber: 158,
            date: ISO8601DateFormatter().date(from: "2025-09-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.23] - 2025-09-27

            ### Hotfix
            - Fixed high cpu usage during idle. This was a bug in the file tree view doing too many calcs every frame

            ### Improvements
            - Improved Claude code sdk detection and added optional log dump on failed connections
            - MCP Connection approval dialogue is now marked as always allow by default to avoid repeated connection popups
            """
        ),
        Version(
            id: "1.4.22",
            buildNumber: 157,
            date: ISO8601DateFormatter().date(from: "2025-09-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.22] - 2025-09-25

            ### Improvements
            - Can now reset built in prompts with simple ui button
            - Saving a file preset when none are selected now creates a new preset

            ### Fixes
            - Further imporved performance of the mcp server settings view
            - Improved path detection for claude code
            - Fixed chat preset ui mismatch
            - Fixed broken folder collapse all button
            """
        ),
        Version(
            id: "1.4.21",
            buildNumber: 156,
            date: ISO8601DateFormatter().date(from: "2025-09-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.21] - 2025-09-24

            ### Improvements
            - Auto configure codex toml file so that repo prompt server tool calls have a longer timeout than the default 60s
            - Improved MCP prompts to be more efficient on tool usage
            - Optimized initial folder loading and reduced memory usage
            - MCP file creation now requires absolute path in multi root scenarios to avoid incorrect folder creation

            ### Fixes
            - Fixed hang when scrolling mcp server settings menu
            - Fixed hang when recursively expanding very large directories
            - Fixed issue where manual config with file tree and codemaps was getting reset on every boot
            - Fixed issue where chat would sometimes cancel the stream prematurely
            - Optimized file edit finalization in chat to prevent hangs
            """
        ),
        Version(
            id: "1.4.20",
            buildNumber: 155,
            date: ISO8601DateFormatter().date(from: "2025-09-22T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.20] - 2025-09-22

            ### Improvements
            - MCP presets now include a guide for the model to select the correct window before making any tool calls when multi window mode is active
            - Claude Code detection now should auto detect setup aliases without manually checking known locations. Should be resilient to any config as long as your terminal properly has claude code setup

            ### Fixes
            - Resolved crash that may occur during chat preset selection
            - Resolved issue where chat sometimes never finalizes
            - Misc stability fixes
            """
        ),
        Version(
            id: "1.4.19",
            buildNumber: 154,
            date: ISO8601DateFormatter().date(from: "2025-09-19T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.19] - 2025-09-19

            ### Improvements
            - Added z.AI provider
            - Made claude code detection more robust, and resilient to the new global install migration

            ### Fixes
            - Fixed 2 potential crash sources
            - Prevent OS from throttling network connections in app while server is active

            ### News
            - Weekend sale of the app: 26% lifetime or yearly (Sept 19-22) to celebrate macOS26! If you're an existing customer and would like to upgrade, please reach out to contact@repoprompt.com to get a special pro-rata discount
            """
        ),
        Version(
            id: "1.4.18",
            buildNumber: 153,
            date: ISO8601DateFormatter().date(from: "2025-09-18T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.18] - 2025-09-18

            ### Fixes
            - Resolved numerous UI glitches that resulted from the switch to macOS Tahoe's SwiftUI layout behavior changes
            - Improved memory usage when processing thousands of paths for selection / lookup operations
            """
        ),
        Version(
            id: "1.4.17",
            buildNumber: 152,
            date: ISO8601DateFormatter().date(from: "2025-09-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.17] - 2025-09-26

            ### macOS 26 - Tahoe update!

            - Revamped visual design to use more native components

            ### Improvements
            - File loading optimization to better handle large binary files
            - Misc ui fixes
            - Temporarily disabled markdown support in chat while native rewrite is underway
            - Minor perf improvements
            """
        ),
        Version(
            id: "1.4.16",
            buildNumber: 151,
            date: ISO8601DateFormatter().date(from: "2025-09-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.16] - 2025-09-16

            ### Improvements
            - File tree now defaults down to 6k tokens instead of 10k in auto mode and has better degredation that preserves selected files in folder only rendering
            - Apply_edits MCP tool now handles malformed calls and should be more robust with the newest versions of Claude Code and Claude Desktop

            ### Fixes
            - Fixed crash in file higherchy rendering
            - Fixed crash due to preset mismatching
            - Fixed issue causing slow bootup in certain cases
            - Fixed typo in discovery prompt
            """
        ),
        Version(
            id: "1.4.15",
            buildNumber: 150,
            date: ISO8601DateFormatter().date(from: "2025-09-13T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.15] - 2025-09-13

            ### Improvements
            - Reworked parallel context builder behavior to evenely partition the codebase into a set number of parallel tasks (4 by default)
            - Simplified controls at the bottom of the builder

            ### Fixes
            - Fixed issue with files all suggested files getting clear when one is removed
            """
        ),
        Version(
            id: "1.4.14",
            buildNumber: 149,
            date: ISO8601DateFormatter().date(from: "2025-09-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.14] - 2025-09-12

            ### Improvements
            - Optimizations to workspace saving and chat session changing

            ### Fixes
            - Addressed issues with files having underscores or hyphens not getting found
            """
        ),
        Version(
            id: "1.4.13",
            buildNumber: 148,
            date: ISO8601DateFormatter().date(from: "2025-09-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.13] - 2025-09-11

            ### Improvements
            - Tightened MCP Discover prompt to help ensure claude sets the hand off prompt and refrains from handling the implementation without approval

            ### Hotfix
            - Fix for regression that caused certain files not to load with many highly similar paths
            """
        ),
        Version(
            id: "1.4.12",
            buildNumber: 147,
            date: ISO8601DateFormatter().date(from: "2025-09-09T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.12] - 2025-09-09

            ### Improvements
            - Optimized logic around file path processing during heavy use of ASCII chars in deeply nested directories

            ### Fixes
            - Fixes to IME keyboard support in chat view
            - Misc performance & stability improvements
            """
        ),
        Version(
            id: "1.4.11",
            buildNumber: 146,
            date: ISO8601DateFormatter().date(from: "2025-09-08T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.11] - 2025-09-08

            ### Performance Improvements
            - Faster code scanning - Added smart caching that remembers previously scanned files, making code navigation much quicker
            - Improved text processing - Optimized how the app handles and parses text content for better responsiveness
            - Memory optimization - Introduced batching to reduce memory usage during heavy operations

            ### Enhanced Reliability
            - Better file handling - Improved how the app finds and matches files across your projects
            - Smarter path resolution - Enhanced ability to locate files even when using shortcuts or symbolic links
            - Stricter file checks - Added validation to ensure files exist before attempting operations

            ### Improved Accuracy
            - Better XML parsing - Refined how the handles XML based file edits and splits changes with Delegated Edit Mode
            - Enhanced workspace management - Improved synchronization between project folders and workspaces
            - More precise file matching - Better detection of the correct files when multiple similar paths exist

            ### Quality Assurance
            - Comprehensive testing - Added extensive test coverage to ensure reliability
            - Stress testing - Implemented fuzzing tests to handle edge cases and unusual inputs
            - Test consolidation - Reorganized and improved the test suite for better maintainability

            ### User Experience
            - Cleaner text formatting - Improved whitespace handling for better readability
            - Consistent folder ordering - Workspace folders now maintain their order properly
            - Better model selection - Improved logic for choosing the right AI model for your tasks
            """
        ),
        Version(
            id: "1.4.10",
            buildNumber: 145,
            date: ISO8601DateFormatter().date(from: "2025-09-04T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.10] - 2025-09-04

            ### Improvements
            - Optimized text entry in instructions view
            - Optimized UI rendering in chat

            ### Fixes
            - Resolved 2 potential crash sources
            - Fixed issue with Requesty.ai API calls
            - Fixed issue with deeply nested files sometimes not loading correctly
            """
        ),
        Version(
            id: "1.4.9",
            buildNumber: 144,
            date: ISO8601DateFormatter().date(from: "2025-09-03T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.9] - 2025-09-03

            ### Improvements
            - Improved clarity of workspace management menu
            - Added ability to search/filter down workspaces in menu
            - Added easier workspace creation logic

            ### Fixes
            - Fixed regression in text input latency on Intel Macs
            - Fixed some sharp edges introduced around MCP chat send operations with model overrides
            - Added missing Codex CLI install button in settings
            - Fixed Together.AI log prob decoding error
            """
        ),
        Version(
            id: "1.4.8",
            buildNumber: 143,
            date: ISO8601DateFormatter().date(from: "2025-09-15T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.8] - 2025-09

            ### Improvements
            - Better display of modes and models used by MCP chat tool
            - Added 1-click install for Codex CLI
            - Added button to copy file tree

            ### Fixes
            - Fixed some info not getting included with certain MCP tools
            - Fixed file tree preview not updating when switching modes
            """
        ),
        Version(
            id: "1.4.7",
            buildNumber: 142,
            date: ISO8601DateFormatter().date(from: "2025-09-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.7] - 2025-09-01

            ### Fixes
            - Fixed git inclusion in manual mode
            - Fixed path processing via the chat_send tool
            - Fixed regression causing the clear button not to work in instructions view
            """
        ),
        Version(
            id: "1.4.6",
            buildNumber: 141,
            date: ISO8601DateFormatter().date(from: "2025-08-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.6] - 2025-08-29

            ### Improvements
            - Reworked all MCP tool rendering to be much clearer about the outcome of the tool call
            - Streamlined tool definitions, removing redundant definitions
            - Removed request_plan tool, in favor of chat_send mode: plan
            - Optimized MCP prompts to be more effective at driving the desired outcomes
            - Optimized text input, adding better handling for IME keyboards
            """
        ),
        Version(
            id: "1.4.5",
            buildNumber: 140,
            date: ISO8601DateFormatter().date(from: "2025-08-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.5] - 2025-08-29

            ### Improvements
            - Better tool response meta data for model to contextually orient itself

            ### Fixes
            - Fix for crash regression with multiple identically named root folders
            """
        ),
        Version(
            id: "1.4.4",
            buildNumber: 139,
            date: ISO8601DateFormatter().date(from: "2025-08-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.4] - 2025-08-29

            ### Fixes
            - Inconsistent formatting for read file tool
            """
        ),
        Version(
            id: "1.4.3",
            buildNumber: 138,
            date: ISO8601DateFormatter().date(from: "2025-08-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.3] - 2025-08-29

            ### Improvements
            - MCP tool calls now return plain text instead of json, avoiding issues with character escaping that lead to inaccurate changes by models
            - Better error messaging for some tools
            - Better handling of malformed paths that have too many prefix components
            - read_file tool can now read from the bottom of a file
            """
        ),
        Version(
            id: "1.4.2",
            buildNumber: 137,
            date: ISO8601DateFormatter().date(from: "2025-08-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.2] - 2025-08-27

            ### Hotfixes
            - Fix for git tool crash when more than 4k files are edited
            - Fixed crash caused by duplicate prompt entries
            - Fixed for mismatched preset - chat mode when reloading existing option
            """
        ),
        Version(
            id: "1.4.1",
            buildNumber: 136,
            date: ISO8601DateFormatter().date(from: "2025-08-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.1] - 2025-08-27

            ### Improvements
            - File tree auto mode is majorly improved, with better a better laid out tree and much more efficient token use for large repos
            - Misc UI improvements
            - File creation root disambiguation with multiple loaded folders is much improved

            ### Fixes
            - Fixes to selection tool failures
            - More descriptive error messages for MCP tools
            """
        ),
        Version(
            id: "1.4.0",
            buildNumber: 135,
            date: ISO8601DateFormatter().date(from: "2025-08-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.4.0] - 2025-08-25 - "Presets"

            ### Improvements
            - Massively streamlined core copy and chat UX with the introductions of presets
            - Presets allow you to quickly jump to optimized app configurations to get the most out of Repo Prompt's toolset
            - Chat view is streamlined as well, with simpler presentation and easier use

            ### Misc Changes
            - More stable file selection handling
            - More stable MCP connections
            - Fixes to license check failures
            """
        ),
        Version(
            id: "1.3.50",
            buildNumber: 134,
            date: ISO8601DateFormatter().date(from: "2025-08-19T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.50] - 2025-08-19

            ### Improvements
            - Improvements to path glob pattern matching to make them more ergonomic for MCP search tool

            ### Fixes
            - Optimized file selection logic further
            - Improvements and optimizations to prevent hangs with git tool
            - Codemap packaging over MCP now matches normal codemap packaging
            - Fixed preset saving
            """
        ),
        Version(
            id: "1.3.49",
            buildNumber: 133,
            date: ISO8601DateFormatter().date(from: "2025-08-18T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.49] - 2025-08-18

            ### Fixes
            - Fixed regression in file selection behavior causing hangs in large folders
            """
        ),
        Version(
            id: "1.3.48",
            buildNumber: 132,
            date: ISO8601DateFormatter().date(from: "2025-08-18T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.48] - 2025-08-18

            ### Improvements
            - MCP Server can now list and change workspaces in multi-window mode, allowing claude to auto open the right workspace. This is disabled if multi-window mode is disabled to help avoid unintended workspace operations.
            - Error messaging is better now to help inform Claude on why certain actions fail when workspaces aren't loaded correctly

            ### Fixes
            - Fixes to memory leaks with mcp server, further enhancing tool reliability
            - Fix regression to stale file system state when window unfocused
            """
        ),
        Version(
            id: "1.3.47",
            buildNumber: 131,
            date: ISO8601DateFormatter().date(from: "2025-08-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.47] - 2025-08-17

            ### Improvements
            - Changed MCP search tool to default to regex matching
            - Changed MCP chat tool to require new chat as a param

            ### Fixes
            - Misc minor performance optimizations
            """
        ),
        Version(
            id: "1.3.46",
            buildNumber: 130,
            date: ISO8601DateFormatter().date(from: "2025-08-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.46] - 2025-08-17

            ### Fixes
            - Fixes to potential memory leaks
            - Fixed 2 potential crash sources
            """
        ),
        Version(
            id: "1.3.45",
            buildNumber: 129,
            date: ISO8601DateFormatter().date(from: "2025-08-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.45] - 2025-08-16

            ### Fixes
            - Fixed issue where sometimes file edits fail because of file not loaded errors
            """
        ),
        Version(
            id: "1.3.44",
            buildNumber: 128,
            date: ISO8601DateFormatter().date(from: "2025-08-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.44] - 2025-08-12

            ### Improvements
            - MCP server is now much more resilient and can restore connections that otherwise failed
            - apply_edits tool now recovers from incorrect indentation escaping, and can now handle edits within single lines, making it more useful for non-code scenarios
            - get_code_structure tool can now recursively fetch codemaps for entire directories
            - manage_selection tool can now add/remove directories recursively
            - Optimized file selection in large repos
            - Ability to re-order root folders with the context menu
            - Optimized CPU usage when typing in text box
            """
        ),
        Version(
            id: "1.3.43",
            buildNumber: 127,
            date: ISO8601DateFormatter().date(from: "2025-08-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.43] - 2025-08-12

            ### Improvements
            - Optimized folder UI operations
            """
        ),
        Version(
            id: "1.3.42",
            buildNumber: 126,
            date: ISO8601DateFormatter().date(from: "2025-08-12T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.42] - 2025-08-12

            ### Improvements
            - Updated Claude Opus to 4.1 over API
            - Can now adjust font scale with cmd + -
            - Improved font scale coverage and efficiency
            - Improved toolbar layout
            - Improved MCP search pattern repair
            """
        ),
        Version(
            id: "1.3.41",
            buildNumber: 125,
            date: ISO8601DateFormatter().date(from: "2025-08-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.41] - 2025-08-11

            ### Improvements
            - Ability to select code snippets and copy them in the review screen
            - Improved MCP Search tool to better handle escaping regex sequences
            - Improved error messaging when using too many tokens with OpenAI models
            - Improved UX of hovering and selecting files

            ### Fixes
            - Fixed crash when opening certain directories
            - Fixed toolbar layouting issue that caused slowdown with very small windows
            - Fixed crash from stale file tree data
            - Fixes to cross window workspace persistence
            """
        ),
        Version(
            id: "1.3.39",
            buildNumber: 123,
            date: ISO8601DateFormatter().date(from: "2025-08-06T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.39] - 2025-08-06

            ### Improvements
            - **Git Diffs in Prompts:** Prompts now support including Git diffs from either all files or your exact file selection—perfect for focused reviews or sharing the context of your changes.
            - **Customizable Prompt Sections:** The prompt editor now lets you reorder, enable, or disable the new Git Diff section right alongside file trees and code maps. Existing prompt setups are seamlessly upgraded to add this flexibility.
            - **Reliable Diff Copying:** Copying Git diffs (selected or all files) is now instant and robust—even for complex or large changes.
            - **Transparent Token Breakdown:** Prompt builder now reports estimated token usage per section (including Git, tree, and maps) so you can fine-tune content and stay within model limits.
            - **Workspace Stability:** Saving workspaces and presets is now fully asynchronous, fixing rare issues with settings lost or conflicted between app windows.
            - **UI Polish:** Compact prompt and settings controls for a cleaner interface.

            ### Fixes
            - **Seamless Prompt Migration:** Prompt section order is upgraded automatically—new options like Git appear without disrupting your setup.
            - **Diff Operations:** Git diff copying works as expected for every selection, with accurate feedback in all scenarios.
            - Fixed an issue in the apply_edits tool to revert a string escaping change that caused some edits to fail.
            """
        ),
        Version(
            id: "1.3.38",
            buildNumber: 122,
            date: ISO8601DateFormatter().date(from: "2025-08-04T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.38] - 2025-08-04

            ### Improvements
            - MCP apply_edits tool now handles replace_all param like claude code does natively
            - Search tool now handles erroneous parameters more gracefully
            - Search tool now has much more sophisticated regex support
            - Improved the git tool to be more robust and support setting branches to use for comparisons
            - Optimized initial directory load and file delta handling
            - Optimized initial folder open

            ### Fixes
            - Fixed issues with file changes not respecting nested git ignore rules
            """
        ),
        Version(
            id: "1.3.37",
            buildNumber: 121,
            date: ISO8601DateFormatter().date(from: "2025-08-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.37] - 2025-08-01

            ### Fixes
            - Fix for rare issue where paths can't be loaded from stale snapshot of file hierarchy
            """
        ),
        Version(
            id: "1.3.36",
            buildNumber: 120,
            date: ISO8601DateFormatter().date(from: "2025-08-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.36] - 2025-08-01

            ### Fixes
            - Improved path lookup consistency to address issues with files not being found
            - Fixed slow typing in chat input box
            """
        ),
        Version(
            id: "1.3.35",
            buildNumber: 119,
            date: ISO8601DateFormatter().date(from: "2025-08-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.35] - 2025-08-01

            ### Fixes
            - Fixed wipe model presets
            """
        ),
        Version(
            id: "1.3.34",
            buildNumber: 118,
            date: ISO8601DateFormatter().date(from: "2025-08-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.34] - 2025-08-01

            ### Improvements
            - Can now specify whether or not you want delegated edit enabled with model presets
            - Can now disable model presets

            ### Fixes
            - Further stabilized app by removing animations on mcp server button as it was invoking crashes on certain configs
            - Fixed path resolution issues with file editing workflows in rare cases
            """
        ),
        Version(
            id: "1.3.33",
            buildNumber: 117,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.33] - 2025-07-31

            ### Improvements
            - Polished tooltips
            - Fix to updater not closing app to restart
            - More subtle notification color
            - Update available notification
            """
        ),
        Version(
            id: "1.3.32",
            buildNumber: 116,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.32] - 2025-07-31

            ### Fixes
            - Fix for misaligned tooltips
            - Workaround for Swift bug that causes app to crash during toolbar layout changes. Should make app significantly more stable
            """
        ),
        Version(
            id: "1.3.31",
            buildNumber: 115,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.31] - 2025-07-31

            ### Fix
            - Fix relayout from mcp server state change that potentially caused crash during tool calls
            """
        ),
        Version(
            id: "1.3.30",
            buildNumber: 114,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.30] - 2025-07-31

            ### Fixes
            - Concurrency stability fixes accross the board
            """
        ),
        Version(
            id: "1.3.29",
            buildNumber: 113,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.29] - 2025-07-31

            ### Fixes
            - Reworked expensive sort based search logic that regressed search perf
            - Fixed json schema adherance for mcp tools
            - Fixed thread issue that potentially caused a crash during mcp tool calls
            - Fixed preset menus no longer working
            - Fixed git diff copy not working
            """
        ),
        Version(
            id: "1.3.28",
            buildNumber: 112,
            date: ISO8601DateFormatter().date(from: "2025-07-31T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.28] - 2025-07-31

            ### New Features
            - Early git integration, select unstaged files and copy diffs to the clipboard for code reviews

            ### Improvements
            - Improvements to MCP search tool, to reduces cases of failed searches
            - Optimized and improved ui search to sort results and run faster (ported to C)
            - Reworked Workspace and preset dropdown ui, reorganized side bar to be clearer

            ### Fixes
            - Fixed file tree set to none not working
            """
        ),
        Version(
            id: "1.3.27",
            buildNumber: 111,
            date: ISO8601DateFormatter().date(from: "2025-07-30T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.27] - 2025-07-30

            ### Improvements
            - Added support for hierarchical ignore files files
            - Added support for .cursor ignore
            - Rebuilt git ignore compiler in C for much faster pattern matching
            - Ported many utilities to C for faster perf
            - Improved Search MCP tool to support | patterns which claude loves to do
            - Improved general search in app ui to support more ergonomic fuzzy lookup

            ### Fixes
            - Reworked MCP tool discovery concurrency to hopefully resolve app crashes during use
            - Fixed concurrency related issues with app licensing checks
            """
        ),
        Version(
            id: "1.3.26",
            buildNumber: 110,
            date: ISO8601DateFormatter().date(from: "2025-07-29T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.26] - 2025-07-29

            ### Fixes
            - Improved stability on chat send tool if no presets are present
            - Fixed issue with tool availability not being updated when server is toggled, and multi window is toggled
            - Chat streaming stability improvement
            """
        ),
        Version(
            id: "1.3.25",
            buildNumber: 109,
            date: ISO8601DateFormatter().date(from: "2025-07-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.25] - 2025-07-28

            ### Hot Fix
            - Fix for claude code file edits not being registered correctly due to edit method
            """
        ),
        Version(
            id: "1.3.24",
            buildNumber: 108,
            date: ISO8601DateFormatter().date(from: "2024-07-28T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.24] - 2024-07-28

            ### New Features
            - **MCP Chat Model Presets** – Prepare a list of models available to the chat MCP tools, with descriptions on when the agent should use each model.

            ### Improvements
            - Unified diffs generated by edit and chat tools are now slimmed down to optimize token usage.
            - Chat list tool can now return a subsection of the chat to avoid overwhelming token use.

            ### Fixes
            - Fixes for multi-window settings behavior.
            - Workspaces and presets added or removed in one window are now propagated to others.
            - Fixed issue where selected stored prompts in chat were not respected.
            """
        ),
        Version(
            id: "1.3.23",
            buildNumber: 107,
            date: ISO8601DateFormatter().date(from: "2024-07-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.23] - 2024-07-24

            ### New Features
            - **Multi-window MCP mode** – Allows clients to access different workspaces in parallel and switch between them.

            ### Improvements
            - When making file edits, prioritize roots with selected files to disambiguate matching file paths.
            - Improved file tree rendering and sorting.
            - Removed resize handle on the instructions view to resolve laggy text input and general UI lag.
            - Improved chat session loading performance.
            - Resolved quirks with chat session ordering when switching chats.
            - Improved initial workspace open performance.

            ### Fixes
            - Fixed state saving quirks when working with two windows on the same workspace.
            - Fixed issue with `create -> rewrite` conversion for detected files when generating edits.
            - Resolved slowdown/hangs caused by invoking the chat over MCP.
            - Fixed issue with file tree preview not updating when switching modes.
            """
        ),
        Version(
            id: "1.3.21",
            buildNumber: 105,
            date: ISO8601DateFormatter().date(from: "2024-07-22T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.21] - 2024-07-22

            ### Fixes
            - Fix for app hang regression in chat when applying edits.
            """
        ),
        Version(
            id: "1.3.20",
            buildNumber: 104,
            date: ISO8601DateFormatter().date(from: "2024-07-21T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.20] - 2024-07-21

            ### MCP
            - Completely revoke connections made to the MCP when using multiple instances of RepoPrompt on the same local Wi-Fi network.

            ### File Edits & Creation
            - Reworked path resolution logic to be significantly more robust and resilient.

            ### Optimizations & Stability Fixes
            - Improved workspace opening latency.
            - Improved chat switching performance and general stability.
            - Miscellaneous stability improvements.
            """
        ),
        Version(
            id: "1.3.19",
            buildNumber: 103,
            date: ISO8601DateFormatter().date(from: "2024-07-17T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.19] - 2024-07-17

            ### Claude Code Integration
            - Improved Claude Code stability, especially for large prompts.
            - Added ability to specify model parameter (`opus` vs `sonnet`).
            - Improved installation detection, favoring the most recently detected version.
            - Added more installation locations and support for directly specifying the install location.

            ### MCP Tools
            - Improved tool descriptions.
            - Added 2 new built-in prompts: **[MCP: Pair Program]** and **[MCP: Claude Code]** – prime a Claude Code chat with these prompts for much better utilization of RepoPrompt MCP.

            ### Chat View
            - Added ability to see selected files for a given chat message and restore selection state.
            - Added a "Refresh Chat View" button to resolve disappearing messages or glitched scrollbars (larger refactor coming).

            ### Code Maps
            - Added button to reset CodeMap cache, as some users reported broken maps.

            ### Prompts
            - Enhanced prompts to better reference input structure
            - Added examples for whole file rewrite file editors, to improve performance with smaller models like gemini flash 2.0
            """
        ),
        Version(
            id: "1.3.18",
            buildNumber: 102,
            date: ISO8601DateFormatter().date(from: "2025-07-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.18] - 2025-07-16

            - Improved Claude Code installation detection, catching more locations.
            - Fixed stale cache for codemaps, which was causing stale maps to be returned despite algorithm improvements.
            """
        ),
        Version(
            id: "1.3.17",
            buildNumber: 101,
            date: ISO8601DateFormatter().date(from: "2025-07-16T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.17] - 2025-07-16

            ### Model Providers
            - **Claude Code as a provider** – Uses your existing Claude Code installation as an API provider, leveraging your existing MAX subscription.
            - **Groq provider** – Supports the new Kimi K2 model.

            ### MCP Server
            - Added a new and improved search tool that allows Claude to navigate codebases far more efficiently.
            - The "apply edits" tool now validates ambiguous search blocks and returns an error instead of applying incorrect edits.
            - The chat tool no longer occasionally operates on stale files.
            - The chat tool now validates file paths before starting a chat, resolving the issue where empty chats would occur.
            - Fixed an issue where the MCP server instance would sometimes connect to a repo prompt client on another machine on a local network.

            ### Chat - Delegate Edits
            - Refined delegate edit approach and prompts, resulting in much more reliable edits.
            """
        ),
        Version(
            id: "1.3.16",
            buildNumber: 100,
            date: ISO8601DateFormatter().date(from: "2025-07-14T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.16] - 2025-07-14

            ### File Edits
            - Editing prompts now include language-specific code examples, defaulting to JavaScript instead of Swift.
            - Improved delegate edits for better scoping and format adherence, enhancing edit accuracy.

            ### UI Improvements
            - Added Shift Select in file tree for faster bulk file selection.
            - Significantly optimized Settings view for better performance.

            ### MCP
            - Concurrent calls to chat send will now return errors indicating chat is busy.
            """
        ),
        Version(
            id: "1.3.15",
            buildNumber: 99,
            date: ISO8601DateFormatter().date(from: "2025-07-11T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.15] - 2025-07-11

            ### Codemaps
            - Added support for PHP.
            - Revamped JavaScript and TypeScript support for improved accuracy.

            ### General Improvements
            - Added support for Grok 4.
            - Improved file selection performance in large repositories.
            - Enhanced handling of large file system deltas when app is backgrounded for extended periods.
            - Added option to include content header in custom provider.
            - Added option to adjust the number of retained chats.
            """
        ),
        Version(
            id: "1.3.14",
            buildNumber: 98,
            date: ISO8601DateFormatter().date(from: "2025-07-07T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.14] - 2025-07-07

            ### MCP Server
            - Improved chat tools clarity and usability for agents
            - Added more 1-click install options

            ### UX
            - Cleaned up top bar clutter by moving items into the options menu
            """
        ),
        Version(
            id: "1.3.13",
            buildNumber: 97,
            date: ISO8601DateFormatter().date(from: "2024-07-04T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.13] - 2024-07-04

            ### MCP Server Wave 3

            - **Chat tools:** Claude gets a pair programmer!
            	External agents can now invoke the powerful Repo Prompt built in chat to discuss, debug, plan, and engineer changes.
            - Improved search and read file consistency around 1-based line numbering.
            - Chat and apply edit tools can now return unified diffs to track changes made in each operation.
            """
        ),
        Version(
            id: "1.3.12",
            buildNumber: 96,
            date: ISO8601DateFormatter().date(from: "2024-07-02T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.12] - 2024-07-02

            ### 🚀 New Features
            - **MCP Server Wave 2 → File operations!**
            	- Ability to create, delete, move, and edit files.
            	- File editing now supports applying multiple search and replace operations in a single tool call.
            	- Enhanced search tool with path-limiting capability.
            	- Consolidated tools from 15 down to 13, despite adding new functionality.
            	- Improved tool descriptions to enhance agent usability.
            	- Added ability to cancel long-running tool calls.

            ### 🐛 Bug Fixes
            - Fixed issue where chat names were not being saved during chat operations.
            """
        ),
        Version(
            id: "1.3.11",
            buildNumber: 95,
            date: ISO8601DateFormatter().date(from: "2024-07-01T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.11] - 2024-07-01

            ### Fixes
            - Addressed memory leaks related to repeated tool calls.
            - Fixed minor diff generation regression for certain matches.
            """
        ),
        Version(
            id: "1.3.10",
            buildNumber: 94,
            date: ISO8601DateFormatter().date(from: "2024-06-30T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.10] - 2024-06-30

            ### Improvements

            #### Chat / XML Diff
            - Reworked Diff generation logic to provide generally better matches, especially with slightly imperfect search blocks.
            - Improved chat selected files logic when switching between chats.

            #### Compose UX
            - Fixed handling of identical relative paths for files in multiple root folders.

            #### MCP Server
            - Added icon animation when tools are running.
            - Report errors when paths are incorrect.
            - Request plan tool can now update selection in a single tool call — helps avoid incorrect calls for this tool.
            """
        ),
        Version(
            id: "1.3.9",
            buildNumber: 93,
            date: ISO8601DateFormatter().date(from: "2024-06-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.9] - 2024-06-27

            ### Improvements
            - Added always allow connection from clients for new connections
            - Optimized initial directory load
            - Optimized file loading overhead
            - Fixed UI issue for token counts not updating on files
            """
        ),
        Version(
            id: "1.3.8",
            buildNumber: 92,
            date: ISO8601DateFormatter().date(from: "2024-06-27T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.8] - 2024-06-27

            ### Fixes
            - Fixed issue where MCP server would flush file system deltas without applying them.
            - Optimized file content loading.
            - Fixed regression where certain files are considered binary when they should not be.
            """
        ),
        Version(
            id: "1.3.7",
            buildNumber: 91,
            date: ISO8601DateFormatter().date(from: "2024-06-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.7] - 2024-06-26

            ### Hotfix
            - Rollback some state dirtying changes that prevent some tools from updating when needed
            - Added timeouts for search overruns.
            - Implemented better binary file detection to avoid loading in junk files.
            """
        ),
        Version(
            id: "1.3.6",
            buildNumber: 90,
            date: ISO8601DateFormatter().date(from: "2024-06-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.6] - 2024-06-26

            ### Fixes
            - Rolled back text changes causing issues.
            - Better MCP server cleanup.
            - Fixed some state change issues when switching workspaces.
            """
        ),
        Version(
            id: "1.3.5",
            buildNumber: 89,
            date: ISO8601DateFormatter().date(from: "2024-06-26T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.5] - 2024-06-26

            ### Improvements
            - Optimized UI performance.
            - Reworked compose text view to be asynchronous and significantly more responsive.
            - Improved MCP server setup to prevent UI stalling under heavy load.
            - Duplicate and disabled tools are no longer advertised to clients.
            """
        ),
        Version(
            id: "1.3.4",
            buildNumber: 88,
            date: ISO8601DateFormatter().date(from: "2024-06-25T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.4] - 2024-06-25

            ### Hotfix
            - Resolve Model selection getting reset periodically
            - Reduced logging overhead that caused some app slowdown
            - Added visual feedback indicators on 'Accept all' and 'Restore' buttons in chat
            """
        ),
        Version(
            id: "1.3.3",
            buildNumber: 87,
            date: ISO8601DateFormatter().date(from: "2024-06-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.3] - 2024-06-24

            ### Improvements
            - Fixed cursor compatibility with MCP using new symlink server path.
            """
        ),
        Version(
            id: "1.3.1",
            buildNumber: 85,
            date: ISO8601DateFormatter().date(from: "2024-06-24T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3.1] - 2024-06-24

            ### MCP Server Improvements
            - **Fixed** issue where backgrounding Repo Prompt too long caused stale file state during tool calls.
            - **Revamped** search tool: now combines `grep` and file search.
            - **Enhanced** codemap tools: added listing capability for available codemaps and multi-codemap retrieval.
            - **Added** file tree tool with configurable options to assist LLM in navigating the codebase.
            - **Improved** file selection tool, now supporting additive or replacement paths.
            - **Changed** app path to avoid spaces issue with certain MCP clients (please update your configuration!)
            """
        ),
        Version(
            id: "1.3",
            buildNumber: 84,
            date: ISO8601DateFormatter().date(from: "2024-06-23T00:00:00Z") ?? Date(),
            changes: """
            ## [1.3] - Major Release

            ### MCP Server
            - Repo Prompt now includes an MCP server that allows external tools to interact with Repo Prompt.
            - Utilize search, codemaps, and planning models for enhanced interaction and improved results with Claude Code or Cursor (Tutorials coming soon).
            - Control the UI: update file selection and instructions.

            ### General Improvements
            - Enhanced prompts for Delegated Edits / Architect XML.
            - Improved layout of Apply XML for better compatibility with small screens.

            ### Fixes
            - Resolved issues causing frequent file edit failures.
            - Fixed Context Builder filter application issues.
            """
        )
    ]

    static var currentVersionString: String {
        current.buildNumber == 1 ? current.id : "\(current.id) (\(current.buildNumber))"
    }

    static var currentVersionStringLabel: String {
        "\(current.id)"
    }

    static func formattedChangelog(for version: Version) -> String {
        // Don't show build number for current version since it's in the title
        if version.buildNumber == current.buildNumber {
            "\n\(version.changes)"
        } else {
            """
            ---
            ## Version \(version.id)
            \(version.changes)
            """
        }
    }

    static var fullChangelog: String {
        history.map { formattedChangelog(for: $0) }.joined(separator: "\n\n")
    }
}

import MarkdownUI

class VersionManager: ObservableObject {
    @Published var shouldShowVersionPopup = false
    @Published var shouldShowWelcomeView = false
    @Published var shouldShowVersionButton = false

    func showChangelog() {
        shouldShowVersionPopup = true
    }

    func dismissVersionButton() {
        shouldShowVersionButton = false
        // Store that we've dismissed the button for this version
        UserDefaults.standard.set(Self.currentBuildNumber, forKey: "versionButtonDismissedForBuild")
        UserDefaults.standard.set(Self.currentVersionID, forKey: "versionButtonDismissedForVersion")
    }

    static var currentVersion: String {
        Changelog.currentVersionString
    }

    static var currentBuildNumber: Int {
        Changelog.current.buildNumber
    }

    static var currentVersionID: Double {
        // Convert version ID string to double for comparison (e.g., "0.9" -> 0.9)
        Double(Changelog.current.id) ?? 0.0
    }

    init() {
        checkWelcomeAndVersion()
    }

    private func checkWelcomeAndVersion() {
        // Check if welcome view has been shown before
        let hasShownWelcome = true || UserDefaults.standard.bool(forKey: "hasShownWelcomeViewV3")

        if !hasShownWelcome {
            // If welcome hasn't been shown, show it and mark as shown
            shouldShowWelcomeView = true
            shouldShowVersionPopup = false
            shouldShowVersionButton = false
            // We'll update the flag when the welcome view is dismissed
        } else {
            // If welcome was already shown, check regular version logic
            checkVersion()
        }
    }

    private func checkVersion() {
        let lastBuildNumber = UserDefaults.standard.integer(forKey: "lastSeenBuildNumber")
        let lastVersionID = UserDefaults.standard.double(forKey: "lastSeenVersionID")

        // Check if the button was dismissed for this version
        let dismissedForBuild = UserDefaults.standard.integer(forKey: "versionButtonDismissedForBuild")
        let dismissedForVersion = UserDefaults.standard.double(forKey: "versionButtonDismissedForVersion")

        // Show button if either build number or version ID increased
        if lastBuildNumber < Self.currentBuildNumber || lastVersionID < Self.currentVersionID {
            // Only show the button if it hasn't been dismissed for this version
            if dismissedForBuild < Self.currentBuildNumber || dismissedForVersion < Self.currentVersionID {
                shouldShowVersionButton = true
            }
            shouldShowVersionPopup = false

            // Update stored values
            UserDefaults.standard.set(Self.currentBuildNumber, forKey: "lastSeenBuildNumber")
            UserDefaults.standard.set(Self.currentVersionID, forKey: "lastSeenVersionID")
        } else {
            shouldShowVersionPopup = false
            shouldShowVersionButton = false
        }
    }

    /// Call this when welcome view is dismissed
    func markWelcomeAsShown() {
        UserDefaults.standard.set(true, forKey: "hasShownWelcomeViewV3")
        shouldShowWelcomeView = false

        // Also update version information
        UserDefaults.standard.set(Self.currentBuildNumber, forKey: "lastSeenBuildNumber")
        UserDefaults.standard.set(Self.currentVersionID, forKey: "lastSeenVersionID")
    }
}

struct VersionPopupView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) { // Adjusted spacing
            // Header
            HStack {
                Text("Welcome to Repo Prompt Version \(Changelog.currentVersionStringLabel)")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold)) // Slightly smaller title
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle()) // Ensure the whole area is clickable
            }
            .padding(.horizontal) // Add horizontal padding to header
            .padding(.top) // Add top padding

            // Changelog Content Area
            GroupBox { // Wrap ScrollView in GroupBox
                ScrollView {
                    Markdown(Changelog.fullChangelog)
                        // .markdownTheme(.gitHub) // Apply a theme if desired
                        .textSelection(.enabled) // Ensure text is selectable
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 5, leading: 10, bottom: 10, trailing: 10)) // Adjust padding inside ScrollView
                }
            }
            .padding(.horizontal) // Add horizontal padding to GroupBox

            // Footer Links
            HStack(spacing: 16) {
                Spacer()
                Link("Getting Started", destination: URL(string: "https://youtube.com/playlist?list=PLFg9suyZ1OnIKYyoCbAGBaFB-QOAk1nSq&si=hiUSja9eTRWeB26j")!)
                    .buttonStyle(CustomButtonStyle())
                Link("Join Discord", destination: URL(string: "https://discord.gg/NtbFDAJPGM")!)
                    .buttonStyle(CustomButtonStyle())
                Link("Visit Website", destination: URL(string: "https://repoprompt.com")!)
                    .buttonStyle(CustomButtonStyle())
                Spacer()
            }
            .padding(.bottom) // Add bottom padding
            .padding(.horizontal) // Add horizontal padding to footer
        }
        .padding(.vertical, 5) // Reduce overall vertical padding slightly if needed
        .frame(width: fontPreset.scaledClamped(550, max: 700), height: fontPreset.scaledClamped(600, max: 760)) // Adjusted width slightly
    }
}

struct WelcomeView: View {
    @Binding var isPresented: Bool
    @ObservedObject var versionManager: VersionManager
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header with icon and close button
            HStack {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                    .symbolRenderingMode(.hierarchical)

                Text("Welcome to Repo Prompt 1.0!")
                    .font(fontPreset.titleFont)
                    .fontWeight(.bold)

                Spacer()

                Button(action: {
                    isPresented = false
                    versionManager.markWelcomeAsShown()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()

            ScrollView {
                VStack(spacing: 28) {
                    // Thank you section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Thank you for your support!")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("If you've been using the beta for a while, thank you so much for engaging with the app and helping shape it into what it is today. While the beta is over, this is a new beginning for the app and this community.")
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Migration note section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Important Migration Note")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("By installing this version, the app has been upgraded to no longer use the sandbox. I have made some best efforts to migrate workspaces and prompts, but some data like API settings will need to be re-entered. This migration has happened to better serve you all, with eventual automated terminal commands, among other things.")
                            .lineSpacing(4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Features section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Community Edition Features")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("RepoPrompt CE makes the core feature set available without paid license gates:")
                            .lineSpacing(4)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "infinity.circle.fill")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 20))
                                    .foregroundColor(.blue)
                                    .frame(width: fontPreset.scaledMetric(24))

                                Text("Prompt, copy, and chat workflows are available without edition token limits")
                                    .font(fontPreset.standardFont)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "gearshape.fill")
                                    .font(fontPreset.swiftUIFont(sizeAtNormal: 20))
                                    .foregroundColor(.blue)
                                    .frame(width: fontPreset.scaledMetric(24))

                                Text("CodeMaps, agent workflows, and custom providers are available in CE")
                                    .font(fontPreset.standardFont)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // License information section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Community Edition")
                            .font(fontPreset.headlineFont)
                            .fontWeight(.bold)

                        Text("This build removes paid activation flows and subscription prompts.")
                            .lineSpacing(4)

                        HStack {
                            Spacer()
                            // Monthly subscription option
                            VStack(spacing: 12) {
                                Text("FOSS Build")
                                    .font(fontPreset.subheadlineFont)
                                    .fontWeight(.medium)

                                Text("No license required")
                                    .font(fontPreset.headlineFont)

                                Text("All CE features are enabled by default.")
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)

                                Text("Fork, build, and use without activation")
                                    .font(fontPreset.subheadlineFont)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)

            // Footer with links
            HStack(spacing: 16) {
                Spacer()

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://youtu.be/-J3CwrTrAlE?si=00Ig2DePtMyD_s03")!)
                }) {
                    Text("Getting Started")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://discord.gg/NtbFDAJPGM")!)
                }) {
                    Text("Join Discord")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://repoprompt.com")!)
                }) {
                    Text("Visit Website")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                // Roadmap link
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://repoprompt.com/roadmap")!)
                }) {
                    Text("View Our New Roadmap")
                        .fontWeight(.medium)
                }
                .buttonStyle(CustomButtonStyle())

                Spacer()
            }
            .padding(.bottom)
            .padding(.horizontal)
        }
        .frame(width: fontPreset.scaledClamped(650, max: 820), height: fontPreset.scaledClamped(720, max: 860))
        .background(Color(NSColor.windowBackgroundColor))
    }
}
