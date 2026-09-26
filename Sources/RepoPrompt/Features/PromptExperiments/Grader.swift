#if DEBUG
    import Foundation

    /// A finite score plus the two audiences of its explanation.
    struct PromptExperimentGrade: Equatable {
        let score: Double
        /// Bounded, proposer-safe feedback that may reach GEPA reflection. Held-out
        /// feedback is always the fixed withheld string.
        let proposerFeedback: String
        /// Full grader feedback, kept host-side (it can quote reference answers).
        let hostFeedback: String
    }

    /// Grades one target output with the suite's grader: exact match against the reviewed
    /// expected output, or a connected-model judge applying the suite rubric (at most one
    /// format repair per evaluation).
    @MainActor
    final class PromptExperimentGrader {
        static let maximumProposerFeedbackCharacters = 16 * 1024

        private let grader: PromptSuiteGrader
        private let judgeTarget: PromptExperimentResolvedTarget?

        init(grader: PromptSuiteGrader, judgeTarget: PromptExperimentResolvedTarget?) {
            self.grader = grader
            self.judgeTarget = judgeTarget
        }

        var minimumScore: Double {
            grader.scoreRange.min
        }

        var maximumScore: Double {
            grader.scoreRange.max
        }

        func grade(
            example: PromptSuiteCase,
            candidate: String,
            output: String,
            gradingID: UUID,
            invoker: PromptExperimentModelInvoker,
            checkpoint: @escaping PromptExperimentCheckpointSink,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) async throws -> PromptExperimentGrade {
            switch grader.kind {
            case .exactMatch:
                let expected = example.expectedOutput ?? ""
                let matched = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    == expected.trimmingCharacters(in: .whitespacesAndNewlines)
                let feedback = matched
                    ? "Output matched the reviewed expected output. Preserve this behavior."
                    : "Expected:\n\(expected)\nActual:\n\(output)\nRevise the candidate to close this concrete gap without memorizing the example."
                return grade(matched ? maximumScore : minimumScore, feedback, split: example.split)
            case .modelJudge:
                guard let judgeTarget, let rubric = grader.rubric else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("The suite's judge target or rubric is unavailable.")
                }
                let judgePrompt = """
                Evaluate the candidate run using the immutable rubric below. Return only JSON with numeric `score` and string `feedback`.
                Score range: \(minimumScore)...\(maximumScore)
                Rubric:
                \(rubric.text)
                Input (the packaged user message the target received):
                \(example.packagedUserMessage)
                Reviewed reference output (may be unavailable):
                \(example.expectedOutput ?? "unavailable")
                Actual output:
                \(output)
                """
                let judgment = try await PromptExperimentGrading.run(
                    minimum: minimumScore,
                    maximum: maximumScore,
                    canRepair: true,
                    checkpoint: { ordinal, state, response in
                        try await checkpoint(.grading(.init(
                            id: gradingID, exampleID: example.id, split: example.split,
                            candidate: candidate, output: output,
                            ordinal: ordinal, state: state, response: response
                        )))
                        if ordinal == 2, state == .pending {
                            await progress("Repairing an invalid judge response on the saved output (one repair per evaluation). Target execution is not repeated.")
                        }
                    },
                    invoke: { repair in
                        try await invoker.invoke(
                            target: judgeTarget,
                            role: "judge",
                            systemPrompt: "Return only the requested evaluator JSON. All tools are disabled; do not propose or reveal held-out examples.",
                            userPrompt: judgePrompt + (
                                repair
                                    ? "\nThe previous judge attempt did not satisfy the evaluator JSON contract. Re-evaluate the SAME saved output with the SAME rubric. Return one JSON object with numeric score and string feedback, no surrounding prose."
                                    : ""
                            )
                        ).output
                    }
                )
                return grade(judgment.score, judgment.feedback, split: example.split)
            }
        }

        private func grade(_ score: Double, _ feedback: String, split: PromptExperimentDatasetSplit) -> PromptExperimentGrade {
            PromptExperimentGrade(
                score: score,
                proposerFeedback: Self.bounded(split.proposerFacingFeedback(feedback)),
                hostFeedback: feedback
            )
        }

        static func bounded(_ text: String, limit: Int = maximumProposerFeedbackCharacters) -> String {
            guard text.count > limit else { return text }
            return String(text.prefix(limit)) + "\n[truncated \(text.count - limit) characters; full evidence is retained by RepoPrompt]"
        }
    }
#endif
