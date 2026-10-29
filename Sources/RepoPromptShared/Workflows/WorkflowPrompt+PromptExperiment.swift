#if DEBUG
    import Foundation

    extension RepoPromptWorkflowPrompts {
        static func rpPromptExperiment(variant: WorkflowPromptVariant) -> String {
            let name = variant == .cli ? "rp-prompt-experiment-cli" : "rp-prompt-experiment"
            return """
            \(frontmatter(
                name: name,
                description: "Improve an RPCE prompt, project prompt, template or AI program with examples and measured results",
                variant: variant
            ))

            # Improve a Prompt

            Help the user improve a prompt or AI program through RepoPrompt's experiment lab. The user should only need to explain what the prompt does, what should improve, and what good results look like. You handle the experiment definition; do not ask them to learn GEPA or write JSON. Use `prompt_experiment` as the experiment authority. Do not run an independent optimizer or treat chat text as approval for the native run.

            ## Start from the user's actual task

            Call `op=targets` to discover built-in prompts, task runners and connected models. Choose the source that matches the request:

            - RPCE Oracle or Engineer prompt: use its actual built-in ID and production task runner. Selecting an execution model called `engineer` is not the same thing as evaluating the Engineer prompt.
            - A project's prompt file: use an absolute `prompt_file` path. For a prompt embedded in source, supply one exact unique static string literal or its complete contents as `selection`. Preserve the returned source encoding metadata; application re-encodes the decoded prompt and checks the original file hash. If dynamic source cannot be mapped, optimize its resolved prompt as pasted text and export it for manual integration.
            - Prompt text or a template: use `prompt_text`, with an optional `source_title`. Cases can supply values for `{{variable}}` placeholders.
            - A Python or DSPy application: inspect the user's intended evaluator and environment, then use `op=describe_program` with `program` and runner `program` or `dspy`. This explicitly executes the selected local module to read its experiment description. It must exercise the real application, including its metrics and usage reporting.

            For a text task, use `op=prepare` with the source, a plain-language `goal`, any representative `example_inputs`, optional `criteria`, and a reflection model if the default is unsuitable. Preparation makes one bounded model call and returns a complete editable `definition`; it does not start optimization. Prefer real user examples. Clearly identify generated examples as synthetic and check them for incorrect assumptions or invented facts.

            ## Review the definition

            Explain the proposed examples and success checks in normal language. The definition needs examples used to improve the prompt (`training`), examples used to compare candidates (`validation`), and final-check examples withheld from reflection (`hidden_test`). These small sets provide exploratory evidence, not a guarantee of general quality.

            Preserve frozen context, variables, private references and built-in task acceptance checks. Do not put expected answers or private tests in the model's task input. For an Engineer experiment, tasks run in fresh isolated file fixtures with the production Engineer renderer, read/edit tools and private acceptance checks. Shell, web and delegation are disabled in this evaluated tool profile.

            For programs, preserve the inspected source/dependency hashes and model routing. `project` routing uses the project's configured model client and settings; do not replace it with a connected model to simplify the experiment. Reported efficiency requires complete measured usage from that evaluator. Environment configuration contains variable names only, never secret values. If discovery returns an empty starting prompt, fill it from the user's actual prompt before creating the experiment.

            Set `objective.mode=quality` for quality first, or `efficiency` for fewer reported tokens subject to the user's accepted `qualityTolerance`. A shorter prompt or a shorter answer alone does not demonstrate token savings. `inputWeight` and `outputWeight` express the user's relative priorities, not provider prices.

            Use server model defaults when suitable. Reflection proposes changes; judging evaluates answers. A distinct judge is preferable, but a generic experiment can use the same model with that limitation disclosed. Program and Engineer runners use their task acceptance scores rather than a text-only judge.

            ## Run through native approval

            1. Call `op=create_or_update` with the reviewed `definition`, optional title/model selectors, and a small search cap such as `max_evaluations=25`. Existing built-in shortcuts using `prompt_id` remain available. Nested definition fields use the camelCase names returned by prepare/describe_program. Fix all field errors reported by the tool.
            2. Explain the full maximum from the returned authority: search plus separate baseline calibration, and the independent `max_provider_invocations` limit. An evaluation runs one example; judging, reflection, repairs and retries consume provider sessions. Agent turns are additionally bounded within each session. These limits are not token or dollar caps. A program's own client calls are outside RPCE's session ledger; its evaluator remains bounded by the approved time and evaluation limits.
            3. Call `op=request_approval` with the experiment UUID and returned `authority_digest`. Direct the user to the native card or Window → Prompt Experiments. Only native approval starts the optimization.
            4. Follow approval and progress with `op=status_or_wait`. Use `op=cancel` when the user wants to stop. Resume an already approved experiment with `op=run` only within its remaining allowance. Changing source, goal, examples, checks, models, program or budget produces different authority and needs a new approval.

            Users can use New Experiment in the native window for this same flow: choose a source, describe the goal, generate or enter examples, review checks, and approve. Creating or reviewing a draft makes no model calls; Generate examples and Load program are explicit preparation actions.

            ## Decide from the evidence

            When a run ends, inspect baseline and candidate performance on matching examples, actual outputs or file-task results, final-check regressions, reported usage and missing evidence. A budget stop still returns the saved incumbent. No improvement found is a valid result; do not rewrite the default by hand and call that optimization.

            Report token reductions only from the paired comparison, naming its example group and reporting coverage. Do not compare unpaired candidate averages or infer missing tokens from character counts. A difference exceeding the observed baseline spread remains an exploratory comparison, not statistical confidence. A synthetic starter suite or one task configuration does not establish broad application quality.

            For a retained candidate, `op=propose_patch` prepares a source diff for native review. The user can apply or reject it there; the tool cannot apply it. Pasted prompts can be copied or saved from Studio. Use `op=export` with `experiment_id`, `run_id` and an absolute `output_path` to save the frozen definition, results and inline evidence in one JSON file. Applying a built-in source change requires rebuilding before the running app uses that new default. Never claim a result was applied, saved, faster, cheaper or better unless the corresponding action or measurements actually support it.

            User request:
            $ARGUMENTS
            """
        }
    }
#endif
