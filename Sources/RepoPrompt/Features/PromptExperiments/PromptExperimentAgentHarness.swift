#if DEBUG
    import Foundation

    /// Real coding-task evaluation of the production Engineer system prompt. Each call
    /// receives a fresh fixture and private MCP profile. Test expectations stay in host
    /// memory, and grading begins only after the agent and its tool processes are stopped.
    @MainActor
    final class PromptExperimentAgentHarness: PromptHarness {
        private let target: PromptExperimentResolvedTarget
        private let evaluationRoot: URL
        private let pythonExecutable: URL?
        private let usesProductionTemplate: Bool
        private let runner: any PromptExperimentAgentTaskRunning
        private let checkerOverride: (any PromptExperimentAgentChecking)?
        private let checkpoint: PromptExperimentCheckpointSink
        private let progress: @MainActor @Sendable (String) async -> Void

        init(
            executionTarget: PromptExperimentResolvedTarget,
            evaluationRoot: URL,
            pythonExecutable: URL? = nil,
            usesProductionTemplate: Bool = true,
            checkpoint: @escaping PromptExperimentCheckpointSink,
            progress: @escaping @MainActor @Sendable (String) async -> Void,
            runner: (any PromptExperimentAgentTaskRunning)? = nil,
            checker: (any PromptExperimentAgentChecking)? = nil
        ) {
            target = executionTarget
            self.evaluationRoot = evaluationRoot.standardizedFileURL.resolvingSymlinksInPath()
            self.pythonExecutable = pythonExecutable
            self.usesProductionTemplate = usesProductionTemplate
            self.checkpoint = checkpoint
            self.progress = progress
            self.runner = runner ?? PromptExperimentConnectedAgentTaskRunner()
            checkerOverride = checker
        }

        static func validate(case example: PromptSuiteCase) throws {
            guard let expected = example.expectedOutput, expected.utf8.count <= 128_000 else {
                throw PromptExperimentAuthorityError.invalidRequest("Engineer tasks require host-owned acceptance JSON in expected_output (at most 128 KB).")
            }
            let acceptance = try PromptExperimentAgentAcceptance.decode(expected)
            guard let files = example.context?.files, !files.isEmpty, files.count <= 128,
                  Set(files.map(\.path)).count == files.count,
                  files.reduce(0, { $0 + $1.content.utf8.count }) <= 2_000_000
            else {
                throw PromptExperimentAuthorityError.invalidRequest("Engineer tasks require 1–128 unique fixture files, totaling at most 2 MB.")
            }
            for file in files {
                try PromptExperimentAgentAcceptance.validateRelativePath(file.path)
            }
            let paths = Set(files.map(\.path))
            guard (acceptance.preserveFiles ?? []).allSatisfy(paths.contains) else {
                throw PromptExperimentAuthorityError.invalidRequest("Every preserve_files entry must name an initial fixture file.")
            }
            // A file cannot also be an ancestor directory of a second fixture.
            for path in paths where paths.contains(where: { $0.hasPrefix(path + "/") }) {
                throw PromptExperimentAuthorityError.invalidRequest("Fixture path \(path) is both a file and a directory.")
            }
        }

        func evaluate(candidate: String, example: PromptSuiteCase, evaluationID: UUID) async throws -> PromptHarnessOutcome {
            let started = ProcessInfo.processInfo.systemUptime
            try Self.validate(case: example)
            let acceptance = try PromptExperimentAgentAcceptance.decode(example.expectedOutput!)
            guard !usesProductionTemplate || AgentModePrompts.isValidEngineerTemplate(candidate) else {
                return outcome(
                    candidate: candidate,
                    example: example,
                    started: started,
                    score: 0,
                    feedback: "The candidate must preserve each {{rpce.*}} production fragment exactly once.",
                    output: "",
                    result: nil,
                    failed: true
                )
            }
            try runner.preflight(target: target)
            let checker: any PromptExperimentAgentChecking
            if let checkerOverride {
                checker = checkerOverride
            } else {
                let python = try pythonExecutable ?? PromptExperimentGEPAWorker.resolvePythonExecutable(
                    sealedValue: PromptExperimentGEPAWorker.configuredPythonSealValue()
                )
                checker = PromptExperimentPythonAcceptanceRunner(python: python)
            }
            try await checker.preflight()
            try Task.checkCancellation()

            // A UUID workspace is never reused, including interrupted or resumed evaluations.
            let root = evaluationRoot.appendingPathComponent(evaluationID.uuidString.lowercased(), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("An Engineer evaluation directory already exists. Refusing to reuse task state.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = root.appendingPathComponent("workspace", isDirectory: true)
            let profile = root.appendingPathComponent("profile", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for file in example.context?.files ?? [] {
                let url = workspace.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(file.content.utf8).write(to: url, options: .withoutOverwriting)
            }
            let system = usesProductionTemplate
                ? AgentModePrompts.engineerPrompt(agentKind: AgentProviderKind(rawValue: target.agentRaw), body: candidate)
                : candidate
            let task = """
            \(example.input)

            Task workspace: \(workspace.path)
            This task exposes only the RepoPrompt file exploration and editing tools. Complete the requested edits in this workspace.
            Acceptance checks run separately after you finish. Do not request other agents, Oracle calls, a shell, or interaction with the user.
            """
            await progress("Running Engineer task \(example.id) in an isolated workspace (up to \(acceptance.maximumTurns) turns).")
            let callID = UUID()
            try await checkpoint(.modelCall(.init(
                id: callID, target: target, role: "execution_agent", state: .started, promptTokens: nil, completionTokens: nil
            )))
            let result: PromptExperimentAgentTaskResult
            do {
                result = try await runBounded(
                    systemPrompt: system, task: task, workspace: workspace, profile: profile,
                    maximumTurns: acceptance.maximumTurns, timeout: acceptance.duration
                )
                try await checkpoint(.modelCall(.init(
                    id: callID, target: target, role: "execution_agent", state: .completed,
                    promptTokens: result.promptTokens, completionTokens: result.completionTokens
                )))
            } catch {
                try? await checkpoint(.modelCall(.init(
                    id: callID, target: target, role: "execution_agent", state: .failed, promptTokens: nil, completionTokens: nil
                )))
                if error is CancellationError { throw CancellationError() }
                if (error as? PromptExperimentProviderFailure)?.code == .timedOut {
                    return outcome(
                        candidate: candidate,
                        example: example,
                        started: started,
                        score: 0,
                        feedback: "The agent exceeded the approved task deadline or tool-call bound.",
                        output: "",
                        result: nil,
                        failed: true
                    )
                }
                throw error
            }
            try Task.checkCancellation()
            await progress("Checking the edited files for Engineer task \(example.id).")
            var results: [PromptExperimentAgentCheckResult] = []
            for check in acceptance.checks {
                try Task.checkCancellation()
                let remaining = acceptance.duration - (ProcessInfo.processInfo.systemUptime - started)
                guard remaining > 0 else {
                    results.append(.init(passed: false, feedback: "\(check.id): task deadline exhausted."))
                    continue
                }
                try await results.append(checker.check(check, workspace: workspace, timeout: remaining))
            }
            for path in acceptance.preserveFiles ?? [] {
                let file = workspace.appendingPathComponent(path)
                let original = example.context?.files.first(where: { $0.path == path })?.content
                let regular = (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
                let observed = regular?.isRegularFile == true && regular?.isSymbolicLink != true
                    && file.resolvingSymlinksInPath().path.hasPrefix(workspace.path + "/")
                    ? try? String(contentsOf: file, encoding: .utf8) : nil
                let passed = original != nil && observed == original
                results.append(.init(passed: passed, feedback: "\(path): \(passed ? "preserved" : "unrequested change")."))
            }
            let score = Double(results.filter(\.passed).count) / Double(results.count)
            let feedback = results.map(\.feedback).joined(separator: "\n")
            let evidence = """
            Agent answer:
            \(result.output)

            Tool calls: \(result.toolCalls)
            \(result.transcript)

            Acceptance:
            \(feedback)
            """
            return outcome(
                candidate: candidate,
                example: example,
                started: started,
                score: score,
                feedback: feedback,
                output: evidence,
                result: result,
                failed: false
            )
        }

        private func runBounded(
            systemPrompt: String, task: String, workspace: URL, profile: URL, maximumTurns: Int, timeout: TimeInterval
        ) async throws -> PromptExperimentAgentTaskResult {
            try await withThrowingTaskGroup(of: PromptExperimentAgentTaskResult.self) { group in
                group.addTask { @MainActor [runner, target] in
                    try await runner.run(
                        target: target,
                        systemPrompt: systemPrompt,
                        task: task,
                        workspace: workspace,
                        profile: profile,
                        maximumTurns: maximumTurns,
                        timeout: timeout
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw PromptExperimentProviderFailure(code: .timedOut)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        }

        private func outcome(
            candidate: String, example: PromptSuiteCase, started: TimeInterval, score: Double,
            feedback: String, output: String, result: PromptExperimentAgentTaskResult?, failed: Bool
        ) -> PromptHarnessOutcome {
            PromptHarnessOutcome(
                score: score, proposerFeedback: example.split.proposerFacingFeedback(feedback),
                output: output, failureKind: failed ? .candidate : nil,
                elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started),
                usage: .init(
                    promptCharacters: candidate.count,
                    outputCharacters: result?.output.count ?? 0,
                    promptTokens: result?.promptTokens,
                    completionTokens: result?.completionTokens,
                    cachedInputTokens: result?.cachedInputTokens,
                    cacheCreationInputTokens: result?.cacheCreationInputTokens,
                    reportedCost: result?.reportedCost,
                    measurementVersion: 1
                )
            )
        }
    }
#endif
