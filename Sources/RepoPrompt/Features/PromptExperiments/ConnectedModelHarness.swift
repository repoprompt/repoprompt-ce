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
        /// Proposer excerpts keep the start and the end of an answer (later sections such as
        /// risks and tests are where plans usually fall short) with an explicit omission marker.
        static let outputExcerptHeadCharacters = 3 * 1024
        static let outputExcerptTailCharacters = 3 * 1024

        static func outputExcerpt(_ output: String) -> String {
            let head = outputExcerptHeadCharacters
            let tail = outputExcerptTailCharacters
            guard output.count > head + tail else { return output }
            let omitted = output.count - head - tail
            return "\(output.prefix(head))\n\n[… \(omitted) characters omitted from the middle of this output; RepoPrompt retains the full text …]\n\n\(output.suffix(tail))"
        }

        private let promptID: BuiltInPromptID?
        private let executionTarget: PromptExperimentResolvedTarget
        private let registry: BuiltInPromptRegistry
        private let invoker: PromptExperimentModelInvoker
        let grader: PromptExperimentGrader
        private let checkpoint: PromptExperimentCheckpointSink
        private let progress: @MainActor @Sendable (String) async -> Void
        private let definition: PromptLabDefinition?
        private let uptime: @Sendable () -> TimeInterval

        init(
            promptID: BuiltInPromptID?,
            executionTarget: PromptExperimentResolvedTarget,
            registry: BuiltInPromptRegistry,
            invoker: PromptExperimentModelInvoker,
            grader: PromptExperimentGrader,
            checkpoint: @escaping PromptExperimentCheckpointSink,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            definition: PromptLabDefinition? = nil
        ) {
            self.promptID = promptID
            self.executionTarget = executionTarget
            self.registry = registry
            self.invoker = invoker
            self.grader = grader
            self.checkpoint = checkpoint
            self.progress = progress
            self.uptime = uptime
            self.definition = definition
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
            let systemPrompt: String
            let userPrompt: String
            if definition?.runner == .plainPrompt || promptID == nil {
                if let definition, PromptLabTemplate.variables(in: candidate) != PromptLabTemplate.variables(in: definition.source.prompt) {
                    return PromptHarnessOutcome(score: grader.minimumScore, proposerFeedback: "Preserve the starting prompt's template variable names.", output: "", failureKind: .candidate, elapsedSeconds: 0)
                }
                var variables = example.variables
                variables["input"] = variables["input"] ?? example.input
                systemPrompt = try PromptLabTemplate.render(candidate, variables: variables)
                let renderedInput = try PromptLabTemplate.render(example.input, variables: variables)
                if example.context == nil {
                    userPrompt = renderedInput
                } else {
                    userPrompt = PromptSuiteCase(
                        id: example.id, split: example.split, input: renderedInput,
                        expectedOutput: nil, context: example.context
                    ).packagedUserMessage
                }
            } else if let promptID {
                systemPrompt = try Self.renderSystemPrompt(candidate: candidate, promptID: promptID, registry: registry)
                userPrompt = example.packagedUserMessage
            } else {
                throw PromptExperimentAuthorityError.invalidRequest("The experiment has no task renderer.")
            }
            await progress("Evaluating a candidate on suite case \(example.id).")
            let output: String
            let usage: PromptExperimentEvaluationUsage
            do {
                let completion = try await invoker.invoke(
                    target: executionTarget,
                    role: "execution",
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    onRetry: { [progress] retry, code, delay in
                        await progress("Retrying the target call after \(code.rawValue) (retry \(retry)) in \(String(format: "%.1f", delay))s.")
                    }
                )
                output = completion.output
                usage = PromptExperimentEvaluationUsage(
                    promptCharacters: candidate.count,
                    outputCharacters: output.count,
                    promptTokens: completion.promptTokens,
                    completionTokens: completion.completionTokens,
                    cachedInputTokens: completion.cachedInputTokens,
                    cacheCreationInputTokens: completion.cacheCreationInputTokens,
                    reportedCost: completion.cost,
                    measurementVersion: 1
                )
            } catch let failure as PromptExperimentProviderFailure where failure.code == .toolViolation {
                // The candidate steered a tool-free target into a tool call: a candidate outcome.
                let feedback = "The candidate caused the target to request a disabled tool. Prompt-only targets must answer directly."
                return PromptHarnessOutcome(
                    score: grader.minimumScore,
                    proposerFeedback: example.split.proposerFacingFeedback(feedback),
                    output: "",
                    failureKind: .candidate,
                    elapsedSeconds: max(0, uptime() - started),
                    usage: PromptExperimentEvaluationUsage(
                        promptCharacters: candidate.count, outputCharacters: 0, promptTokens: nil, completionTokens: nil
                    )
                )
            }
            let grade = try await grader.grade(
                example: example,
                candidate: candidate,
                output: output,
                gradingID: evaluationID,
                invoker: invoker,
                checkpoint: checkpoint,
                progress: progress,
                renderedInput: userPrompt
            )
            return PromptHarnessOutcome(
                score: grade.score,
                proposerFeedback: grade.proposerFeedback,
                output: output,
                failureKind: nil,
                elapsedSeconds: max(0, uptime() - started),
                usage: usage
            )
        }
    }
#endif
