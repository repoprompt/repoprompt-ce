#if DEBUG
    import CoreFoundation
    import Darwin
    import Foundation

    /// Runs an explicitly selected project evaluator. The project interpreter owns its
    /// dependencies; model callbacks stay in RPCE and are bounded and recorded by the invoker.
    @MainActor
    final class PromptLabProgramHarness: PromptHarness {
        private let definition: PromptLabDefinition
        private let targets: PromptExperimentTargets
        private let invoker: PromptExperimentModelInvoker
        private let progress: @MainActor @Sendable (String) async -> Void

        init(
            definition: PromptLabDefinition,
            targets: PromptExperimentTargets,
            invoker: PromptExperimentModelInvoker,
            progress: @escaping @MainActor @Sendable (String) async -> Void
        ) throws {
            guard definition.program != nil else { throw PromptExperimentAuthorityError.invalidRequest("Select a project evaluator.") }
            self.definition = definition
            self.targets = targets
            self.invoker = invoker
            self.progress = progress
        }

        func evaluate(candidate: String, example: PromptSuiteCase, evaluationID _: UUID) async throws -> PromptHarnessOutcome {
            let start = ProcessInfo.processInfo.systemUptime
            var encodedExample = example.payload?.mapValues(\.foundationValue) ?? [:]
            encodedExample["id"] = example.id
            encodedExample["split"] = example.split.rawValue
            if encodedExample["input"] == nil || encodedExample["input"] is String { encodedExample["input"] = example.input }
            if let reference = example.expectedOutput { encodedExample["expectedOutput"] = reference
                encodedExample["expected_output"] = reference
            } else {
                for key in ["expectedOutput", "expected_output"] where encodedExample[key] is String {
                    encodedExample.removeValue(forKey: key)
                }
            }
            if !example.variables.isEmpty || encodedExample["variables"] != nil { encodedExample["variables"] = example.variables }
            if let context = example.context { encodedExample["context"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) }
            var callbacks = 0
            await progress("Evaluating project case \(example.id) with \(definition.runner.rawValue).")
            let result = try await Self.run(definition: definition, operation: nil, request: [
                "protocol_version": 1, "type": "evaluate", "candidate": candidate, "example": encodedExample
            ]) { [self] payload in
                callbacks += 1
                guard callbacks <= 40 else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("The project evaluation exceeded 40 model calls.")
                }
                guard let messages = payload["messages"] as? [[String: Any]],
                      let role = payload["role"] as? String, ["execution", "judge"].contains(role)
                else { throw PromptExperimentAuthorityError.invalidRequest("The project requested an unsupported model callback.") }
                if let settings = payload["settings"] as? [String: Any], !settings.isEmpty {
                    throw PromptExperimentAuthorityError.invalidRequest("The connected CLI uses the selected RPCE model and effort. For custom temperature, sampling or token limits, use the project's API client in evaluate().")
                }
                let system = messages.filter { ($0["role"] as? String) == "system" || ($0["role"] as? String) == "developer" }
                let conversation = messages.filter { !["system", "developer"].contains($0["role"] as? String ?? "") }
                guard conversation.count == 1, conversation[0]["role"] as? String == "user",
                      let user = conversation[0]["content"] as? String,
                      system.allSatisfy({ $0["content"] is String })
                else {
                    throw PromptExperimentAuthorityError.invalidRequest("The connected CLI callback requires one user message. For conversational/few-shot programs, use the project's model client in evaluate() so message roles are preserved.")
                }
                let completion = try await invoker.invoke(
                    target: selectedTarget(role: role),
                    role: "program_\(role)", systemPrompt: system.compactMap { $0["content"] as? String }.joined(separator: "\n\n"), userPrompt: user
                )
                var reply: [String: Any] = ["status": "ok", "output": completion.output, "settings_policy": "selected_rpce_model"]
                if let tokens = completion.promptTokens { reply["prompt_tokens"] = tokens }
                if let tokens = completion.completionTokens { reply["completion_tokens"] = tokens }
                return reply
            }
            guard let score = result["score"] as? Double, score.isFinite, (0 ... 1).contains(score),
                  let feedback = result["feedback"] as? String, let output = result["output"] as? String
            else { throw PromptExperimentAuthorityError.runtimeUnavailable("The project evaluator must return a finite score from 0 to 1, feedback and output.") }
            return PromptHarnessOutcome(
                score: score, proposerFeedback: example.split.proposerFacingFeedback(feedback), output: output,
                failureKind: result["candidate_valid"] as? Bool == false ? .candidate : nil, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                usage: .init(
                    promptCharacters: candidate.count,
                    outputCharacters: output.count,
                    promptTokens: Self.tokens(result["prompt_tokens"]),
                    completionTokens: Self.tokens(result["completion_tokens"]),
                    measurementVersion: 1
                )
            )
        }

        private func selectedTarget(role: String) throws -> PromptExperimentResolvedTarget {
            if role == "execution" { return targets.execution }
            guard let judge = targets.judge else { throw PromptExperimentAuthorityError.targetUnavailable("Select a judge model for this program's metric callbacks.") }
            return judge
        }

        private static func tokens(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue
            else { return nil }
            return number.intValue
        }

        static func preflight(definition: PromptLabDefinition) async throws {
            let metadata = try await run(definition: definition, operation: "--validate", request: [
                "protocol_version": 1, "type": "validate", "candidate": definition.source.prompt
            ])
            if let routing = definition.program?.modelRouting, metadata["model_routing"] as? String != routing.rawValue {
                throw PromptExperimentAuthorityError.invalidRequest("The project's model routing changed. Reload its description and review a new experiment.")
            }
        }

        static func describe(program: PromptLabProgram, runner: PromptLabRunnerKind) async throws -> [String: Any] {
            let definition = PromptLabDefinition(
                source: .init(kind: .pasted, title: "Program", prompt: "inspect"),
                goal: "Inspect program",
                runner: runner,
                examples: [],
                criteria: "",
                program: program
            )
            return try await run(definition: definition, operation: "--describe", request: nil)
        }

        static func export(definition: PromptLabDefinition, candidate: String) async throws -> [String: Any] {
            try await run(definition: definition, operation: "--export", request: ["protocol_version": 1, "type": "export", "candidate": candidate])
        }

        private static func run(
            definition: PromptLabDefinition, operation: String?, request: [String: Any]?,
            callback: (@MainActor ([String: Any]) async throws -> [String: Any])? = nil
        ) async throws -> [String: Any] {
            guard let program = try definition.program?.sealed() else {
                throw PromptExperimentAuthorityError.invalidRequest("The experiment has no project evaluator.")
            }
            let runner = try PromptExperimentGEPAWorker.resolveWorkerURL().deletingLastPathComponent().appendingPathComponent("prompt_program_runner.py")
            guard FileManager.default.isReadableFile(atPath: runner.path) else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The packaged project-program runner is missing. Rebuild the app.")
            }
            let session = try PromptLabProgramProcess(program: program, runner: runner, adapter: definition.runner == .dspy ? "dspy" : "python", operation: operation)
            defer { session.dispose() }
            try session.process.run()
            if let request { try session.write(request) }
            let raw = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { @MainActor in
                        var terminal: String?
                        for try await line in session.output.fileHandleForReading.bytes.lines {
                            try Task.checkCancellation()
                            guard line.utf8.count <= 8_000_000,
                                  let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                  object["protocol_version"] as? Int == 1, let type = object["type"] as? String
                            else { throw PromptExperimentAuthorityError.runtimeUnavailable("The program runner emitted invalid protocol data.") }
                            if type == "host_request" {
                                guard terminal == nil, let callback, let id = object["id"] as? String,
                                      object["operation"] as? String == "complete", let payload = object["payload"] as? [String: Any]
                                else { throw PromptExperimentAuthorityError.runtimeUnavailable("The program requested a model call outside evaluation.") }
                                var reply = try await callback(payload)
                                reply["protocol_version"] = 1
                                reply["type"] = "host_response"
                                reply["id"] = id
                                try session.write(reply)
                            } else if type == "failed" {
                                let code = object["failure_code"] as? String ?? "unknown"
                                let exception = object["exception_type"] as? String ?? "unknown"
                                throw PromptExperimentAuthorityError.runtimeUnavailable("Project runner failed: \(code) (\(exception)). Verify its selected interpreter, dependencies and evaluator contract.")
                            } else if type == Self.terminalType(for: operation), terminal == nil {
                                terminal = line
                            } else {
                                throw PromptExperimentAuthorityError.runtimeUnavailable("Unexpected project runner event: \(type).")
                            }
                        }
                        guard let terminal else { throw PromptExperimentAuthorityError.runtimeUnavailable("The project runner exited without a result.") }
                        while session.process.isRunning {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        guard session.process.terminationReason == .exit, session.process.terminationStatus == 0 else {
                            throw PromptExperimentAuthorityError.runtimeUnavailable("The project runner exited unsuccessfully after producing a result.")
                        }
                        return terminal
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(operation == nil ? program.timeoutSeconds : min(program.timeoutSeconds, 30)))
                        throw PromptExperimentProviderFailure(code: .timedOut)
                    }
                    defer { session.stop()
                        group.cancelAll()
                    }
                    guard let first = try await group.next() else { throw CancellationError() }
                    return first
                }
            } onCancel: { session.stop() }
            guard let result = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The project runner result is not an object.")
            }
            return result
        }

        private static func terminalType(for operation: String?) -> String {
            switch operation {
            case "--preflight", "--validate": "ready"
            case "--describe": "description"
            case "--export": "exported"
            default: "result"
            }
        }
    }

    private final class PromptLabProgramProcess: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        private let scratch: URL
        private let errorHandle: FileHandle

        init(program: PromptLabProgram, runner: URL, adapter: String, operation: String?) throws {
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rpce-program-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let stderrURL = scratch.appendingPathComponent("stderr.log")
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            errorHandle = try FileHandle(forWritingTo: stderrURL)
            process.executableURL = URL(fileURLWithPath: program.pythonExecutable)
            process.arguments = ["-I", "-B", runner.path, "--project-root", program.projectRoot, "--module", program.modulePath, "--callable", program.callable, "--adapter", adapter] + (operation.map { [$0] } ?? [])
            process.currentDirectoryURL = URL(fileURLWithPath: program.projectRoot, isDirectory: true)
            var environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": scratch.path,
                "TMPDIR": scratch.path,
                "LANG": "en_US.UTF-8",
                "PYTHONUNBUFFERED": "1",
                "PYTHONDONTWRITEBYTECODE": "1"
            ]
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"] {
                environment[key] = ProcessInfo.processInfo.environment[key]
            }
            for key in program.environmentKeys {
                guard let value = ProcessInfo.processInfo.environment[key] else {
                    throw PromptExperimentAuthorityError.runtimeUnavailable("The selected environment variable '\(key)' is unavailable to RPCE. Configure it before running this evaluator, or load the project's own configuration in the module.")
                }
                environment[key] = value
            }
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorHandle
        }

        func write(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        func stop() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }

        func dispose() {
            stop()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    extension PromptExperimentService {
        func describeProgram(_ program: PromptLabProgram, runner: PromptLabRunnerKind) async throws -> PromptLabDefinition {
            guard runner == .program || runner == .dspy else { throw PromptExperimentAuthorityError.invalidRequest("Choose Python or DSPy execution.") }
            var sealed = try program.sealed()
            let description = try await PromptLabProgramHarness.describe(program: sealed, runner: runner)
            if let routing = description["model_routing"] as? String {
                sealed.modelRouting = PromptLabProgram.ModelRouting(rawValue: routing)
            }
            // A generic evaluator need not own the prompt: users can select a source file
            // or paste it independently. The final definition validates a nonempty seed.
            let seed = description["seed_candidate"] as? String ?? ""
            if runner == .dspy, seed.isEmpty {
                throw PromptExperimentAuthorityError.invalidRequest("The DSPy program did not describe any predictor instructions.")
            }
            let examples: [PromptSuiteCase] = if let data = description["examples"] as? [[String: Any]] {
                try data.enumerated().map { index, raw in
                    let payload = try JSONDecoder().decode([String: PromptExperimentExampleValue].self, from: JSONSerialization.data(withJSONObject: raw))
                    let fallback: PromptSuiteSplit = index < max(1, data.count - 2) ? .training : (index == data.count - 2 ? .validation : .hiddenTest)
                    return PromptSuiteCase(
                        id: raw["id"] as? String ?? "case_\(index + 1)",
                        split: (raw["split"] as? String).flatMap(PromptSuiteSplit.init(rawValue:)) ?? fallback,
                        input: raw["input"] as? String ?? raw["question"] as? String ?? "Project example \(index + 1)",
                        expectedOutput: raw["expectedOutput"] as? String ?? raw["expected_output"] as? String,
                        variables: raw["variables"] as? [String: String] ?? [:], payload: payload
                    )
                }
            } else { [] }
            let criteria = (description["criteria"] as? String) ?? (description["criteria"] as? [String])?.joined(separator: "\n") ?? "Program metric and acceptance checks"
            return PromptLabDefinition(
                source: .init(kind: .pasted, title: URL(fileURLWithPath: sealed.modulePath).lastPathComponent, prompt: seed),
                goal: description["objective"] as? String ?? "Improve task quality while preserving required behavior.",
                runner: runner, examples: examples, criteria: criteria, program: sealed
            )
        }
    }
#endif
