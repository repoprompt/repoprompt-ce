#if DEBUG
    import Foundation
    import MCP
    import RepoPromptShared

    enum PromptExperimentOperation: String, CaseIterable {
        case targets
        case prepare
        case describeProgram = "describe_program"
        case createOrUpdate = "create_or_update"
        case requestApproval = "request_approval"
        case run
        case statusOrWait = "status_or_wait"
        case cancel
        case proposePatch = "propose_patch"
        case exportResult = "export"
    }

    struct PromptExperimentPrepareRequest: Equatable {
        let promptID: String?
        let promptText: String?
        let promptFile: String?
        let sourceTitle: String?
        let selection: String?
        let goal: String
        let exampleInputs: String
        let criteria: String
        let targetSelector: String?
    }

    enum PromptExperimentCommand: Equatable {
        case targets
        case prepare(PromptExperimentPrepareRequest)
        case describeProgram(PromptLabProgram, runner: PromptLabRunnerKind)
        case createOrUpdate(PromptExperimentCreateRequest)
        case requestApproval(experimentID: UUID, expectedAuthorityDigest: String?)
        case run(experimentID: UUID)
        case statusOrWait(experimentID: UUID?, timeoutSeconds: TimeInterval)
        case cancel(experimentID: UUID)
        case proposePatch(experimentID: UUID, runID: UUID, candidateIndex: Int)
        case exportResult(experimentID: UUID, runID: UUID, outputPath: String)
    }

    /// The one structured error the tool returns: a stable code, a message, and every
    /// field-level problem found in the request.
    struct PromptExperimentMCPError: Error, Equatable {
        let code: String
        let message: String
        let fields: [PromptExperimentFieldError]

        var jsonText: String {
            let object: [String: Any] = [
                "error": [
                    "code": code,
                    "message": message,
                    "fields": fields.map { ["field": $0.field, "message": $0.message] }
                ] as [String: Any]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        static func from(_ error: Error) -> Self {
            if let error = error as? Self { return error }
            if let patch = error as? PromptPatchProposer.PatchError {
                let code = switch patch {
                case .baselineConflict: "baseline_conflict"
                case .sourceRootUnavailable: "source_root_unavailable"
                case .unsafeSourcePath, .archiveConflict: "unsafe_source_path"
                case .invalidCandidate, .invalidEngineerTemplate, .unchangedCandidate: "invalid_candidate"
                }
                return Self(code: code, message: patch.localizedDescription, fields: [])
            }
            guard let authority = error as? PromptExperimentAuthorityError else {
                return Self(code: "internal_error", message: error.localizedDescription, fields: [])
            }
            let code = switch authority {
            case .experimentNotFound: "experiment_not_found"
            case .authorityChanged: "authority_changed"
            case .approvalNotRequested: "approval_not_requested"
            case .alreadyApproved: "already_approved"
            case .notApproved: "not_approved"
            case .runActive: "run_active"
            case .budgetExhausted: "budget_exhausted"
            case .invalidRequest: "invalid_request"
            case .validation: "validation_failed"
            case .targetUnavailable: "target_unavailable"
            case .runtimeUnavailable: "runtime_unavailable"
            }
            if case let .validation(fields) = authority {
                return Self(code: code, message: "The experiment request has \(fields.count) invalid field(s).", fields: fields)
            }
            return Self(code: code, message: authority.localizedDescription, fields: [])
        }
    }

    /// MCP adapter over the app-wide experiment service. It can create, request approval for,
    /// run, observe, and cancel experiments; it has no path to approve one.
    @MainActor
    enum PromptExperimentMCPControl {
        static let defaultWaitSeconds: TimeInterval = 60

        private static let commonArguments: Set<String> = ["op"]
        private static let createArguments: Set<String> = [
            "experiment_id", "title", "prompt_id", "suite_id", "execution_target", "reflection_target",
            "judge_target", "max_evaluations", "reflection_minibatch_size", "max_provider_retries",
            "random_seed", "prompt_character_ceiling_ratio", "max_prompt_characters", "noise_floor_replicates", "definition"
        ]
        static let acceptedArguments: [PromptExperimentOperation: Set<String>] = [
            .targets: [],
            .prepare: ["prompt_id", "prompt_text", "prompt_file", "source_title", "selection", "goal", "example_inputs", "criteria", "reflection_target"],
            .describeProgram: ["program", "runner"],
            .createOrUpdate: createArguments,
            .requestApproval: ["experiment_id", "expected_authority_digest"],
            .run: ["experiment_id"],
            .statusOrWait: ["experiment_id", "timeout_seconds"],
            .cancel: ["experiment_id"],
            .proposePatch: ["experiment_id", "run_id", "candidate_index"],
            .exportResult: ["experiment_id", "run_id", "output_path"]
        ]

        static func execute(args: [String: Value]) async throws -> Value {
            if let connectionID = ServerNetworkManager.currentConnectionID,
               await ServerNetworkManager.shared.runPurpose(for: connectionID) == .discoverRun
            {
                throw MCPError.invalidParams(PromptExperimentMCPError(
                    code: "forbidden",
                    message: "Discovery and evaluation callbacks cannot control the experiment lab.",
                    fields: []
                ).jsonText)
            }
            do {
                return try await handle(args: args, service: WindowStatesManager.shared.promptExperimentService)
            } catch let error as PromptExperimentMCPError {
                throw MCPError.invalidParams(error.jsonText)
            }
        }

        /// Parses, executes, and encodes one call. Errors surface as `PromptExperimentMCPError`.
        static func handle(args: [String: Value], service: PromptExperimentService) async throws -> Value {
            let command = try parse(args)
            do {
                switch command {
                case .targets:
                    return await targetsValue(service: service)
                case let .prepare(request):
                    let source: PromptLabSource
                    if let rawID = request.promptID {
                        guard let id = BuiltInPromptID(rawValue: rawID) else {
                            throw PromptExperimentAuthorityError.invalidRequest("Unknown built-in prompt. Call targets to list the available prompts.")
                        }
                        source = try service.source(for: id)
                    } else if let path = request.promptFile {
                        source = try PromptLabSource.importFile(url: URL(fileURLWithPath: path), selection: request.selection)
                    } else {
                        source = PromptLabSource(kind: .pasted, title: request.sourceTitle ?? "Pasted prompt", prompt: request.promptText ?? "")
                    }
                    let definition = try await service.prepareDefinition(
                        source: source, goal: request.goal, exampleInputs: request.exampleInputs,
                        criteria: request.criteria, targetSelector: request.targetSelector
                    )
                    return try .object([
                        "definition": encodedValue(definition),
                        "next_action": .string("Review the generated examples and criteria with the user; then pass definition to create_or_update. This preparation made one model call and did not approve or start optimization.")
                    ])
                case let .describeProgram(program, runner):
                    let definition = try await service.describeProgram(program, runner: runner)
                    return try .object([
                        "definition": encodedValue(definition),
                        "next_action": .string("Review this program's prompt, examples, checks and model routing; supply the user's starting prompt if source.prompt is empty, then pass definition to create_or_update. Loading the description executed the selected local Python module, not an optimization run.")
                    ])
                case let .createOrUpdate(request):
                    return try await experimentValue(service.createOrUpdate(request))
                case let .requestApproval(experimentID, digest):
                    return try await experimentValue(service.requestApproval(experimentID: experimentID, expectedAuthorityDigest: digest))
                case let .run(experimentID):
                    return try await experimentValue(service.run(experimentID: experimentID))
                case let .statusOrWait(experimentID, timeout):
                    guard let experimentID else {
                        await service.load()
                        return .object(["experiments": .array(service.experiments.map(summaryValue))])
                    }
                    return try await experimentValue(service.statusOrWait(experimentID: experimentID, timeoutSeconds: timeout))
                case let .cancel(experimentID):
                    return try await experimentValue(service.cancel(experimentID: experimentID))
                case let .proposePatch(experimentID, runID, candidateIndex):
                    let proposal = try await service.proposePatch(experimentID: experimentID, runID: runID, candidateIndex: candidateIndex)
                    return .object([
                        "experiment_id": .string(experimentID.uuidString),
                        "proposal_id": .string(proposal.id.uuidString),
                        "run_id": .string(runID.uuidString),
                        "candidate_index": .int(candidateIndex),
                        "state": .string(proposal.state.rawValue),
                        "diff_sha256": proposal.diffEvidence.map { .string($0.sha256) } ?? .null,
                        "next_action": .string("Review the full diff and run evidence in the native card or Prompt Experiments Studio; only native controls can apply or reject.")
                    ])
                case let .exportResult(experimentID, runID, outputPath):
                    try await service.exportResult(experimentID: experimentID, runID: runID, to: URL(fileURLWithPath: outputPath))
                    return .object([
                        "experiment_id": .string(experimentID.uuidString), "run_id": .string(runID.uuidString),
                        "output_path": .string(outputPath), "status": .string("exported")
                    ])
                }
            } catch {
                throw PromptExperimentMCPError.from(error)
            }
        }

        // MARK: - Parsing

        static func parse(_ args: [String: Value]) throws -> PromptExperimentCommand {
            let rawOperation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let operation = PromptExperimentOperation(rawValue: rawOperation) else {
                throw PromptExperimentMCPError(
                    code: "invalid_request",
                    message: "Unknown op.",
                    fields: [.init(field: "op", message: "Must be one of: \(PromptExperimentOperation.allCases.map(\.rawValue).joined(separator: ", ")).")]
                )
            }
            var errors: [PromptExperimentFieldError] = []
            let accepted = acceptedArguments[operation, default: []].union(commonArguments)
            for key in args.keys.sorted() where !accepted.contains(key) {
                errors.append(.init(field: key, message: "Not accepted by op=\(operation.rawValue)."))
            }
            func string(_ key: String) -> String? {
                guard let value = args[key], value != .null else { return nil }
                guard let text = value.stringValue else {
                    errors.append(.init(field: key, message: "Must be a string."))
                    return nil
                }
                return text
            }
            func integer(_ key: String) -> Int? {
                guard let value = args[key], value != .null else { return nil }
                switch value {
                case let .int(number): return number
                case let .double(number) where number.rounded() == number && abs(number) < 1e9: return Int(number)
                default:
                    errors.append(.init(field: key, message: "Must be an integer."))
                    return nil
                }
            }
            func number(_ key: String) -> Double? {
                guard let value = args[key], value != .null else { return nil }
                switch value {
                case let .int(number): return Double(number)
                case let .double(number): return number
                default:
                    errors.append(.init(field: key, message: "Must be a number."))
                    return nil
                }
            }
            func uuid(_ key: String, required: Bool) -> UUID? {
                guard let text = string(key) else {
                    if required, args[key] == nil || args[key] == .null {
                        errors.append(.init(field: key, message: "Required."))
                    }
                    return nil
                }
                guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    errors.append(.init(field: key, message: "Must be an experiment UUID."))
                    return nil
                }
                return id
            }

            let command: PromptExperimentCommand?
            switch operation {
            case .targets:
                command = .targets
            case .prepare:
                let promptID = string("prompt_id")
                let promptText = string("prompt_text")
                let promptFile = string("prompt_file")
                if [promptID, promptText, promptFile].compactMap(\.self).count != 1 {
                    errors.append(.init(field: "source", message: "Provide exactly one of prompt_id, prompt_text or prompt_file."))
                }
                let selection = string("selection")
                if selection != nil, promptFile == nil {
                    errors.append(.init(field: "selection", message: "A selection requires prompt_file."))
                }
                if let promptFile, !promptFile.hasPrefix("/") {
                    errors.append(.init(field: "prompt_file", message: "Use an absolute file path."))
                }
                let goal = string("goal") ?? ""
                if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append(.init(field: "goal", message: "Describe what should improve."))
                }
                command = .prepare(.init(
                    promptID: promptID, promptText: promptText, promptFile: promptFile,
                    sourceTitle: string("source_title"), selection: selection, goal: goal,
                    exampleInputs: string("example_inputs") ?? "", criteria: string("criteria") ?? "",
                    targetSelector: string("reflection_target")
                ))
            case .describeProgram:
                let runnerName = string("runner") ?? PromptLabRunnerKind.program.rawValue
                let runner = PromptLabRunnerKind(rawValue: runnerName)
                if runner != .program, runner != .dspy {
                    errors.append(.init(field: "runner", message: "Must be program or dspy."))
                }
                let program: PromptLabProgram? = decodeProgram(args["program"], errors: &errors)
                command = if let program, let runner { .describeProgram(program, runner: runner) } else { nil }
            case .createOrUpdate:
                var request = PromptExperimentCreateRequest(
                    experimentID: uuid("experiment_id", required: false),
                    title: string("title"),
                    promptID: string("prompt_id"),
                    suiteID: string("suite_id"),
                    executionTarget: string("execution_target"),
                    reflectionTarget: string("reflection_target"),
                    judgeTarget: string("judge_target"),
                    maxEvaluations: integer("max_evaluations"),
                    reflectionMinibatchSize: integer("reflection_minibatch_size"),
                    maxProviderRetries: integer("max_provider_retries"),
                    randomSeed: integer("random_seed"),
                    promptCharacterCeilingRatio: number("prompt_character_ceiling_ratio"),
                    maxPromptCharacters: integer("max_prompt_characters"),
                    noiseFloorReplicates: integer("noise_floor_replicates")
                )
                request.definition = decodeDefinition(args["definition"], errors: &errors)
                command = .createOrUpdate(request)
            case .requestApproval:
                let id = uuid("experiment_id", required: true)
                let digest = string("expected_authority_digest")
                command = id.map { .requestApproval(experimentID: $0, expectedAuthorityDigest: digest) }
            case .run:
                command = uuid("experiment_id", required: true).map { .run(experimentID: $0) }
            case .statusOrWait:
                let id = uuid("experiment_id", required: false)
                var timeout = defaultWaitSeconds
                if let value = args["timeout_seconds"], value != .null {
                    let seconds: Double? = switch value {
                    case let .int(number): Double(number)
                    case let .double(number): number
                    default: nil
                    }
                    if let seconds, seconds.isFinite, (0 ... 3600).contains(seconds) {
                        timeout = seconds
                    } else {
                        errors.append(.init(field: "timeout_seconds", message: "Must be a number between 0 and 3600."))
                    }
                }
                command = .statusOrWait(experimentID: id, timeoutSeconds: id == nil ? 0 : timeout)
            case .cancel:
                command = uuid("experiment_id", required: true).map { .cancel(experimentID: $0) }
            case .proposePatch:
                let experimentID = uuid("experiment_id", required: true)
                let runID = uuid("run_id", required: true)
                let candidateIndex = integer("candidate_index")
                if candidateIndex == nil, args["candidate_index"] == nil || args["candidate_index"] == .null {
                    errors.append(.init(field: "candidate_index", message: "Required."))
                }
                if let candidateIndex, candidateIndex < 0 {
                    errors.append(.init(field: "candidate_index", message: "Must be nonnegative."))
                }
                command = if let experimentID, let runID, let candidateIndex {
                    .proposePatch(experimentID: experimentID, runID: runID, candidateIndex: candidateIndex)
                } else {
                    nil
                }
            case .exportResult:
                let experimentID = uuid("experiment_id", required: true)
                let runID = uuid("run_id", required: true)
                let path = string("output_path")
                if path?.hasPrefix("/") != true {
                    errors.append(.init(field: "output_path", message: "An absolute destination file path is required."))
                }
                command = if let experimentID, let runID, let path {
                    .exportResult(experimentID: experimentID, runID: runID, outputPath: path)
                } else { nil }
            }
            guard errors.isEmpty, let command else {
                throw PromptExperimentMCPError(
                    code: "invalid_request",
                    message: "The op=\(operation.rawValue) request has \(errors.count) invalid argument(s).",
                    fields: errors
                )
            }
            return command
        }

        // MARK: - Encoding

        /// Fill documented defaults before Codable decoding. Nested property names are the
        /// same camelCase names returned by prepare, so that response can be reviewed and
        /// submitted without a lossy conversion or a second schema.
        static func decodeDefinition(_ value: Value?, errors: inout [PromptExperimentFieldError]) -> PromptLabDefinition? {
            guard let value, value != .null else { return nil }
            guard var object = value.objectValue else {
                errors.append(.init(field: "definition", message: "Must be an experiment definition object."))
                return nil
            }
            rejectUnknown(object, allowed: ["source", "goal", "objective", "runner", "examples", "criteria", "program", "contractVersion", "relativePromptLimit"], path: "definition", errors: &errors)
            object["runner"] = object["runner"] ?? .string(PromptLabRunnerKind.plainPrompt.rawValue)
            object["contractVersion"] = object["contractVersion"] ?? .int(PromptLabDefinition.contractVersion)
            if let source = object["source"]?.objectValue {
                rejectUnknown(source, allowed: ["kind", "title", "prompt", "builtInPromptID", "filePath", "originalFileSHA256", "selection", "literal"], path: "definition.source", errors: &errors)
                if let literal = source["literal"]?.objectValue {
                    rejectUnknown(literal, allowed: ["language", "token"], path: "definition.source.literal", errors: &errors)
                }
            }
            var objective = object["objective"]?.objectValue ?? [:]
            if let supplied = object["objective"], supplied.objectValue == nil {
                errors.append(.init(field: "definition.objective", message: "Must be an objective object."))
            }
            rejectUnknown(objective, allowed: ["mode", "qualityTolerance", "inputWeight", "outputWeight"], path: "definition.objective", errors: &errors)
            objective["mode"] = objective["mode"] ?? .string("quality")
            objective["qualityTolerance"] = objective["qualityTolerance"] ?? .double(0)
            objective["inputWeight"] = objective["inputWeight"] ?? .double(1)
            objective["outputWeight"] = objective["outputWeight"] ?? .double(1)
            object["objective"] = .object(objective)
            if let examples = object["examples"]?.arrayValue {
                object["examples"] = .array(examples.enumerated().map { index, item in
                    guard var example = item.objectValue else { return item }
                    let path = "definition.examples[\(index)]"
                    rejectUnknown(example, allowed: ["id", "split", "input", "expectedOutput", "context", "variables", "payload"], path: path, errors: &errors)
                    example["variables"] = example["variables"] ?? .object([:])
                    if let context = example["context"]?.objectValue {
                        rejectUnknown(context, allowed: ["fileTree", "files"], path: "\(path).context", errors: &errors)
                        for (fileIndex, file) in (context["files"]?.arrayValue ?? []).enumerated() {
                            if let file = file.objectValue {
                                rejectUnknown(file, allowed: ["path", "content"], path: "\(path).context.files[\(fileIndex)]", errors: &errors)
                            }
                        }
                    }
                    return .object(example)
                })
            }
            if let supplied = object["program"], supplied != .null,
               let program = decodeProgram(supplied, field: "definition.program", errors: &errors)
            {
                object["program"] = try? encodedValue(program)
            }
            return decode(.object(object), as: PromptLabDefinition.self, field: "definition", errors: &errors)
        }

        static func decodeProgram(_ value: Value?, field: String = "program", errors: inout [PromptExperimentFieldError]) -> PromptLabProgram? {
            guard var object = value?.objectValue else {
                errors.append(.init(field: field, message: "Provide the Python interpreter, project root and evaluation module in a program object."))
                return nil
            }
            rejectUnknown(object, allowed: ["pythonExecutable", "projectRoot", "modulePath", "callable", "timeoutSeconds", "moduleSHA256", "environmentKeys", "modelRouting", "dependencySHA256"], path: field, errors: &errors)
            object["callable"] = object["callable"] ?? .string("evaluate")
            object["timeoutSeconds"] = object["timeoutSeconds"] ?? .double(120)
            object["environmentKeys"] = object["environmentKeys"] ?? .array([])
            return decode(.object(object), as: PromptLabProgram.self, field: field, errors: &errors)
        }

        private static func rejectUnknown(_ object: [String: Value], allowed: Set<String>, path: String, errors: inout [PromptExperimentFieldError]) {
            for key in object.keys.sorted() where !allowed.contains(key) {
                errors.append(.init(field: "\(path).\(key)", message: "Unknown field."))
            }
        }

        private static func decode<T: Decodable>(_ value: Value, as type: T.Type, field: String, errors: inout [PromptExperimentFieldError]) -> T? {
            do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
            catch {
                let detail: String = switch error {
                case let DecodingError.keyNotFound(key, context):
                    "Missing \((context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))."
                case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context), let DecodingError.dataCorrupted(context):
                    "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
                default: error.localizedDescription
                }
                errors.append(.init(field: field, message: detail))
                return nil
            }
        }

        static func encodedValue(_ value: some Encodable) throws -> Value {
            try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        }

        static func targetsValue(service: PromptExperimentService) async -> Value {
            await service.load()
            let defaults = service.targetDefaults()
            let prompts: [Value] = service.promptOptions().map { option in
                var value: [String: Value] = ["prompt_id": .string(option.id)]
                if let resourceSHA256 = option.resourceSHA256 {
                    value["resource_sha256"] = .string(resourceSHA256)
                }
                if let suite = option.suite {
                    value["suite"] = .object([
                        "suite_id": .string(suite.suiteID),
                        "suite_sha256": .string(suite.suiteSHA256),
                        "grader": .string(suite.grader.kind.rawValue),
                        "score_range": .array([.double(suite.grader.scoreRange.min), .double(suite.grader.scoreRange.max)]),
                        "cases": .object(Dictionary(uniqueKeysWithValues: PromptSuiteSplit.allCases.map {
                            ($0.rawValue, Value.int(suite.cases(in: $0).count))
                        })),
                        "minimum_max_evaluations": .int(PromptExperimentBudgetLedger.minimumApprovableEvaluations(
                            cases: suite.cases, reflectionMinibatchSize: PromptExperimentGEPASettings().reflectionMinibatchSize
                        )),
                        "budget_guide": budgetGuide(cases: suite.cases, minibatch: PromptExperimentGEPASettings().reflectionMinibatchSize)
                    ])
                } else {
                    value["suite"] = .null
                    value["suite_unavailable"] = .string(option.unavailableReason ?? "The prompt suite is unavailable.")
                }
                return .object(value)
            }
            return .object([
                "operations": .array(PromptExperimentOperation.allCases.map { .string($0.rawValue) }),
                "scope": .object([
                    "built_in_prompts": .bool(true),
                    "project_prompts": .bool(true),
                    "pasted_prompts": .bool(true),
                    "tool_using_agents": .bool(true),
                    "dspy_programs": .bool(true)
                ]),
                "runners": .array(PromptLabRunnerKind.allCases.map { .string($0.rawValue) }),
                "prompts": .array(prompts),
                "targets": .array(service.availableTargets().map(targetValue)),
                "defaults": .object([
                    "execution_target": defaults.execution.map { .string($0.selector) } ?? .null,
                    "reflection_target": defaults.reflection.map { .string($0.selector) } ?? .null,
                    "judge_target": defaults.judge.map { .string($0.selector) } ?? .null
                ]),
                "runtime": .object([
                    "gepa_version": .string(PromptExperimentGEPAConfiguration.packageVersion),
                    "gepa_revision": .string(PromptExperimentGEPAConfiguration.pinnedRevision),
                    "python_version": .string(PromptExperimentGEPAWorker.pythonVersion),
                    "bundled_runtime_available": .bool(PromptExperimentGEPAWorker.bundledRuntimeAvailable),
                    "status": .string(PromptExperimentGEPAWorker.runtimeStatus)
                ]),
                "notes": .array([
                    "One lab optimizes RPCE prompts, project prompt files or selected source passages, pasted templates, and Python/DSPy programs. A frozen definition records the goal, examples, criteria and actual task runner.",
                    "prepare drafts examples and checks with one bounded model call. describe_program executes the selected local Python module to load its description. Review the returned definition before create_or_update; neither operation approves optimization.",
                    "New Experiment in Window ▸ Prompt Experiments… (⌥⌘E) creates a draft without an agent. request_approval shows a native review; only the user can approve. Approval covers max_evaluations plus the separate calibration_evaluations and starts the first run. Evaluation counts are not model-call or dollar caps.",
                    "Oracle uses production prompt packaging. Engineer evaluates real file tasks in separate fixtures with read/edit tools and private acceptance checks; shell, web and delegation are disabled. Python/DSPy programs execute the selected project evaluator and its dependencies.",
                    "run resumes an approved experiment within its remaining cap. Changing any authority field creates a new experiment that needs its own approval.",
                    "status_or_wait with experiment_id blocks until the approval or run state changes, or timeout_seconds elapses.",
                    "propose_patch selects a retained candidate from a completed run; only native UI can apply or reject its source diff. Pasted prompts can be copied or saved in Studio. export writes a JSON evidence file with the frozen definition and result artifacts.",
                    "Token reductions require reported usage on matching examples. Inspect comparison coverage, final-check quality and baseline variability before claiming an improvement."
                ].map(Value.string))
            ])
        }

        /// How the default settings spend a cap on this suite, so a caller can size `max_evaluations`.
        static func budgetGuide(cases: [PromptSuiteCase], minibatch: Int) -> Value {
            let shape = PromptExperimentBudgetLedger.searchShape(cases: cases, reflectionMinibatchSize: minibatch)
            return .object([
                "seed_validation_pass": .int(shape.validationPass),
                "accepted_proposal_cost": .int(shape.iterationCost),
                "rejected_proposal_cost": .int(shape.iterationCost - shape.validationPass),
                "held_out_reserve": .int(PromptExperimentBudgetLedger.heldOutReserve(for: cases)),
                "calibration_evaluations": .int(PromptExperimentBudgetLedger.calibrationEvaluations(
                    cases: cases, replicates: PromptExperimentGEPASettings().noiseFloorReplicates
                )),
                "expected_proposals_at_25": .int(PromptExperimentBudgetLedger.expectedProposals(
                    cap: 25, cases: cases, reflectionMinibatchSize: minibatch
                )),
                "note": .string("Calibration is a separate approved line. Definition-backed labs use a fresh baseline for each experiment; legacy built-in requests may reuse a matching cache. The worker never starts an iteration the remaining cap cannot finish.")
            ])
        }

        static func noiseFloorValue(_ noise: PromptExperimentNoiseFloor) -> Value {
            func comparison(_ value: PromptExperimentNoiseFloor.CaseComparison) -> Value {
                .object([
                    "example_id": .string(value.exampleID),
                    "split": .string(value.split.rawValue),
                    "baseline_samples": .array(value.baselineSamples.map(Value.double)),
                    "baseline_mean": .double(value.baselineMean),
                    "best": value.best.map(Value.double) ?? .null,
                    "delta": value.delta.map(Value.double) ?? .null,
                    "spread": .double(value.spread),
                    "improved_beyond_noise": .bool(value.improvedBeyondNoise),
                    "regressed_beyond_noise": .bool(value.regressedBeyondNoise)
                ])
            }
            return .object([
                "summary": .string(noise.summary),
                "measured": .bool(noise.measured),
                "within_noise": .bool(noise.withinNoise),
                "samples_per_case": .int(noise.samplesPerCase),
                "mean_spread": .double(noise.meanSpread),
                "mean_delta": noise.meanDelta.map(Value.double) ?? .null,
                "held_out_mean_delta": noise.heldOutMeanDelta.map(Value.double) ?? .null,
                "validation": .array(noise.validation.map(comparison)),
                "held_out": .array(noise.heldOut.map(comparison))
            ])
        }

        static func usageValue(_ usage: PromptExperimentCandidateUsage) -> Value {
            .object([
                "prompt_characters": .int(usage.promptCharacters),
                "evaluations": .int(usage.evaluations),
                "average_output_characters": usage.averageOutputCharacters.map(Value.double) ?? .null,
                "token_reported_evaluations": .int(usage.tokenReportedEvaluations),
                "average_prompt_tokens": usage.averagePromptTokens.map(Value.double) ?? .null,
                "average_completion_tokens": usage.averageCompletionTokens.map(Value.double) ?? .null
            ])
        }

        static func usageComparisonValue(_ comparison: PromptLabUsageComparison) -> Value {
            .object([
                "split": .string(comparison.split.rawValue), "case_count": .int(comparison.caseCount),
                "paired_input_cases": .int(comparison.pairedInputCases), "paired_output_cases": .int(comparison.pairedOutputCases),
                "baseline_input_tokens": comparison.baselineInputTokens.map(Value.int) ?? .null,
                "candidate_input_tokens": comparison.candidateInputTokens.map(Value.int) ?? .null,
                "baseline_output_tokens": comparison.baselineOutputTokens.map(Value.int) ?? .null,
                "candidate_output_tokens": comparison.candidateOutputTokens.map(Value.int) ?? .null,
                "input_reduction": comparison.inputReduction.map(Value.double) ?? .null,
                "output_reduction": comparison.outputReduction.map(Value.double) ?? .null,
                "summary": .string(comparison.summary)
            ])
        }

        static func targetValue(_ target: PromptExperimentResolvedTarget) -> Value {
            .object([
                "selector": .string(target.selector),
                "display_name": .string(target.displayName),
                "agent": .string(target.agentRaw),
                "model": .string(target.modelRaw),
                "prompt_only": .bool(PromptExperimentConnectedModelRunner.supportsPromptOnlyCallbacks(target))
            ])
        }

        static func nextAction(_ experiment: PromptExperiment) -> String {
            switch experiment.status {
            case .unapproved: "request_approval, then tell the user to review the native card or Window ▸ Prompt Experiments… (⌥⌘E)"
            case .awaitingApproval: "status_or_wait until the user approves or declines in the native card or Window ▸ Prompt Experiments… (⌥⌘E)"
            case .approved: "run"
            case .running: "status_or_wait"
            case .completed, .stoppedBudget:
                "review the run evidence; propose_patch a retained candidate, or run to resume within \(experiment.remainingEvaluations) evaluations"
            case .failed, .cancelled:
                "review the run evidence; run resumes within the remaining \(experiment.remainingEvaluations) evaluations"
            case .budgetExhausted: "review the run evidence; create_or_update a new experiment for more budget"
            }
        }

        static func summaryValue(_ experiment: PromptExperiment) -> Value {
            .object([
                "experiment_id": .string(experiment.id.uuidString),
                "title": .string(experiment.title),
                "status": .string(experiment.status.rawValue),
                "prompt_id": .string(experiment.authority.promptIdentifier),
                "source": .string(experiment.authority.sourceDescription),
                "suite_id": .string(experiment.authority.suiteID),
                "remaining_evaluations": .int(experiment.remainingEvaluations)
            ])
        }

        static func experimentValue(_ experiment: PromptExperiment) -> Value {
            let authority = experiment.authority
            let settings = authority.settings
            let definition: Value = authority.definition.flatMap { try? encodedValue($0) } ?? .null
            let authorityValue: [String: Value] = [
                "prompt_id": .string(authority.promptIdentifier),
                "source": .string(authority.sourceDescription),
                "definition": definition,
                "prompt_resource_sha256": .string(authority.promptResourceSHA256),
                "suite_id": .string(authority.suiteID),
                "suite_sha256": .string(authority.suiteSHA256),
                "rubric_sha256": authority.rubricSHA256.map(Value.string) ?? .null,
                "execution_target": targetValue(authority.targets.execution),
                "reflection_target": targetValue(authority.targets.reflection),
                "judge_target": authority.targets.judge.map(targetValue) ?? .null,
                "max_evaluations": .int(authority.maxEvaluations),
                "calibration_evaluations": .int(authority.calibrationEvaluations),
                "maximum_total_evaluations": .int(authority.maximumTotalEvaluations),
                "max_provider_invocations": authority.maxProviderInvocations.map(Value.int) ?? .null,
                "reflection_minibatch_size": .int(settings.reflectionMinibatchSize),
                "candidate_selection_strategy": .string(settings.candidateSelectionStrategy),
                "prompt_character_ceiling_ratio": .double(settings.promptCharacterCeilingRatio),
                "max_prompt_characters": settings.maxPromptCharacters.map(Value.int) ?? .null,
                "noise_floor_replicates": .int(settings.noiseFloorReplicates),
                "max_provider_retries": .int(settings.maxProviderRetries),
                "random_seed": .int(settings.randomSeed),
                "gepa_revision": .string(authority.gepaRevision)
            ]
            let proposals: [Value] = experiment.proposals.map { proposal in
                let value: [String: Value] = [
                    "proposal_id": .string(proposal.id.uuidString),
                    "run_id": .string(proposal.runID.uuidString),
                    "candidate_index": .int(proposal.candidateIndex),
                    "state": .string(proposal.state.rawValue)
                ]
                return .object(value)
            }
            let value: [String: Value] = [
                "experiment_id": .string(experiment.id.uuidString),
                "title": .string(experiment.title),
                "status": .string(experiment.status.rawValue),
                "next_action": .string(nextAction(experiment)),
                "authority_digest": .string(experiment.authorityDigest),
                "supersedes": experiment.supersedes.map { .string($0.uuidString) } ?? .null,
                "authority": .object(authorityValue),
                "admissions_used": .int(experiment.admissionsUsed),
                "remaining_evaluations": .int(experiment.remainingEvaluations),
                "calibration_admissions_used": .int(experiment.calibrationAdmissionsUsed),
                "approval_requested_at": experiment.approvalRequest.map { .string(iso8601.string(from: $0.requestedAt)) } ?? .null,
                "approved_at": experiment.approval.map { .string(iso8601.string(from: $0.approvedAt)) } ?? .null,
                "runs": .array(experiment.runs.map(runValue)),
                "proposals": .array(proposals)
            ]
            return .object(value)
        }

        static func runValue(_ run: PromptExperimentRun) -> Value {
            var value: [String: Value] = [
                "run_id": .string(run.id.uuidString),
                "ordinal": .int(run.ordinal),
                "state": .string(run.state.rawValue),
                "status_text": .string(run.statusText),
                "admissions_before": .int(run.admissionsBefore),
                "admissions_after": run.admissionsAfter.map(Value.int) ?? .null,
                "calibration_admissions": run.calibrationAdmissions.map(Value.int) ?? .null,
                "interrupted_admissions_settled": .int(run.interruptedAdmissionsSettled),
                "uncertain_remote_settlement": .bool(run.uncertainRemoteSettlement),
                "scored_evaluations": .int(run.evaluations.count),
                "model_calls": .int(run.modelCalls.count),
                "model_calls_without_usage": .int(run.modelCalls.count(where: { $0.promptTokens == nil || $0.completionTokens == nil })),
                "gradings": .int(run.gradings.count),
                "error": run.error.map(Value.string) ?? .null,
                "run_directory": .string(run.runDirectoryRelativePath)
            ]
            if let diagnostics = run.diagnostics {
                value["diagnostics"] = .object([
                    "process_observation": .string(diagnostics.processObservation.rawValue),
                    "last_event": .string(diagnostics.lastObservedEvent),
                    "latest_progress": diagnostics.latestProgress.map(Value.string) ?? .null,
                    "stderr_log": diagnostics.stderrLogRelativePath.map(Value.string) ?? .null,
                    "protocol_log": diagnostics.stdoutProtocolLogRelativePath.map(Value.string) ?? .null
                ])
            }
            if let result = run.result {
                var heldOut: Value = .null
                if let summary = result.heldOut {
                    let baseline: Value = summary.baselineAverage.map(Value.double) ?? .null
                    let best: Value = summary.bestAverage.map(Value.double) ?? .null
                    heldOut = .object([
                        "baseline_average": baseline,
                        "best_average": best,
                        "baseline_source": summary.baselineSource.map { .string($0.rawValue) } ?? .null
                    ])
                }
                let candidates: [Value] = result.candidates.map { candidate in
                    let usage: Value = candidate.usage.map(usageValue) ?? .null
                    let score: Value = candidate.aggregateScore.map(Value.double) ?? .null
                    return .object([
                        "index": .int(candidate.index),
                        "parent_indices": .array(candidate.parentIndices.map(Value.int)),
                        "aggregate_score": score,
                        "is_baseline": .bool(candidate.isBaseline),
                        "is_best": .bool(candidate.isBest),
                        "sha256": .string(candidate.candidateEvidence.sha256),
                        "preview": .string(candidate.candidatePreview),
                        "usage": usage
                    ])
                }
                let noise: Value = result.noiseFloor.map(noiseFloorValue) ?? .null
                let stopReason: Value = result.stopReason.map(Value.string) ?? .null
                let baselineScore: Value = result.baselineScore.map(Value.double) ?? .null
                let bestScore: Value = result.bestScore.map(Value.double) ?? .null
                let bestIndex: Value = result.bestCandidateIndex.map(Value.int) ?? .null
                value["result"] = .object([
                    "stop_reason": stopReason,
                    "assessment": .string(result.assessment),
                    "baseline_score": baselineScore,
                    "best_score": bestScore,
                    "best_candidate_index": bestIndex,
                    "held_out": heldOut,
                    "noise_floor": noise,
                    "usage_comparison": result.usageComparison.map(usageComparisonValue) ?? .null,
                    "evaluations": .int(result.totalEvaluations),
                    "candidates": .array(candidates)
                ])
            }
            return .object(value)
        }

        private static let iso8601 = ISO8601DateFormatter()
    }
#endif
