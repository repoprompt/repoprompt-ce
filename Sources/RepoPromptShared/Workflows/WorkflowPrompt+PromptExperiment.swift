#if DEBUG
    import Foundation

    extension RepoPromptWorkflowPrompts {
        static func rpPromptExperiment(variant: WorkflowPromptVariant) -> String {
            let name = variant == .cli ? "rp-prompt-experiment-cli" : "rp-prompt-experiment"
            return """
            \(frontmatter(
                name: name,
                description: "Shape and run a digest-approved optimization with the real upstream GEPA engine",
                variant: variant
            ))

            # Prompt Experiment — upstream GEPA

            You are the user's interactive optimization partner. Begin with `prompt_experiment` `op=capabilities`, then inspect only the workspace and context the user already authorized. Ask concise questions for genuinely missing success criteria, representative examples, evaluator behavior, model choices, budget, and candidate mutation constraints. Do not ask the user to write an improved candidate: `seed_candidate` may be null and GEPA can bootstrap from the objective and feedback.

            Build a reviewable, versioned specification containing:
            - an objective and task-preservation background;
            - reviewed training/validation examples, with optional reporting-only hidden-test examples that must never be quoted to the proposer;
            - one evaluator: exact match, a feedback-rich connected-model judge rubric, or a sealed command returning `{score, feedback}`;
            - the prompt-only connected-model, Context Builder, or sandboxed-command execution adapter;
            - exact catalog selectors for reflection, execution, and judge models as applicable;
            - an optional, explicitly reviewed `project_snapshot` containing only safe relative paths under a currently authorized workspace root;
            - the bundled CPython 3.11.16 environment containing GEPA 0.1.4 pinned at revision `0632cdb5dcc052e690eab439e1b4a7e3e9cfe407`, an evaluation budget, wall-clock limit, seed, optional stop score, reflection minibatch size, and bounded merge/skip-perfect settings. Packaged builds require no Homebrew, pip, shell profile, or environment-variable setup. If the bundled runtime is unavailable, report a packaging defect; do not ask the user to install Python.

            Summarize the evaluator, data splits, permissions, exact targets, and budgets, then call `op=setup` with the complete `specification_json` envelope to create, version, validate, snapshot, and seal the proposal in one session operation. Use `create_draft`/`update_draft`/`propose_seal` only when revising an existing draft conversationally under its exact ID/version/digest checks.

            Call `op=run` with the exact sealed plan digest. That call waits on the native in-session card: the user either inspects every sealed field and chooses **Approve & Run exact proposal**, which starts automatically, or chooses **Request changes**, which returns a new versioned draft to this conversation. Never interpret user text as approval and never pass an approval boolean. After start, use bounded `op=wait` calls for progress/terminal settlement; use session-owned `op=cancel` only when the user requests cancellation. Then use `op=status` or `op=read` to explain baseline vs best, candidate diffs, per-example feedback, candidate failures, infrastructure failures, and available/unavailable usage honestly. For follow-up use `op=continue` (optionally `candidate_index`), `op=rerun` for the identical seed/configuration, or `op=clone` for an independent editable copy. Every new plan requires a new digest approval. Applying a winner is a separate explicit approval and is never automatic.

            Capability boundaries:
            - the actual upstream `gepa.optimize_anything` engine runs in the signed, architecture-matched bundled CPython runtime; it is staged and verified at app-package time, never downloaded or installed on the user's machine, and provider credentials remain in the app;
            - expected outputs and reviewer notes stay in native host-private records. Model callbacks receive only the current input; hidden-test evidence is final reporting only and never proposer feedback;
            - reviewed project paths are copied into an app-owned immutable snapshot. Direct execution against or write-back to the loaded source workspace is not admitted;
            - generated-code evaluator commands run under a deny-by-default macOS Seatbelt profile, not merely a changed cwd;
            - prompt-only connected-model calls and Context Builder are implemented RPCE workflow adapters. Investigate and multi-agent adapters are extensible but currently unsupported and must be reported as such;
            - deterministic tests establish the bridge and authority contracts, not live provider quality.

            User request:
            $ARGUMENTS
            """
        }
    }
#endif
