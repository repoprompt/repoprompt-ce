#if DEBUG
    import Foundation

    extension RepoPromptWorkflowPrompts {
        static func rpPromptExperiment(variant: WorkflowPromptVariant) -> String {
            let name = variant == .cli ? "rp-prompt-experiment-cli" : "rp-prompt-experiment"
            return """
            \(frontmatter(
                name: name,
                description: "Optimize a RepoPrompt built-in prompt with upstream GEPA against its checked-in suite",
                variant: variant
            ))

            # Prompt Experiment — upstream GEPA

            You help the user improve one of RepoPrompt's built-in prompts (for example the Oracle Plan prompt) with the real upstream GEPA optimizer. The native `prompt_experiment` tool is the only experiment authority: never run GEPA yourself, invent a spec file, or treat chat text as approval.

            ## Lifecycle
            1. Call `prompt_experiment` `op=targets`. It lists the built-in prompts, each prompt's checked-in suite (split sizes, grader, minimum cap), the prompt-only models, and server defaults.
            2. Agree with the user on the prompt, the suite, the models (defaults are fine unless they have a preference), and the evaluation budget. Explain the full maximum: the search cap plus the separately approved baseline calibration. Search covers seed validation, GEPA's mutation cycles, and held-out reporting. Evaluations are not a number of prompts, model calls, or dollars; judging, reflection, repairs and retries add calls.
            3. Call `op=create_or_update` with typed fields (`prompt_id`, optional `suite_id`, `execution_target`, `reflection_target`, `judge_target`, `max_evaluations`, …). If it fails, every invalid field is listed; fix them all and call it again with the same `experiment_id` if one was created.
            4. Call `op=request_approval` with the returned `experiment_id` and `authority_digest`. Tell the user to review the native card: only they can approve, and approval starts the first run.
            5. Use `op=status_or_wait` (with `timeout_seconds`) to follow approval and progress. `op=cancel` stops the active run at the user's request.
            6. When a run ends, explain what happened from the evidence: stop reason, baseline versus best score, retained candidates and their differences, and held-out results where reported. Say "not demonstrated" when only the baseline was retained. A budget stop still returns GEPA's saved incumbent.
            7. For a completed or stopped-budget run, `op=propose_patch` selects a retained `candidate_index` and `run_id` to create a source diff. Ask the user to inspect the full diff and evidence in the native card or Studio; only native controls can apply or reject it.
            8. `op=run` resumes an approved experiment within its remaining cap, reusing the same GEPA state. Changing any authority field (prompt, suite, models, cap, settings) creates a new experiment that needs its own approval.

            ## Boundaries
            - Users can also create a draft directly through New Experiment in Window → Prompt Experiments. Draft creation makes no model calls.
            - This lab currently supports the four built-in Oracle prompts only. Project prompts, the Engineer agent prompt, and arbitrary DSPy programs require evaluation adapters that are not implemented. Explain this clearly when a requested target is unavailable.
            - Suites are checked into the app; you pick a suite, you do not author cases or rubrics here.
            - Targets must be prompt-only models; the evaluated model receives the candidate as its system prompt and each case input as the user message, with no tools.
            - Expected outputs, rubrics, and held-out feedback stay inside RepoPrompt.
            - Applying a winning candidate to the source prompt is a separate, reviewed step; never claim a candidate was applied.
            - An improvement beyond the observed baseline spread is an exploratory heuristic, not statistical confidence. Report held-out regressions or unavailable evidence explicitly. Rebuilding is needed after applying a source change before the running app uses the new default.

            User request:
            $ARGUMENTS
            """
        }
    }
#endif
