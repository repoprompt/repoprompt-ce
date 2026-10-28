#if DEBUG
    import Foundation
    import MCP
    import RepoPromptShared

    enum PromptExperimentOperation: String, CaseIterable {
        case targets
        case createOrUpdate = "create_or_update"
        case requestApproval = "request_approval"
        case run
        case statusOrWait = "status_or_wait"
        case cancel
        case proposePatch = "propose_patch"
    }

    enum PromptExperimentCommand: Equatable {
        case targets
        case createOrUpdate(PromptExperimentCreateRequest)
        case requestApproval(experimentID: UUID, expectedAuthorityDigest: String?)
        case run(experimentID: UUID)
        case statusOrWait(experimentID: UUID?, timeoutSeconds: TimeInterval)
        case cancel(experimentID: UUID)
        case proposePatch(experimentID: UUID, runID: UUID, candidateIndex: Int)
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
                case .invalidCandidate, .unchangedCandidate: "invalid_candidate"
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
            "random_seed", "prompt_character_ceiling_ratio", "max_prompt_characters", "noise_floor_replicates"
        ]
        static let acceptedArguments: [PromptExperimentOperation: Set<String>] = [
            .targets: [],
            .createOrUpdate: createArguments,
            .requestApproval: ["experiment_id", "expected_authority_digest"],
            .run: ["experiment_id"],
            .statusOrWait: ["experiment_id", "timeout_seconds"],
            .cancel: ["experiment_id"],
            .proposePatch: ["experiment_id", "run_id", "candidate_index"]
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
            case .createOrUpdate:
                command = .createOrUpdate(PromptExperimentCreateRequest(
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
                ))
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
                    "project_prompts": .bool(false),
                    "tool_using_agents": .bool(false),
                    "dspy_programs": .bool(false)
                ]),
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
                    "Experiments optimize a built-in prompt against its checked-in suite. Targets must be prompt-only (no tools).",
                    "New Experiment in Window ▸ Prompt Experiments… (⌥⌘E) creates a draft without an agent. request_approval shows a native review; only the user can approve. Approval covers max_evaluations plus the separate calibration_evaluations and starts the first run. Evaluation counts are not model-call or dollar caps.",
                    "Project prompts, the Engineer agent prompt, and arbitrary DSPy programs are not supported by this prompt-only lab.",
                    "run resumes an approved experiment within its remaining cap. Changing any authority field creates a new experiment that needs its own approval.",
                    "status_or_wait with experiment_id blocks until the approval or run state changes, or timeout_seconds elapses.",
                    "propose_patch selects a retained candidate from a completed run; only native UI can apply or reject its source diff."
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
                "note": .string("Calibration is a separate approved line, spent only when the cross-experiment baseline cache misses. The worker never starts an iteration the remaining cap cannot finish.")
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
                "prompt_id": .string(experiment.authority.promptID.rawValue),
                "suite_id": .string(experiment.authority.suiteID),
                "remaining_evaluations": .int(experiment.remainingEvaluations)
            ])
        }

        static func experimentValue(_ experiment: PromptExperiment) -> Value {
            let authority = experiment.authority
            let settings = authority.settings
            return .object([
                "experiment_id": .string(experiment.id.uuidString),
                "title": .string(experiment.title),
                "status": .string(experiment.status.rawValue),
                "next_action": .string(nextAction(experiment)),
                "authority_digest": .string(experiment.authorityDigest),
                "supersedes": experiment.supersedes.map { .string($0.uuidString) } ?? .null,
                "authority": .object([
                    "prompt_id": .string(authority.promptID.rawValue),
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
                    "reflection_minibatch_size": .int(settings.reflectionMinibatchSize),
                    "candidate_selection_strategy": .string(settings.candidateSelectionStrategy),
                    "prompt_character_ceiling_ratio": .double(settings.promptCharacterCeilingRatio),
                    "max_prompt_characters": settings.maxPromptCharacters.map(Value.int) ?? .null,
                    "noise_floor_replicates": .int(settings.noiseFloorReplicates),
                    "max_provider_retries": .int(settings.maxProviderRetries),
                    "random_seed": .int(settings.randomSeed),
                    "gepa_revision": .string(authority.gepaRevision)
                ]),
                "admissions_used": .int(experiment.admissionsUsed),
                "remaining_evaluations": .int(experiment.remainingEvaluations),
                "calibration_admissions_used": .int(experiment.calibrationAdmissionsUsed),
                "approval_requested_at": experiment.approvalRequest.map { .string(iso8601.string(from: $0.requestedAt)) } ?? .null,
                "approved_at": experiment.approval.map { .string(iso8601.string(from: $0.approvedAt)) } ?? .null,
                "runs": .array(experiment.runs.map(runValue)),
                "proposals": .array(experiment.proposals.map { proposal in
                    .object([
                        "proposal_id": .string(proposal.id.uuidString),
                        "run_id": .string(proposal.runID.uuidString),
                        "candidate_index": .int(proposal.candidateIndex),
                        "state": .string(proposal.state.rawValue)
                    ])
                })
            ])
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
                    "evaluations": .int(result.totalEvaluations),
                    "candidates": .array(candidates)
                ])
            }
            return .object(value)
        }

        private static let iso8601 = ISO8601DateFormatter()
    }
#endif
