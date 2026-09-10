#if DEBUG
    import Foundation

    extension RepoPromptWorkflowPrompts {
        static func rpPromptExperiment(variant: WorkflowPromptVariant) -> String {
            let name = variant == .cli ? "rp-prompt-experiment-cli" : "rp-prompt-experiment"
            return """
            \(frontmatter(
                name: name,
                description: "Shape a native, explicitly approved Prompt Experiment draft for a fixed synthetic-fixture comparison",
                variant: variant
            ))

            # Native Prompt Experiment pilot

            Help the user articulate a fixed original-versus-candidate Context Builder comparison. Ask only for missing task, synthetic fixture, original instructions, candidate instructions, target role, and one-to-three repetitions.

            Start by calling `prompt_experiment` with `op=capabilities`. Use its bounded operations to create or update the draft owned by this Agent session, then call `op=propose_seal` with the exact returned draft ID, version, and digest. Tell the user to open the native **Prompt Experiments** flask view and approve the exact plan digest shown by the tool and card.

            The agent tool can persist drafts, seal a proposal, read results, and propose a next revision. It has no approve, run, cancel, score, or promote operation. Approval and execution remain explicit native UI actions bound to the exact sealed digest.

            Pilot boundaries:
            - synthetic-fixture-only isolated execution; loaded-workspace experiments are unsupported;
            - fixed, serial Context Builder trials using an existing catalog-resolved provider path;
            - no Investigate workflow, multi-agent optimizer, GEPA attachment, semantic judge, or automatic promotion;
            - no claim that controlled trials prove live provider quality.

            User request:
            $ARGUMENTS
            """
        }
    }
#endif
