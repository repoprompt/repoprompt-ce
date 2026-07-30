import Foundation

/// Provider-neutral RepoPrompt workflow prompt renderers.
/// These prompts are installed as managed skills/commands and exposed through Agent Mode,
/// MCP prompts, and prompt-copy surfaces.
enum RepoPromptWorkflowPrompts {
    /// Bump when skill content changes.
    /// Version 2: Added embedded version markers to frontmatter, fixed CLI help reference.
    /// Version 3: Added rp-oracle-export command.
    /// Version 4: Added rp-review and rp-refactor commands.
    /// Version 5: Added anti-patterns and scoped down exploration before context_builder.
    /// Version 6: Added Phase 0 workspace verification, mandatory branch confirmation for review, CLI window routing. Renamed commands to skills, added .agents/skills support.
    /// Version 7: Migrated to folder/SKILL.md structure (.claude/skills/<name>/SKILL.md), added name field to frontmatter.
    /// Version 8: Redesigned rp-investigate to leverage agent/context-builder/oracle strengths, preserve selection, and encourage judicious oracle usage.
    /// Version 9: Refreshes installed ChatGPT Prompt Export / rp-oracle-export skill content after the naming and workflow text update.
    /// Version 10: Makes rp-build follow-up chat explicitly optional/targeted rather than a mandatory plan challenge step.
    /// Version 11: Clarifies rp-investigate capability boundaries so factual lookups stay with direct tool calls, not chat/oracle.
    /// Version 12: Tightens rp-build checklist wording and updates rp-investigate metadata to reflect tool-vs-chat boundaries.
    /// Version 13: Aligns rp-build with the measured architect tone: default trust the plan and only validate when a concrete question remains.
    /// Version 14: Clarifies rp-build chat/oracle boundaries and slims metadata to context-builder-plan → implement.
    /// Version 15: Removes redundant rp-build intro role/tool wording.
    /// Version 16: Updates rp-oracle-export to confirm Question/Plan/Review intent, reuse review scope confirmation, and refresh managed exports for the 160k ChatGPT budget/review-hotword flow.
    /// Version 17: Tightens review-shaped clarify instructions for rp-oracle-export and refreshes managed skills after the broader git/review hotword detection update.
    /// Version 18: Reworks rp-oracle-export around conversational intent clarification, a fast path for simple tasks, pre-export selection review, and unique repo-local prompt export paths.
    /// Version 19: Simplifies rp-oracle-export, restores correct agent/workflow structure, and tightens review guidance.
    /// Version 20: Tightens rp-oracle-export so broad Question/Plan exports go straight to context_builder instead of burning tool calls to prove complexity.
    /// Version 21: Tightens rp-oracle-export filename/path guidance so exports default to repo-local prompt-exports paths with request-derived slugs.
    /// Version 22: Skips redundant post-context_builder export re-checks in rp-oracle-export; keep manual selection/prompt review for fast-path exports only.
    /// Version 23: Treats context_builder output as the export prompt source of truth in rp-oracle-export; avoid critiquing or rewriting its generated prompt unless there is a concrete mismatch.
    /// Version 24: Adds `agents/openai.yaml` to managed skill folders so Codex disables implicit skill invocation for every managed skill except `rp-reminder`, which remains eligible for implicit invocation.
    /// Version 25: Quotes YAML frontmatter scalars so skill descriptions containing `:` remain valid for Codex skill parsing.
    /// Version 26: Keeps `rp-oracle-export` implicitly invokable alongside `rp-reminder`.
    /// Version 27: Reverts `rp-oracle-export` to explicit-only; only `rp-reminder` remains implicitly invokable.
    /// Version 28: Removes redundant 'review' word-choice warning; routes audits/evaluations to Plan intent instead of Review.
    /// Version 29: Makes CLI skill frontmatter names match their `*-cli` parent directories for strict skill validators.
    /// Version 30: Fixes prompt-inception bug in rp-oracle-export: strips export/prompt meta-framing from $ARGUMENTS before passing to context_builder, adds anti-pattern against leaking export intent into builder instructions, and defaults ambiguous/generic requests to Plan preset.
    /// Version 31: Adds rp-orchestrate workflow — plan, decompose, and delegate tasks across multiple agents.
    /// Version 32: Teaches rp-orchestrate to export Oracle responses for delegated agent handoff.
    /// Version 33: Slims oracle export format (title + response only), shortens filenames, adds export_response to context_builder, improves orchestrate dispatch scoping guidance.
    /// Version 34: Refreshes managed skills after supported skill changes so existing client setups reinstall current content.
    /// Version 35: Removes `oracle_export_path` parameter guidance from agent_run/agent_explore; rp-orchestrate and rp-refactor now reference exported plan paths inside message text.
    /// Version 36: Fixes CLI workflow examples to use builder --export and pass exported plan paths inside agent_run messages.
    /// Version 37: Replaces generic `agent_run / agent_explore` phrasing with capability-specific wording and removes the `paste` verb in export delegation guidance.
    /// Version 38: Reframes rp-investigate so explore agents are the primary evidence-gathering mechanism; main agent orchestrates and synthesizes instead of duplicating sub-agent reconnaissance.
    /// Version 39: Splits rp-investigate investigator agents into pair (main investigation line, deeper reasoning) + explore (parallel narrow checks); main agent dispatches both and orchestrates.
    /// Version 40: Reworks rp-orchestrate — contextualize-first Phase 1 with explore-agent escalation, fresh-agent-per-item dispatch default with Codex-aware `roles_only` escape hatch. Ports shared orchestration guidance into rp-refactor via 6 new helper blocks (decomposition, roles-only check, parallel dispatch, dispatch brief, final rollup, monitor-and-verify). Softens "CRITICAL"/"DO NOT" tone across rp-investigate, rp-refactor, rp-build, and rp-review; unifies plan-path references to `<plan path>`.
    /// Version 41: Tells rp-orchestrate to stick to the predefined role labels and not reason about specific underlying models unless the user names one — avoids speculative mapping across providers.
    /// Version 42: rp-investigate — sequence explore agents before the pair investigator (so its brief folds in their findings) and direct the pair, as lead investigator, to write findings into the investigation report file.
    /// Version 43: rp-investigate — explore agents are now used for pre-context_builder external info gathering (git/web/docs) and inside the pair investigator's own session; the main agent no longer runs a parallel explore fleet alongside the pair.
    /// Version 44: rp-investigate — adds optional parallel pair investigators for genuinely disjoint hypothesis paths (with disjoint scopes, distinct report sub-sections, and a 2–3 cap); clarifies where more parallelism does and doesn't pay off.
    /// Version 45: rp-investigate — upgrades pair investigator brief from passive permission to active encouragement to fan out explore agents for parallel reconnaissance.
    /// Version 46: rp-investigate — tightening pass: consolidates duplicated guidance, flattens Phase 3 subsections, merges Phase 1/1.5, rewrites file-selection guidance for the delegation model (pair reads don't populate main agent's selection; bias toward inclusion), adds termination criteria and builder-failure fallback, fixes Role Summary inconsistencies.
    /// Version 47: rp-orchestrate — Housekeeping section now also guides cleanup of stray plan/review exports under `prompt-exports/` so superseded or consumed export files don't accumulate across a multi-agent task.
    /// Version 48: rp-reminder — refresh for the current toolset: adds sections for context/planning tools (`manage_selection`, `context_builder`, `ask_oracle`, `workspace_context`, `prompt`, `oracle_chat_log`, `ask_user`, `git`) and agent delegation (`agent_run` / `agent_manage` with role labels explore/engineer/pair/design, fan-out + steer patterns, export handoff). Keeps the MCP/CLI variant split.
    /// Version 49: rp-reminder — drops the workflow-skills cross-reference table so the reminder doesn't nudge the agent to self-invoke other skills; those are user-invoked entry points.
    /// Version 50: rp-investigate — drop the pair-investigator tier. Main agent is the lead investigator and report author again; explore agents are reframed as liberal context-preserving pulses (external facts + narrow in-workspace side-questions) fanned out alongside the main line of inquiry rather than gated behind a delegation layer. Also drops the `## Investigator Findings` report section, the parallel-pair branch, the Phase 1/1.5 split, and pair-era anti-patterns/roles; trims Role Summary to four columns.
    /// Version 51: Adds rp-optimize — an app-agnostic iterative performance optimization loop built on orchestrate's scaffolding. Protocol: define target + stop criterion, instrument with debug-only metrics in secondary test/support files, capture a baseline per AGENTS.md testing protocols, then loop plan → dispatch pair for one optimize+harden cycle → re-measure → ask oracle for next plan, until oracle signals satisfaction, the metric target is met, or the iteration cap is reached.
    /// Version 52: Fixes the shared roles-only check used by rp-orchestrate and rp-refactor — the `codexExec:*` prefix never appears in the `roles_only=true` view, so guidance now keys off the `Codex CLI` display-name prefix (with `codexExec:*` kept as a fallback cue when inspecting an explicit compound `model_id`).
    /// Version 53: Reverts Version 50 — restores the pair-investigator tier in rp-investigate. Main agent returns to orchestrating (dispatches explore agents for…
    /// Version 54: Disables implicit invocation for the `rp-reminder-cli` skill so only the MCP `rp-reminder` variant remains auto-invocable; CLI variant is now explicit-only.
    /// Version 55: rp-optimize — restructures the workflow around delegation. Phase 1 fans out explore agents to map surface area (AGENTS.md/measurement conventions, hot-path location, existing benchmarks, scope boundaries) instead of the main agent doing the navigation. Phase 2 routes through `context_builder` in plan mode to produce the metric definition, instrumentation strategy, first-pass optimization candidates, and scoreboard scaffold in one pass. Phase 3 dispatches a pair agent to land instrumentation and capture the baseline (multi-sample with variance) so the main agent never runs measurements directly. Phase 4 keeps measurement and optimization fully delegated; main agent verifies via scoreboard reads and uses explore agents for deeper checks. Adds a role summary table.
    /// Version 56: rp-optimize — Phase 1 now does bottleneck scouting *around* the named target, not just locating it. Replaces the single "hot path" explore with three: target & call graph (locate + map callers with context), bottleneck candidates (scout target + callers + adjacent code for tight loops, per-iteration allocations, locking, redundant computation, expensive transformations, sync I/O on hot paths, O(n²) patterns; rank 2–3 with rationale), and prior perf work (existing benchmarks, profiler traces, sample reports, perf-related TODOs in the repo). Phase 1c synthesis adds a ranked candidate list as a fifth output. Phase 2's context_builder call now takes those bottleneck candidates and prior perf work as inputs so first-pass optimization candidates are evidence-grounded. Adds matching anti-pattern and role-summary row.
    /// Version 57: rp-optimize — leanness + drift pass per `docs/reviews/rp-optimize-skill-leanness-2026-04-27.md`. Reframes Phase 1a so full bottleneck fan-out is the explicit default and shortcuts are narrow exceptions (closes the v56 off-ramp). Drops sharedMonitorAndVerifyBlock from Phase 4d (it contradicted the surrounding "minimal direct reads" guidance) and replaces it with a one-line domain-specific reminder; same drop for sharedDispatchBriefGuidance in Phase 4c (the inline examples already model dispatch-brief patterns). Compresses Phase 1b's five near-identical agent_run example blobs to two representative ones plus a comment pointing to the table. Makes context_builder the explicit default in Phase 4a, removes the "or the oracle" parenthetical that lets readers drift off the candidate-queue plan format. Collapses duplicate anti-patterns (twins + recipe-restating bullets). Drops the Quick Reference table and one-cell padding rows from the Role Summary; key operations folded into the surrounding prose. Tightens the iteration cap to a hard 5 with explicit user opt-in for loop 6, the "Can't tell" path to a stop-optimizing imperative with rationale, and the divergence-handling in Phase 1c with a concrete pause/ask/wait template. Replaces inline `variant == .cli ? "builder" : "context_builder"` ternaries with the existing `\\(builderName)` constant for consistency. Phase 4 housekeeping no longer re-renders sharedSessionCleanupSection; only the stray-plan-export hint remains with a back-reference to Phase 3.
    /// Version 58: Updates stray prompt-export cleanup guidance to use true absolute delete paths.
    /// Version 59: rp-orchestrate / rp-refactor — adds "two conversations, kept separate" guidance to the shared dispatch-brief block so the orchestrator translates user steering into the technical task instead of proxying user-to-orchestrator commentary verbatim into peer-agent briefs. Adds matching rp-orchestrate anti-pattern with the cancel-and-re-send remedy when a brief already carried that commentary.
    /// Version 60: Adds rp-deep-plan — a delegation-heavy planning workflow that produces a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document. Mandatory first interactive action is `ask_user` to pick a user-involvement mode (up front / mid-flow / hands-off); the rest of the run pauses for grounded ambiguity-shaping questions only at the chosen checkpoint. Phase 2 fans out explore agents across in-workspace seams, optional external research, and optional prior art lanes. Phase 4 runs `context_builder` in plan mode with `export_response:true` and merges the architectural bones into the plan (not a verbatim append) before deleting the standalone export. Phase 6 is a bounded one-page design-agent critique (under-specified seams / contradictions / overplanning risk / order-changing questions only) — explicitly non-authorial. Phase 7 is the orchestrator's editorial polish: shorter, organized, free of contradiction, no transcript dumps. Hands-off mode becomes interactive at the final hand-off.
    /// Version 61: rp-deep-plan — adds explicit halt-on-`ask_user`-timeout handling for involvement-mode checkpoints. When the user has actively picked a mode that promises a pause (Up front → Phase 1.5, Mid-flow → Phase 5) and a downstream `ask_user` returns `timed_out: true`, the workflow halts at that checkpoint instead of proceeding with assumed answers — resuming from the same prompt when the user replies. The Phase 1 involvement-mode prompt itself is exempt: a timeout there means "no signal" and falls through to Hands-off (same as `skipped: true`), so the workflow doesn't stall before any direction has been given. Adds a Core principle, a Phase 1 "Handling the answer" sub-section that distinguishes the three result shapes, halt reminders at the end of Phase 1.5 / Phase 5, and a matching anti-pattern.
    /// Version 62: rp-deep-plan — reframes the plan pass so the context_builder export is a preservation baseline, not an unquestionable authority: the final plan keeps its supported implementation-bearing detail, allows evidence-backed correction, removal, and lossless consolidation, and never trims accurate detail merely for brevity. Phase 4 builds a coverage ledger while reading the export; Phase 6 is a completeness/correctness critic scoped to the generated plan response only; Phase 7.5 walks the ledger as a fidelity check before deleting the export. Also states the plan is the sole deliverable (workflow artifacts like the critique are expected).
    static let skillsVersion = 62

    static func render(
        id: RepoPromptWorkflowID,
        variant: WorkflowPromptVariant,
        includeSessionCleanupGuidance: Bool = true
    ) -> String {
        switch id {
        case .build:
            rpBuild(variant: variant)
        case .investigate:
            rpInvestigate(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        case .deepPlan:
            rpDeepPlan(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        case .reminder:
            rpReminder(variant: variant)
        case .oracleExport:
            rpOracleExport(variant: variant)
        case .review:
            rpReview(variant: variant)
        case .refactor:
            rpRefactor(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        case .orchestrate:
            rpOrchestrate(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        case .optimize:
            rpOptimize(variant: variant, includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        }
    }

    // MARK: - Frontmatter Helpers

    /// Generates YAML frontmatter with embedded version markers for RepoPrompt-managed skills.
    /// - Parameters:
    ///   - name: The skill name (becomes the /slash-command)
    ///   - description: The skill description
    ///   - variant: The tool variant (mcp or cli)
    /// - Returns: Complete YAML frontmatter block including version markers
    static func codexSkillAgentPolicy(forSkillNamed name: String, variant: WorkflowPromptVariant) -> String {
        // Only the MCP variant of `rp-reminder` is implicitly invokable. The CLI variant
        // (`rp-reminder-cli`) must be invoked explicitly, matching every other skill.
        let implicitlyInvokableSkills: Set = ["rp-reminder"]
        let allowImplicitInvocation = variant != .cli && implicitlyInvokableSkills.contains(name)
        return "policy:\n  allow_implicit_invocation: \(allowImplicitInvocation ? "true" : "false")"
    }

    static func yamlQuotedScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    static func frontmatter(name: String, description: String, variant: WorkflowPromptVariant) -> String {
        """
        ---
        name: \(yamlQuotedScalar(name))
        description: \(yamlQuotedScalar(description))
        repoprompt_managed: true
        repoprompt_skills_version: \(skillsVersion)
        repoprompt_variant: \(variant.frontmatterVariantName)
        ---
        """
    }

    /// Strips YAML frontmatter (content between --- markers at the start).
    static func stripYAMLFrontmatter(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return content
        }

        var endIndex = 1
        while endIndex < lines.count {
            if lines[endIndex].trimmingCharacters(in: .whitespaces) == "---" {
                let remaining = lines.dropFirst(endIndex + 1)
                return remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            endIndex += 1
        }

        return content
    }
}
