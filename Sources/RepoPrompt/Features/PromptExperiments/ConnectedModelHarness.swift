#if DEBUG
    import Foundation

    extension PromptSuiteCase {
        /// The user message production would send for this case: the frozen file map and file
        /// contents packaged by the production `PromptPackagingService`/`AIMessage` builders with
        /// the case input wrapped in `<user_instructions>`, in the default section order.
        var packagedUserMessage: String {
            let message = PromptPackagingService.buildAIMessage(
                systemPrompt: "",
                metaInstructions: [],
                fileTree: PromptPackagingService.combinedFileMapContent(
                    fileTreeContent: context?.fileTree,
                    codemapBlocks: []
                ) ?? "",
                fileContents: (context?.files ?? []).map {
                    PromptPackagingService.fullFileBlock(path: $0.path, content: $0.content)
                },
                conversation: [ConversationEntry(role: .user, content: input)],
                temperature: nil,
                promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
                disabledPromptSections: []
            )
            return message.packagedFinalUserMessage ?? input
        }
    }

    /// Prompt-only harness: renders the candidate as the built-in prompt's system prompt,
    /// sends the case packaged like a production Oracle request (file map, file contents,
    /// `<user_instructions>`) as the user message to a tool-free connected model, and grades
    /// the answer with the suite grader.
    @MainActor
    final class ConnectedModelHarness: PromptHarness {
        static let maximumOutputExcerptCharacters = 8 * 1024

        private let promptID: BuiltInPromptID
        private let executionTarget: PromptExperimentResolvedTarget
        private let registry: BuiltInPromptRegistry
        private let invoker: PromptExperimentModelInvoker
        let grader: PromptExperimentGrader
        private let checkpoint: PromptExperimentCheckpointSink
        private let progress: @MainActor @Sendable (String) async -> Void
        private let uptime: @Sendable () -> TimeInterval

        init(
            promptID: BuiltInPromptID,
            executionTarget: PromptExperimentResolvedTarget,
            registry: BuiltInPromptRegistry,
            invoker: PromptExperimentModelInvoker,
            grader: PromptExperimentGrader,
            checkpoint: @escaping PromptExperimentCheckpointSink,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.promptID = promptID
            self.executionTarget = executionTarget
            self.registry = registry
            self.invoker = invoker
            self.grader = grader
            self.checkpoint = checkpoint
            self.progress = progress
            self.uptime = uptime
        }

        /// The exact system prompt a candidate is evaluated under: the registry renders it as a
        /// per-evaluation override and the production Oracle composition adds the fixed
        /// suffixes, so the candidate is measured in the bytes production would send.
        static func renderSystemPrompt(
            candidate: String,
            promptID: BuiltInPromptID,
            registry: BuiltInPromptRegistry
        ) throws -> String {
            let rendered = try registry.render(promptID, override: BuiltInPromptOverride(promptID: promptID, text: candidate))
            return OracleSystemPromptRenderer.render(promptID, body: rendered.text)
        }

        func evaluate(
            candidate: String,
            example: PromptSuiteCase,
            evaluationID: UUID
        ) async throws -> PromptHarnessOutcome {
            let started = uptime()
            let systemPrompt = try Self.renderSystemPrompt(candidate: candidate, promptID: promptID, registry: registry)
            await progress("Evaluating a candidate on suite case \(example.id).")
            let output: String
            do {
                output = try await invoker.invoke(
                    target: executionTarget,
                    role: "execution",
                    systemPrompt: systemPrompt,
                    userPrompt: example.packagedUserMessage,
                    onRetry: { [progress] retry, code, delay in
                        await progress("Retrying the target call after \(code.rawValue) (retry \(retry)) in \(String(format: "%.1f", delay))s.")
                    }
                ).output
            } catch let failure as PromptExperimentProviderFailure where failure.code == .toolViolation {
                // The candidate steered a tool-free target into a tool call: a candidate outcome.
                let feedback = "The candidate caused the target to request a disabled tool. Prompt-only targets must answer directly."
                return PromptHarnessOutcome(
                    score: grader.minimumScore,
                    proposerFeedback: example.split.proposerFacingFeedback(feedback),
                    output: "",
                    failureKind: .candidate,
                    elapsedSeconds: max(0, uptime() - started)
                )
            }
            let grade = try await grader.grade(
                example: example,
                candidate: candidate,
                output: output,
                gradingID: evaluationID,
                invoker: invoker,
                checkpoint: checkpoint,
                progress: progress
            )
            return PromptHarnessOutcome(
                score: grade.score,
                proposerFeedback: grade.proposerFeedback,
                output: output,
                failureKind: nil,
                elapsedSeconds: max(0, uptime() - started)
            )
        }
    }
#endif
