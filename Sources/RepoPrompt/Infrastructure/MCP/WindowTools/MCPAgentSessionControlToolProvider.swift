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
                Create and revise a native Prompt Experiment draft owned by this Agent session.

                Start with `op=capabilities`. Supported mutations are bounded draft creation/update,
                sealing a proposal for native review, and proposing the next revision after settlement.
                This tool cannot approve, start, cancel, score, or promote an experiment. The user must
                approve the exact sealed digest and press Run in Prompt Experiment Studio.
                """,
                annotations: .repoPromptLocalEphemeralState,
                inputSchema: .object(
                    properties: [
                        "op": .string(description: "capabilities | list | create_draft | update_draft | propose_seal | read | propose_next_revision"),
                        "experiment_id": .string(description: "Experiment UUID for record operations."),
                        "expected_draft_id": .string(description: "Exact draft UUID returned by create/read/update."),
                        "expected_draft_version": .integer(description: "Exact optimistic draft version returned by create/read/update."),
                        "expected_draft_digest": .string(description: "Exact draft digest returned by create/read/update."),
                        "expected_plan_digest": .string(description: "Exact current sealed plan digest for proposing a next revision."),
                        "title": .string(description: "Optional draft title replacement."),
                        "task_input": .string(description: "Optional fixed task replacement."),
                        "synthetic_fixture": .string(description: "Optional synthetic fixture replacement. Loaded workspace content is unsupported."),
                        "original_instructions": .string(description: "Optional original instructions replacement."),
                        "candidate_instructions": .string(description: "Optional candidate instructions replacement."),
                        "target_role": .string(description: "Optional catalog selector: a task role such as explore or an exact compound model_id returned by capabilities, such as codexExec:<model-and-effort>."),
                        "repetitions": .integer(description: "Optional repetitions per condition, 1 through 3.")
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
            guard let rawOperation = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let operation = PromptExperimentAgentOperation(rawValue: rawOperation)
            else {
                throw MCPError.invalidParams("Unsupported Prompt Experiment operation. Call op=capabilities for the bounded schema; approval and run operations do not exist.")
            }
            let connectionID = try await dependencies.requireAgentModeConnection(MCPWindowToolName.promptExperiment)
            let targetWindow = try dependencies.requireTargetWindow()
            let target = try await dependencies.resolveAgentModeTabID(args, connectionID, .promptExperiment)
            guard let identity = target.identity,
                  let sessionID = identity.sessionID,
                  identity.persistentBindingGeneration != nil
            else {
                throw MCPError.invalidParams("prompt_experiment requires a durably bound Agent session identity.")
            }
            try targetWindow.agentModeViewModel.validatePromptExperimentTarget(target)

            let service = PromptExperimentService.live(windowState: targetWindow)
            await service.load()
            try targetWindow.agentModeViewModel.validatePromptExperimentTarget(target)
            let owner = PromptExperimentAgentOwner(controllerSessionID: sessionID, sourceTabID: target.tabID)
            let interface = PromptExperimentAgentInterface(service: service)
            let command: PromptExperimentAgentCommand = switch operation {
            case .capabilities:
                .capabilities
            case .list:
                .list
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
                        repetitions: args["repetitions"]?.intValue
                    )
                )
            case .proposeSeal:
                try .proposeSeal(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedDraftID: requiredUUID("expected_draft_id", args: args),
                    expectedDraftVersion: requiredInt("expected_draft_version", args: args),
                    expectedDraftDigest: requiredString("expected_draft_digest", args: args)
                )
            case .read:
                try .read(experimentID: requiredUUID("experiment_id", args: args))
            case .proposeNextRevision:
                try .proposeNextRevision(
                    experimentID: requiredUUID("experiment_id", args: args),
                    expectedPlanDigest: requiredString("expected_plan_digest", args: args)
                )
            }
            return try await responseValue(interface.execute(command, owner: owner))
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

        private static func responseValue(_ response: PromptExperimentAgentResponse) throws -> Value {
            switch response {
            case let .capabilities(operations, targets, limitations):
                .object([
                    "operations": .array(operations.map(Value.string)),
                    "available_targets": .array(targets.map(targetValue)),
                    "limitations": .array(limitations.map(Value.string)),
                    "native_approval_required": .bool(true)
                ])
            case let .records(records):
                try .object(["experiments": .array(records.map { try recordValue($0) })])
            case let .record(record, artifactTextBySHA256):
                try recordValue(record, artifactTextBySHA256: artifactTextBySHA256)
            case let .draft(experimentID, draft):
                try .object([
                    "experiment_id": .string(experimentID.uuidString),
                    "draft": draftValue(draft),
                    "next_action": .string("Use update_draft with the exact ID/version/digest, then propose_seal. The user approves only in the native Studio.")
                ])
            case let .sealed(experimentID, plan):
                .object([
                    "experiment_id": .string(experimentID.uuidString),
                    "phase": .string(PromptExperimentPhase.awaitingApproval.rawValue),
                    "plan_revision": .int(plan.revision),
                    "plan_digest": .string(plan.digest),
                    "native_action_required": .string("Ask the user to review and approve this exact digest in Prompt Experiment Studio. This tool cannot approve or run it.")
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
                "repetitions": .int(draft.repetitions)
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
            if let plan = record.currentPlan {
                value["current_plan"] = .object([
                    "id": .string(plan.id.uuidString),
                    "revision": .int(plan.revision),
                    "digest": .string(plan.digest),
                    "approved": .bool(record.approval(for: plan) != nil)
                ])
            } else {
                value["current_plan"] = .null
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
                "provider_token_usage": .string("unavailable_from_context_builder_completion_contract"),
                "legacy_unclassified_output_preview": attempt.outputPreview.map(Value.string) ?? .null,
                "error": attempt.error.map(Value.string) ?? .null
            ]
            value["legacy_unclassified_evidence"] = attempt.evidence.map(artifactValue) ?? .null
            return .object(value)
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
