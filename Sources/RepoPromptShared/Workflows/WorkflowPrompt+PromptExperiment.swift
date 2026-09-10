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

            The native **Prompt Experiments** view is the sole authority for draft persistence, sealing, approval, execution, cancellation, and revision. You may propose text, but you cannot approve a digest or start trials on the user’s behalf. Approval must be an explicit native UI action bound to the exact sealed digest.

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
