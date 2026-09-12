import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPAgentSessionControlToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .agentSessionControl

    private let runtime: MCPAppToolBinder
    private let dependencies: MCPAppPhysicalCapabilityAdapters.Execution

    init(runtime: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution) {
        self.runtime = runtime
        dependencies = execution
    }

    func buildTools() -> [Tool] {
        var tools = [
            shareThoughtsTool(),
            setStatusTool(),
            waitForNextInstructionTool()
        ]
        #if DEBUG
            tools.append(promptExperimentTool())
        #endif
        return tools
    }

    private func shareThoughtsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.shareThoughts,
            freshnessPolicy: .none,
            description: """
            Share real-time progress updates with the user.

            **Critical**: This is the PRIMARY way to provide live feedback during operations.
            Without this tool, users see nothing until you call `wait_for_next_user_instruction` -
            they're left staring at a loading state wondering what's happening.

            Use this tool PROACTIVELY to narrate your progress as you work:
            - "Looking for authentication-related files..."
            - "Found UserService.swift, reading to understand the pattern..."
            - "Making changes to the login flow..."

            **When to use (frequently!):**
            - Exploring a codebase (searching, reading multiple files)
            - Working through multi-step implementations
            - Any task taking more than a few seconds
            - Before and after significant operations

            **Notes:**
            - Messages appear with a "thinking" indicator
            - Use the optional `title` parameter for categorization (e.g., "Searching", "Analyzing", "Planning")
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "thoughts": .string(description: "Your thoughts or reasoning to share with the user."),
                    "title": .string(description: "Optional short title for the thought (e.g., 'Analyzing', 'Planning').")
                ],
                required: ["thoughts"]
            )
        ) { [dependencies] _, args in
            try await Self.executeShareThoughts(args: args, dependencies: dependencies)
        }
    }

    private func setStatusTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.setStatus,
            freshnessPolicy: .none,
            description: """
            Rename the current agent session/tab.

            Use this tool near session start to set a helpful session title.
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "session_name": .string(description: "Optional session/tab title to set for the active session tab.")
                ],
                required: []
            )
        ) { [dependencies] _, args in
            try await Self.executeSetStatus(args: args, dependencies: dependencies)
        }
    }

    private func waitForNextInstructionTool() -> Tool {
        let defaultWaitSeconds = Int(MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds)
        return runtime.tool(
            name: MCPWindowToolName.waitForNextInstruction,
            freshnessPolicy: .none,
            description: """
            Complete your turn and receive the user's next message.

            **CRITICAL - YOU MUST ALWAYS CALL THIS TOOL**
            This is how you deliver your response to the user. Without calling this tool, the user sees NOTHING and the session hangs. You must call this after EVERY turn - whether you completed a task, answered a question, or just want to share information.

            **How it works:**
            - The `prompt` you provide IS your message to the user - make it your complete response
            - After you call this, you receive the user's reply as your next turn (like a normal conversation)
            - The wait defaults to \(defaultWaitSeconds) seconds and honors a caller-supplied `timeout_seconds`; a timeout returns `timed_out: true`
            - Do NOT send a separate text response before calling this tool - the prompt IS your response

            **Writing your response (the `prompt` parameter):**
            - Be verbose and thorough - explain what you did, what you found, or what you're thinking
            - Write naturally as if speaking to a colleague - no need to end with a question
            - Include relevant details: files changed, code snippets, reasoning, observations
            - Example: "I've refactored the authentication module to use JWT tokens. The changes include:\n\n1. **TokenManager.swift** - New class handling token generation and validation\n2. **AuthMiddleware.swift** - Updated to use TokenManager instead of session-based auth\n3. **UserController.swift** - Login endpoint now returns JWT in response body\n\nAll existing tests pass, and I added new tests for token expiration handling."
            - DO NOT write terse responses like "Done." - be informative and helpful

            **The user's response comes as your next turn:**
            - After calling this tool, you'll receive the user's message as input to your next turn
            - This is just like a normal conversation - no special handling needed
            - You don't need to ask "what's next?" - just present your response naturally
            """,
            annotations: .repoPromptLocalEphemeralState,
            inputSchema: .object(
                properties: [
                    "prompt": .string(description: "Your response to the user - what you want to say before waiting for their next instruction."),
                    "timeout_seconds": .integer(description: "Optional wait timeout in seconds. Default \(defaultWaitSeconds).")
                ],
                required: []
            )
        ) { [dependencies] _, args in
            try await Self.executeWaitForNextInstruction(args: args, dependencies: dependencies)
        }
    }

    #if DEBUG
        private func promptExperimentTool() -> Tool {
            runtime.tool(
                name: MCPWindowToolName.promptExperiment,
                freshnessPolicy: .none,
                description: """
                Set up, run, observe, and iterate on an upstream-GEPA experiment owned by this Agent session or the explicitly bound external MCP workspace.

                Start with `op=capabilities`, inspect only authorized context, and ask for genuinely missing goals.
                Cold starts use reviewed preparation rounds before search: schema 3 stage=preparation tests
                preparation_candidates on training examples only, with no reflection or held-out calls.
                Read feedback and revise; continue carries the tested candidate into a search draft.
                `setup` seals an already-discussed specification in one call. `run` requests exact-plan user
                approval through MCP form elicitation or the native card; acceptance starts automatically. Then use `wait`, `status`, `cancel`,
                and the revision/clone operations. New runs use the sealed evaluation count without an experiment-wide
                deadline; status/read return durable redacted worker and callback diagnostics. The agent cannot approve or apply a winner.
                """,
                annotations: .repoPromptLocalEphemeralState,
                inputSchema: .object(
                    properties: [
                        "op": .string(description: "capabilities | list | setup | create_draft | update_draft | propose_seal | status | run | wait | cancel | read | clone | clone_draft | rerun | propose_run_again | continue | propose_next_revision"),
                        "workspace_id": .string(description: "Required for external MCP operations except capabilities. Must match the bound workspace ID returned by capabilities."),
                        "approval_mode": .string(description: "mcp requests exact-plan approval via negotiated form elicitation, without native UI. External clients always use mcp; Agent sessions default to native."),
                        "experiment_id": .string(description: "Experiment UUID for record operations."),
                        "expected_draft_id": .string(description: "Exact draft UUID returned by create/read/update."),
                        "expected_draft_version": .integer(description: "Exact optimistic draft version returned by create/read/update."),
                        "expected_draft_digest": .string(description: "Exact draft digest returned by create/read/update."),
                        "expected_plan_digest": .string(description: "Exact current sealed plan digest for cloning or proposing a next revision."),
                        "candidate_index": .integer(description: "Optional exact GEPA candidate index to continue; omitted means the recorded best candidate."),
                        "timeout_seconds": .number(description: "For wait only: 0-3600 seconds to await terminal settlement before returning current progress. Default 120."),
                        "title": .string(description: "Optional draft title replacement."),
                        "task_input": .string(description: "Optional fixed task replacement."),
                        "synthetic_fixture": .string(description: "Optional synthetic fixture replacement. Loaded workspace content is unsupported."),
                        "original_instructions": .string(description: "Optional original instructions replacement."),
                        "candidate_instructions": .string(description: "Optional candidate instructions replacement."),
                        "target_role": .string(description: "Optional catalog selector: a task role such as explore or an exact compound model_id returned by capabilities, such as codexExec:<model-and-effort>."),
                        "repetitions": .integer(description: "Legacy v1 comparison field. New GEPA drafts do not use it."),
                        "specification_json": .string(description: "Complete versioned optimization specification JSON returned by create/read, with objective/background, reviewed examples, optional reviewed project snapshot, evaluator, execution adapter, and pinned GEPA configuration. Replaces the specification atomically under draft version/digest checks.")
                    ],
                    required: ["op"]
                )
            ) { [dependencies] _, args in
                try await Self.executePromptExperiment(args: args, dependencies: dependencies)
            }
        }

        private static func executePromptExperiment(
            args: [String: Value],
            dependencies: MCPAppPhysicalCapabilityAdapters.Execution
        ) async throws -> Value {
            try await PromptExperimentMCPControl.execute(args: args, dependencies: dependencies)
        }

        static func promptExperimentCommand(args: [String: Value]) throws -> PromptExperimentAgentCommand {
            guard let rawOperation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let operation = PromptExperimentAgentOperation(rawValue: rawOperation)
            else {
                throw MCPError.invalidParams("Unsupported Prompt Experiment operation. Call op=capabilities for the session-driven schema; approval requires a user response through MCP form elicitation or the native card.")
            }
            return switch operation {
            case .capabilities:
                .capabilities
            case .list:
                .list
            case .setup:
                try .setup(patch: PromptExperimentAgentDraftPatch(
                    title: args["title"]?.stringValue,
                    taskInput: args["task_input"]?.stringValue,
                    syntheticFixture: args["synthetic_fixture"]?.stringValue,
                    originalInstructions: args["original_instructions"]?.stringValue,
                    candidateInstructions: args["candidate_instructions"]?.stringValue,
                    targetRole: args["target_role"]?.stringValue,
                    repetitions: args["repetitions"]?.intValue,
                    optimization: decodeOptimizationSpecificationArgument(
                        args["specification_json"],
                        required: true
                    )
                ))
            case .createDraft:
                .createDraft
            case .updateDraft:
                try .updateDraft(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedDraftID: requiredUUID("expected_draft_id", args: args),
                    expectedDraftVersion: requiredInt("expected_draft_version", args: args),
                    expectedDraftDigest: requiredString("expected_draft_digest", args: args),
                    patch: PromptExperimentAgentDraftPatch(
                        title: args["title"]?.stringValue,
                        taskInput: args["task_input"]?.stringValue,
                        syntheticFixture: args["synthetic_fixture"]?.stringValue,
                        originalInstructions: args["original_instructions"]?.stringValue,
                        candidateInstructions: args["candidate_instructions"]?.stringValue,
                        targetRole: args["target_role"]?.stringValue,
                        repetitions: args["repetitions"]?.intValue,
                        optimization: decodeOptimizationSpecificationArgument(
                            args["specification_json"],
                            required: false
                        )
                    )
                )
            case .proposeSeal:
                try .proposeSeal(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedDraftID: requiredUUID("expected_draft_id", args: args),
                    expectedDraftVersion: requiredInt("expected_draft_version", args: args),
                    expectedDraftDigest: requiredString("expected_draft_digest", args: args)
                )
            case .status:
                try .status(experimentID: requiredUUID("experiment_id", args: args))
            case .run:
                try .run(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args)
                )
            case .wait:
                try .wait(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args),
                    timeoutSeconds: args["timeout_seconds"]?.doubleValue
                        ?? args["timeout_seconds"]?.intValue.map(TimeInterval.init)
                        ?? 120
                )
            case .cancel:
                try .cancel(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args)
                )
            case .read:
                try .read(experimentID: requiredUUID("experiment_id", args: args))
            case .clone, .cloneDraft:
                try .cloneDraft(experimentID: requiredUUID("experiment_id", args: args))
            case .rerun, .proposeRunAgain:
                try .proposeRunAgain(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args)
                )
            case .continueRevision, .proposeNextRevision:
                try .proposeNextRevision(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args),
                    candidateIndex: args["candidate_index"]?.intValue
                )
            }
        }

        private static func requiredString(_ key: String, args: [String: Value]) throws -> String {
            guard let value = args[key]?.stringValue, !value.isEmpty else {
                throw MCPError.invalidParams("\(key) is required")
            }
            return value
        }

        private static func requiredUUID(_ key: String, args: [String: Value]) throws -> UUID {
            let raw = try requiredString(key, args: args)
            guard let value = UUID(uuidString: raw) else { throw MCPError.invalidParams("\(key) must be a UUID") }
            return value
        }

        private static func requiredInt(_ key: String, args: [String: Value]) throws -> Int {
            guard let value = args[key]?.intValue else { throw MCPError.invalidParams("\(key) is required") }
            return value
        }

        private struct PromptExperimentOptimizationEnvelope: Codable {
            let schemaVersion: Int
            let specification: PromptExperimentOptimizationSpecification
        }

        private static func decodeOptimizationSpecificationArgument(
            _ value: Value?,
            required: Bool
        ) throws -> PromptExperimentOptimizationSpecification? {
            guard let value else {
                if required { throw MCPError.invalidParams("specification_json is required") }
                return nil
            }

            let data: Data
            switch value {
            case let .string(raw) where !raw.isEmpty:
                data = Data(raw.utf8)
            case .object:
                do {
                    data = try JSONEncoder().encode(value)
                } catch {
                    throw MCPError.invalidParams("Invalid specification_json: \(error.localizedDescription)")
                }
            default:
                throw MCPError.invalidParams("specification_json must be a JSON document string")
            }

            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let envelope = try decoder.decode(PromptExperimentOptimizationEnvelope.self, from: data)
                guard [1, 2, 3].contains(envelope.schemaVersion) else {
                    throw MCPError.invalidParams("Unsupported optimization specification schema \(envelope.schemaVersion)")
                }
                guard envelope.schemaVersion == 3
                    || (envelope.specification.stage == nil && envelope.specification.preparationCandidates == nil)
                else { throw MCPError.invalidParams("Preparation fields require specification schema 3.") }
                return envelope.specification
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.invalidParams("Invalid specification_json: \(error.localizedDescription)")
            }
        }

        static func encodeOptimizationSpecification(
            _ specification: PromptExperimentOptimizationSpecification
        ) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(PromptExperimentOptimizationEnvelope(
                schemaVersion: 3,
                specification: specification
            ))
            return String(decoding: data, as: UTF8.self)
        }

        static func responseValue(_ response: PromptExperimentAgentResponse, usesMCPApproval: Bool = false) throws -> Value {
            switch response {
            case let .capabilities(operations, targets, gepaRuntime, limitations):
                .object([
                    "operations": .array(operations.map(Value.string)),
                    "available_targets": .array(targets.map(targetValue)),
                    "gepa_runtime": .object([
                        "worker_protocol_version": .int(gepaRuntime.workerProtocolVersion),
                        "package_version": .string(gepaRuntime.packageVersion),
                        "pinned_revision": .string(gepaRuntime.pinnedRevision),
                        "python_version": .string(gepaRuntime.pythonVersion),
                        "worker_resource_available": .bool(gepaRuntime.workerResourceAvailable),
                        "bundled_runtime_available": .bool(gepaRuntime.bundledRuntimeAvailable),
                        "configured_python_executable": gepaRuntime.configuredPythonExecutable.map(Value.string) ?? .null,
                        "runtime_status": .string(gepaRuntime.runtimeStatus),
                        "preflight_behavior": .string("Before model execution, Run verifies the bundled provenance, exact CPython/GEPA metadata, dependency-free package contract, and worker import without a model call.")
                    ]),
                    "limitations": .array(limitations.map(Value.string)),
                    "mcp_adapter": .object([
                        "server": .string("bundled_rpce_headless"), "sdk_version": .string(PromptExperimentMCPConfiguration.sdkVersion),
                        "allowed_tools": .array(PromptExperimentMCPConfiguration.allowedTools.sorted().map(Value.string)),
                        "configuration": .string("execution.adapter=mcp_adapter; execution.mcp={tool_names:[...],component:system_prompt or tool_description_<selected tool>}; project_snapshot is required. Sealing resolves executable and schema fingerprints. Cold starts use preparation candidates before search."),
                        "maximum_tool_calls_per_evaluation": .int(1), "maximum_target_model_calls_per_evaluation": .int(2),
                        "network": .string("denied"), "source_workspace_writes": .bool(false)
                    ]),
                    "user_approval_required": .bool(true),
                    "native_approval_required": .bool(!usesMCPApproval)
                ])
            case let .records(records):
                try .object(["experiments": .array(records.map { try recordValue($0) })])
            case let .record(record, artifactTextBySHA256):
                try recordValue(record, artifactTextBySHA256: artifactTextBySHA256)
            case let .draft(experimentID, draft):
                try .object([
                    "experiment_id": .string(experimentID.uuidString),
                    "draft": draftValue(draft),
                    "next_action": .string("Revise with update_draft under the exact ID/version/digest, then propose_seal. For a new complete proposal, setup performs create/update/seal in one call.")
                ])
            case let .sealed(experimentID, plan):
                .object([
                    "experiment_id": .string(experimentID.uuidString),
                    "phase": .string(PromptExperimentPhase.awaitingApproval.rawValue),
                    "plan_revision": .int(plan.revision),
                    "plan_digest": .string(plan.digest),
                    "next_action": .string("Call run with this exact experiment_id and expected_plan_digest. Review and accept or decline the MCP form (external clients) or native card (Agent default). Acceptance starts execution automatically; revise the draft if changes are needed.")
                ])
            }
        }

        private static func draftValue(_ draft: PromptExperimentDraft) throws -> Value {
            try .object([
                "id": .string(draft.id.uuidString),
                "revision": .int(draft.revision),
                "version": .int(draft.optimisticVersion),
                "digest": .string(draft.contentDigest()),
                "title": .string(draft.title),
                "task_input": .string(draft.taskInput),
                "synthetic_fixture": .string(draft.syntheticFixture),
                "original_instructions": .string(draft.originalInstructions),
                "candidate_instructions": .string(draft.candidateInstructions),
                "target_selector": .string(draft.targetRole),
                "repetitions": .int(draft.repetitions),
                "optimization_specification_json": draft.optimization.map(encodeOptimizationSpecification).map(Value.string) ?? .null
            ])
        }

        private static func recordValue(
            _ record: PromptExperimentRecord,
            artifactTextBySHA256: [String: String] = [:]
        ) throws -> Value {
            var value: [String: Value] = [
                "experiment_id": .string(record.id.uuidString),
                "phase": .string(record.phase.rawValue),
                "status": .string(record.statusMessage),
                "plan_revisions": .array(record.plans.map { .int($0.revision) }),
                "attempts": .array(record.attempts.map {
                    attemptValue($0, artifactTextBySHA256: artifactTextBySHA256)
                })
            ]
            value["draft"] = try record.draft.map(draftValue) ?? .null
            let nextAction = switch record.phase {
            case .drafting:
                "Revise the returned draft under exact version/digest checks, then propose_seal."
            case .awaitingApproval:
                "Call run with the exact plan digest for user approval through MCP form elicitation (external clients) or the native card (Agent default). Decline and revise the draft to request changes."
            case .approved:
                "Call run with the exact plan digest to resume the already-approved run after interruption."
            case .running, .cancelling:
                "Call wait with the exact plan digest for bounded progress or terminal results; cancel remains available to the owning session."
            case .completed, .inconclusive, .cancelled:
                "Inspect results, then use continue/rerun/clone if the user wants another reviewed iteration."
            }
            value["next_action"] = .string(nextAction)
            if let plan = record.currentPlan {
                value["current_plan"] = sealedPlanValue(plan, approved: record.approval(for: plan) != nil)
            } else {
                value["current_plan"] = .null
            }
            return .object(value)
        }

        private static func sealedPlanValue(_ plan: PromptExperimentPlan, approved: Bool) -> Value {
            var value: [String: Value] = [
                "id": .string(plan.id.uuidString),
                "revision": .int(plan.revision),
                "digest": .string(plan.digest),
                "approved": .bool(approved),
                "schema_version": .int(plan.schemaVersion ?? PromptExperimentPlan.legacySchemaVersion),
                "engine": .string(plan.optimization?.gepa.engine ?? "legacy_fixed_comparison"),
                "environment_digest": .string(plan.environment.fixtureDigest),
                "environment_files": .array(plan.environment.fixtureFiles.map { .object([
                    "path": .string($0.path), "byte_count": .int($0.byteCount), "sha256": .string($0.sha256)
                ]) })
            ]
            if let optimization = plan.optimization {
                value["stage"] = .string(optimization.isPreparation ? "preparation" : "search")
                value["preparation_candidates"] = optimization.preparationCandidates.map { .array($0.map(Value.string)) } ?? .null
                value["objective"] = .string(optimization.objective)
                value["background"] = .string(optimization.background)
                value["examples"] = .array(optimization.examples.map { example in .object([
                    "id": .string(example.id),
                    "split": .string(example.split.rawValue),
                    "input": .string(example.input),
                    "expected_output": example.expectedOutput.map(Value.string) ?? .null,
                    "reviewer_notes": example.reviewerNotes.map(Value.string) ?? .null
                ]) })
                value["project_snapshot"] = optimization.projectSnapshot.map { snapshot in .object([
                    "source_root_path": .string(snapshot.sourceRootPath),
                    "included_paths": .array(snapshot.includedPaths.map(Value.string))
                ]) } ?? .null
                value["execution"] = .object([
                    "adapter": .string(optimization.execution.adapter.rawValue),
                    "target": plan.optimizationTargets?.execution.map(targetValue) ?? .null,
                    "instructions": .string(optimization.execution.instructions),
                    "mcp": optimization.execution.mcp.map { .object([
                        "tool_names": .array($0.toolNames.map(Value.string)), "component": .string($0.component),
                        "tool_definitions_json": $0.toolDefinitionsJson.map(Value.string) ?? .null,
                        "server_sha256": $0.serverSha256.map(Value.string) ?? .null
                    ]) } ?? .null
                ])
                value["evaluator"] = .object([
                    "kind": .string(optimization.evaluator.kind.rawValue),
                    "rubric": .string(optimization.evaluator.rubric),
                    "command": optimization.evaluator.command.map(Value.string) ?? .null,
                    "candidate_file_name": optimization.evaluator.candidateFileName.map(Value.string) ?? .null,
                    "minimum_score": .double(optimization.evaluator.minimumScore),
                    "maximum_score": .double(optimization.evaluator.maximumScore),
                    "judge_target": plan.optimizationTargets?.judge.map(targetValue) ?? .null
                ])
                var gepa: [String: Value] = [
                    "reflection_target": plan.optimizationTargets.map { targetValue($0.reflection) } ?? .null,
                    "max_evaluations": .int(optimization.gepa.maxEvaluations),
                    "experiment_wall_clock_deadline": .string("none"),
                    "reflection_minibatch_size": .int(optimization.gepa.reflectionMinibatchSize ?? 3),
                    "use_merge": .bool(optimization.gepa.useMerge ?? false),
                    "max_merge_invocations": .int(optimization.gepa.maxMergeInvocations ?? 5),
                    "skip_perfect_score": .bool(optimization.gepa.skipPerfectScore ?? true),
                    "random_seed": .int(optimization.gepa.randomSeed)
                ]
                if let legacyWallClock = optimization.gepa.maxWallClockSeconds {
                    gepa["legacy_max_wall_clock_seconds"] = .int(legacyWallClock)
                    gepa["experiment_wall_clock_deadline"] = .string("historic_sealed_limit")
                }
                value["gepa"] = .object(gepa)
            }
            return .object(value)
        }

        private static func targetValue(_ target: PromptExperimentResolvedTarget) -> Value {
            .object([
                "selector": .string(target.selector),
                "canonical_model_id": .string(target.canonicalSelectionID),
                "agent": .string(target.agentRaw),
                "model": .string(target.modelRaw),
                "display_name": .string(target.displayName)
            ])
        }

        private static func attemptValue(
            _ attempt: PromptExperimentAttempt,
            artifactTextBySHA256: [String: String]
        ) -> Value {
            let elapsed: TimeInterval? = if let submittedAt = attempt.submittedAt, let settledAt = attempt.settledAt {
                max(0, settledAt.timeIntervalSince(submittedAt))
            } else {
                nil
            }
            var value: [String: Value] = [
                "id": .string(attempt.id.uuidString),
                "plan_revision": attempt.planRevision.map(Value.int) ?? .null,
                "plan_digest": attempt.planDigest.map(Value.string) ?? .null,
                "condition": .string(attempt.condition.rawValue),
                "ordinal": .int(attempt.ordinal),
                "status": .string(attempt.status.rawValue),
                "status_text": .string(attempt.statusText),
                "committed_handoff": attempt.committedHandoff.map {
                    committedHandoffValue($0, artifactTextBySHA256: artifactTextBySHA256)
                } ?? .null,
                "assistant_output": attempt.assistantOutputEvidence.flatMap {
                    artifactTextBySHA256[$0.sha256]
                }.map(Value.string) ?? .null,
                "assistant_output_preview": attempt.assistantOutputPreview.map(Value.string) ?? .null,
                "assistant_output_evidence": attempt.assistantOutputEvidence.map(artifactValue) ?? .null,
                "handoff_unavailable_reason": attempt.handoffUnavailableReason.map(Value.string) ?? .null,
                "elapsed_seconds": elapsed.map(Value.double) ?? .null,
                "provider_token_usage": .string(
                    attempt.modelCalls == nil
                        ? "unavailable_from_context_builder_completion_contract"
                        : "per_invocation_in_model_calls; null_tokens_are_unavailable_not_zero"
                ),
                "legacy_unclassified_output_preview": attempt.outputPreview.map(Value.string) ?? .null,
                "error": attempt.error.map(Value.string) ?? .null,
                "optimization_result": attempt.optimizationResult.map {
                    optimizationResultValue($0, artifactTextBySHA256: artifactTextBySHA256)
                } ?? .null
            ]
            value["model_calls"] = attempt.modelCalls.map { calls in .array(calls.map { call in .object([
                "id": .string(call.id.uuidString), "role": .string(call.role),
                "target": targetValue(call.target), "state": .string(call.state.rawValue),
                "prompt_tokens": call.promptTokens.map(Value.int) ?? .null,
                "completion_tokens": call.completionTokens.map(Value.int) ?? .null
            ]) }) } ?? .null
            value["partial_evaluations"] = attempt.partialEvaluations.map { evaluations in .array(evaluations.map { partial in
                let evaluation = partial.evaluation
                return .object([
                    "id": .string(partial.id.uuidString),
                    "candidate_evidence": artifactValue(partial.candidateEvidence),
                    "candidate": artifactTextBySHA256[partial.candidateEvidence.sha256].map(Value.string) ?? .null,
                    "example_id": .string(evaluation.exampleID), "split": .string(evaluation.split.rawValue),
                    "score": evaluation.score.map(Value.double) ?? .null, "feedback": .string(evaluation.feedback),
                    "failure_kind": evaluation.failureKind.map { .string($0.rawValue) } ?? .null,
                    "output_evidence": evaluation.outputEvidence.map(artifactValue) ?? .null,
                    "output": evaluation.outputEvidence.flatMap { artifactTextBySHA256[$0.sha256] }.map(Value.string) ?? .null,
                    "elapsed_seconds": evaluation.elapsedSeconds.map(Value.double) ?? .null
                ])
            }) } ?? .null
            value["legacy_unclassified_evidence"] = attempt.evidence.map(artifactValue) ?? .null
            value["diagnostics"] = attempt.diagnostics.map(diagnosticValue) ?? .null
            return .object(value)
        }

        static func diagnosticValue(_ diagnostics: PromptExperimentAttemptDiagnostics) -> Value {
            let formatter = ISO8601DateFormatter()
            return .object([
                "process_observation": .string(diagnostics.processObservation.rawValue),
                "worker_pid": diagnostics.workerPID.map { .int(Int($0)) } ?? .null,
                "worker_process_identity": diagnostics.workerProcessIdentity.map(Value.string) ?? .null,
                "process_started_at": diagnostics.processStartedAt.map { .string(formatter.string(from: $0)) } ?? .null,
                "process_exited_at": diagnostics.processExitedAt.map { .string(formatter.string(from: $0)) } ?? .null,
                "process_exit_status": diagnostics.processExitStatus.map { .int(Int($0)) } ?? .null,
                "last_observed_at": .string(formatter.string(from: diagnostics.lastObservedAt)),
                "last_observed_event": .string(diagnostics.lastObservedEvent),
                "active_callback_id": diagnostics.activeCallbackID.map(Value.string) ?? .null,
                "active_callback_operation": diagnostics.activeCallbackOperation.map(Value.string) ?? .null,
                "linked_callback_runtime": diagnostics.linkedCallbackRuntime.map(runtimeLinkValue) ?? .null,
                "stderr_log_relative_path": diagnostics.stderrLogRelativePath.map(Value.string) ?? .null,
                "stdout_protocol_log_relative_path": diagnostics.stdoutProtocolLogRelativePath.map(Value.string) ?? .null,
                "stderr_log_byte_count": diagnostics.stderrLogByteCount.map(Value.int) ?? .null,
                "stderr_log_truncated": .bool(diagnostics.stderrLogTruncated),
                "protocol_log_byte_count": diagnostics.protocolLogByteCount.map(Value.int) ?? .null,
                "protocol_log_truncated": .bool(diagnostics.protocolLogTruncated),
                "pid_liveness_caveat": .string("A persisted PID is a historical observation only; never infer current liveness from it after restart or without a fresh event."),
                "payload_policy": .string("Protocol request/response bodies are excluded; arbitrary stderr is redacted."),
                "event_tail": .array(diagnostics.eventTail.map { event in .object([
                    "observed_at": .string(formatter.string(from: event.observedAt)),
                    "channel": .string(event.channel),
                    "event": .string(event.event),
                    "detail": event.detail.map(Value.string) ?? .null
                ]) })
            ])
        }

        private static func runtimeLinkValue(_ runtime: PromptExperimentRuntimeLink) -> Value {
            .object([
                "adapter": .string(runtime.adapter),
                "tab_id": runtime.tabID.map { .string($0.uuidString) } ?? .null,
                "run_id": runtime.runID.map { .string($0.uuidString) } ?? .null,
                "provider": runtime.provider.map(Value.string) ?? .null,
                "model": runtime.model.map(Value.string) ?? .null
            ])
        }

        private static func optimizationResultValue(
            _ result: PromptExperimentOptimizationResult,
            artifactTextBySHA256: [String: String]
        ) -> Value {
            .object([
                "engine": .string(result.engine),
                "assessment": .string(result.assessment),
                "upstream_revision": .string(result.upstreamRevision),
                "baseline_score": result.baselineScore.map(Value.double) ?? .null,
                "best_score": result.bestScore.map(Value.double) ?? .null,
                "best_candidate_index": result.bestCandidateIndex.map(Value.int) ?? .null,
                "total_evaluations": .int(result.totalEvaluations),
                "wall_time_seconds": result.wallTimeSeconds.map(Value.double) ?? .null,
                "proposer_usage": .string(result.proposerUsage),
                "run_directory_relative_path": result.runDirectoryRelativePath.map(Value.string) ?? .null,
                "raw_result_evidence": result.rawResultEvidence.map(artifactValue) ?? .null,
                "candidates": .array(result.candidates.map { candidate in
                    .object([
                        "index": .int(candidate.index),
                        "parents": .array(candidate.parentIndices.map(Value.int)),
                        "score": candidate.aggregateScore.map(Value.double) ?? .null,
                        "is_baseline": .bool(candidate.isBaseline),
                        "is_best": .bool(candidate.isBest),
                        "candidate": artifactTextBySHA256[candidate.candidateEvidence.sha256].map(Value.string) ?? .null,
                        "preview": .string(candidate.candidatePreview),
                        "evidence": artifactValue(candidate.candidateEvidence)
                    ])
                }),
                "evaluations": .array(result.evaluations.map { evaluation in
                    .object([
                        "candidate_index": .int(evaluation.candidateIndex),
                        "example_id": .string(evaluation.exampleID),
                        "split": .string(evaluation.split.rawValue),
                        "score": evaluation.score.map(Value.double) ?? .null,
                        "feedback": .string(evaluation.feedback),
                        "failure_kind": evaluation.failureKind.map { .string($0.rawValue) } ?? .null,
                        "output": evaluation.outputEvidence.flatMap { artifactTextBySHA256[$0.sha256] }.map(Value.string) ?? .null,
                        "elapsed_seconds": evaluation.elapsedSeconds.map(Value.double) ?? .null
                    ])
                })
            ])
        }

        private static func committedHandoffValue(
            _ handoff: PromptExperimentCommittedHandoff,
            artifactTextBySHA256: [String: String]
        ) -> Value {
            .object([
                "prompt": artifactTextBySHA256[handoff.promptEvidence.sha256].map(Value.string) ?? .null,
                "prompt_preview": .string(handoff.promptPreview),
                "prompt_evidence": artifactValue(handoff.promptEvidence),
                "selection": selectionValue(handoff.selection),
                "selection_revision": .int(Int(clamping: handoff.selectionRevision)),
                "used_agent_output_as_prompt": .bool(handoff.usedAgentOutputAsPrompt)
            ])
        }

        private static func artifactValue(_ artifact: PromptExperimentArtifactReference) -> Value {
            .object([
                "sha256": .string(artifact.sha256),
                "relative_path": .string(artifact.relativePath),
                "byte_count": .int(artifact.byteCount)
            ])
        }

        private static func selectionValue(_ selection: StoredSelection) -> Value {
            let slices = selection.slices.keys.sorted().map { path in
                Value.object([
                    "path": .string(path),
                    "ranges": .array(selection.slices[path, default: []].map { range in
                        .object([
                            "start_line": .int(range.start),
                            "end_line": .int(range.end),
                            "description": range.description.map(Value.string) ?? .null
                        ])
                    })
                ])
            }
            return .object([
                "selected_paths": .array(selection.selectedPaths.map(Value.string)),
                "manual_codemap_paths": .array(selection.manualCodemapPaths.map(Value.string)),
                "slices": .array(slices),
                "codemap_auto_enabled": .bool(selection.codemapAutoEnabled)
            ])
        }
    #endif

    private static func executeShareThoughts(
        args: [String: Value],
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        guard let thoughts = args["thoughts"]?.stringValue else {
            throw MCPError.invalidParams("thoughts is required")
        }
        let title = args["title"]?.stringValue

        let connectionID = try await dependencies.requireAgentModeConnection(MCPWindowToolName.shareThoughts)
        let targetWindow = try dependencies.requireTargetWindow()
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .shareThoughts)

        // Invariant: background tool updates are tab-scoped and must not steal tab focus.
        try await MainActor.run {
            try targetWindow.agentModeViewModel.shareThoughts(
                thoughts,
                title: title,
                target: target
            )
        }

        return .object([
            "ok": .bool(true),
            "context_id": .string(target.tabID.uuidString)
        ])
    }

    private static func executeSetStatus(
        args: [String: Value],
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        let connectionID = try await dependencies.requireAgentModeConnection(MCPWindowToolName.setStatus)
        let trimmedSessionName = args["session_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionNameToApply = (trimmedSessionName?.isEmpty == false) ? trimmedSessionName : nil

        let targetWindow = try dependencies.requireTargetWindow()
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .setStatus)

        // Invariant: background status updates are tab-scoped and must not steal tab focus.
        try await MainActor.run {
            if let sessionNameToApply {
                try targetWindow.agentModeViewModel.renameSession(
                    target: target,
                    to: sessionNameToApply
                )
            }
        }

        var result: [String: Value] = [
            "ok": .bool(true),
            "context_id": .string(target.tabID.uuidString),
            "session_name_applied": .bool(sessionNameToApply != nil)
        ]
        if let sessionNameToApply {
            result["session_name"] = .string(sessionNameToApply)
        }
        return .object(result)
    }

    static func resolvedInstructionWaitTimeoutSeconds(_ value: Value?) throws -> TimeInterval {
        let timeout = value?.intValue.map(TimeInterval.init) ?? MCPTimeoutPolicy.nextUserInstructionDefaultWaitSeconds
        guard timeout > 0 else {
            throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
        }
        return timeout
    }

    private static func executeWaitForNextInstruction(
        args: [String: Value],
        dependencies: MCPAppPhysicalCapabilityAdapters.Execution
    ) async throws -> Value {
        let prompt = args["prompt"]?.stringValue
        let timeout = try resolvedInstructionWaitTimeoutSeconds(args["timeout_seconds"])

        let targetWindow = try dependencies.requireTargetWindow()
        let connectionID = ServerNetworkManager.currentConnectionID
        let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .waitForInstruction)

        // Invariant: waiting state is stored on the target session; do not switch tabs here.
        let response = try await targetWindow.agentModeViewModel.waitForNextUserInstruction(
            target: target,
            prompt: prompt,
            timeoutSeconds: timeout
        )

        var result: [String: Value] = [
            "timed_out": .bool(response.timedOut),
            "elapsed_seconds": .int(response.elapsedSeconds)
        ]
        if let text = response.text {
            result["instruction"] = .string(text)
        } else {
            result["instruction"] = .null
        }

        return .object(result)
    }
}
