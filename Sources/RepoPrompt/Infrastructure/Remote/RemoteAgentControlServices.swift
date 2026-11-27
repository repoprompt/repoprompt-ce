import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptRemoteProtocol

enum RemoteAgentControlServiceError: LocalizedError {
    case unsupportedProtocol(Int)
    case invalidWorkspaceID
    case workspaceNotFound
    case workspaceNotOpen
    case sessionIDRequired
    case sessionNotFound
    case interactionIDRequired
    case invalidInteractionID
    case messageRequired
    case contextBuilderUnavailable
    case commandRejected(String)
    case partialSuccess(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(version):
            "Unsupported remote protocol version \(version)."
        case .invalidWorkspaceID:
            "A valid workspace ID is required."
        case .workspaceNotFound:
            "The requested workspace was not found."
        case .workspaceNotOpen:
            "The requested workspace is saved but is not open in a desktop window."
        case .sessionIDRequired:
            "A session ID is required for this command."
        case .sessionNotFound:
            "The requested session is not available."
        case .interactionIDRequired:
            "An interaction ID is required for this command."
        case .invalidInteractionID:
            "The interaction ID is invalid or no longer pending."
        case .messageRequired:
            "A non-empty message is required."
        case .contextBuilderUnavailable:
            "Context Builder is not available in the active desktop window."
        case let .commandRejected(message):
            message
        case let .partialSuccess(message):
            message
        }
    }
}

enum RemoteMutationFailureDisposition: Equatable {
    case rollbackProvisionalSession
    case preserveExistingSession
}

enum RemoteMutationFailurePolicy {
    static let mutationOperations: [RemoteCommandOperation] = [
        .startRun,
        .configureSession,
        .configureTools,
        .followUp,
        .steer,
        .uploadAttachment,
        .respond,
        .cancel,
        .resume,
        .contextBuilder
    ]

    static func disposition(for operation: RemoteCommandOperation) -> RemoteMutationFailureDisposition {
        switch operation {
        case .startRun:
            .rollbackProvisionalSession
        case .configureSession, .configureTools, .followUp, .steer, .respond, .cancel, .resume, .contextBuilder:
            .preserveExistingSession
        case .registerNotifications, .uploadAttachment:
            .preserveExistingSession
        }
    }
}

enum RemoteWorkspaceActivationDecision: Equatable {
    case reuseExistingWindow
    case openNewWindow
    case workspaceNotFound
}

enum RemoteWorkspaceActivationPlanner {
    static func decision(
        workspaceExists: Bool,
        reusableWindowExists: Bool
    ) -> RemoteWorkspaceActivationDecision {
        if reusableWindowExists { return .reuseExistingWindow }
        if workspaceExists { return .openNewWindow }
        return .workspaceNotFound
    }
}

@MainActor
protocol RemoteAgentControlService: AnyObject {
    func execute(
        _ request: RemoteCommandRequest,
        authorizeDispatch: @escaping RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse
    func clearAttachmentUploads()
}

/// Direct in-process adapter for paired Remote commands and Agent Mode session writers.
@MainActor
final class WindowRemoteAgentControlService: RemoteAgentControlService {
    private weak var windowStatesManager: WindowStatesManager?
    private var uploads = RemoteAttachmentUploads()
    private var uploadExpiry: Task<Void, Never>?

    init(windowStatesManager: WindowStatesManager) {
        self.windowStatesManager = windowStatesManager
    }

    func clearAttachmentUploads() {
        uploads = RemoteAttachmentUploads()
        uploadExpiry?.cancel()
        uploadExpiry = nil
    }

    func execute(
        _ request: RemoteCommandRequest,
        authorizeDispatch: @escaping RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        do {
            guard RemoteProtocol.supports(request.protocolVersion) else {
                throw RemoteAgentControlServiceError.unsupportedProtocol(request.protocolVersion)
            }

            try authorizeDispatch()
            let files: [RemoteAttachmentUploads.File]
            if let ids = request.attachmentIDs {
                guard [.startRun, .followUp, .resume].contains(request.operation) else {
                    throw RemoteAgentControlServiceError.commandRejected("Attachments can be sent with a new message after the current run stops.")
                }
                files = try uploads.take(submissionID: request.commandID, ids: ids)
            } else {
                files = []
            }

            switch request.operation {
            case .uploadAttachment:
                guard let chunk = request.attachmentChunk else {
                    throw RemoteAgentControlServiceError.commandRejected("The attachment chunk is missing.")
                }
                try uploads.append(chunk)
                uploadExpiry?.cancel()
                uploadExpiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    self?.clearAttachmentUploads()
                }
                return RemoteCommandResponse(commandID: request.commandID, accepted: true)
            case .startRun:
                return try await start(request, files: files, authorizeDispatch: authorizeDispatch)
            case .configureSession:
                return try await configureSession(request, authorizeDispatch: authorizeDispatch)
            case .configureTools:
                return try await configureTools(request, authorizeDispatch: authorizeDispatch)
            case .followUp, .steer, .resume:
                return try await continueRun(request, files: files, authorizeDispatch: authorizeDispatch)
            case .respond:
                return try await respond(request, authorizeDispatch: authorizeDispatch)
            case .cancel:
                return try await cancel(request, authorizeDispatch: authorizeDispatch)
            case .contextBuilder:
                return try await contextBuilder(request, authorizeDispatch: authorizeDispatch)
            case .registerNotifications:
                throw RemoteAgentControlServiceError.commandRejected(
                    "Notification registration must be handled by the Remote gateway."
                )
            }
        } catch let error as RemoteAgentControlServiceError {
            throw error
        } catch let error as MCPError {
            throw RemoteAgentControlServiceError.commandRejected(
                Self.remoteRejectionMessage(for: error)
            )
        }
    }

    static func remoteRejectionMessage(for error: MCPError) -> String {
        switch error {
        case let .invalidParams(detail):
            switch detail ?? "The requested command is not valid for this agent session." {
            case AgentModeViewModel.mcpResidentTargetError, AgentModeViewModel.mcpResidentBusyError:
                "This chat is busy or changing. Refresh the conversation and try again."
            case AgentModeViewModel.mcpResidentProtectedError:
                "Respond to the pending request or stop the run before sending another message."
            case AgentModeViewModel.mcpResidentUnconfirmedError:
                "The message may already be in the chat. Refresh the conversation before sending it again."
            case let message:
                message
            }
        case .urlElicitationRequired:
            "The agent requires an additional sign-in or setup step on the Mac."
        case .connectionClosed, .transportError:
            "The Mac lost its connection to the agent while delivering this command. Try again."
        case .invalidRequest, .internalError, .parseError, .methodNotFound, .serverError:
            "The Mac could not deliver this command to the agent session."
        }
    }

    private func start(
        _ request: RemoteCommandRequest,
        files: [RemoteAttachmentUploads.File],
        authorizeDispatch: @escaping RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let workspaceID = try parseWorkspaceID(request.workspaceID)
        let message = try requiredMessage(request.message, allowsEmpty: !files.isEmpty)
        let workflow: AgentWorkflowDefinition?
        if let workflowID = request.workflowID {
            guard let resolvedWorkflow = AgentWorkflowStore.shared.resolveWorkflowReference(workflowID) else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "The requested workflow is no longer available on the Mac."
                )
            }
            workflow = resolvedWorkflow
        } else {
            workflow = nil
        }
        let context = try await activateWorkspace(workspaceID, authorizeDispatch: authorizeDispatch)
        try authorizeDispatch()
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: "Remote run",
            expectedWorkspaceID: workspaceID
        )

        do {
            guard let sessionID = target.sessionID else {
                throw RemoteAgentControlServiceError.sessionNotFound
            }
            let selection = try await context.agentMode.resolveRemoteLaunchSelection(
                tabID: target.tabID,
                agentRaw: request.agentID,
                modelRaw: request.modelID,
                reasoningEffortRaw: request.reasoningEffort
            )
            try context.agentMode.requireCurrentMCPWorkspaceTarget(target, expectedWorkspaceID: workspaceID)
            try authorizeDispatch()
            let attachments = try await importAttachments(files, sessionID: sessionID, workspaceID: workspaceID, in: context)
            _ = try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                target: target,
                message: message,
                metadata: .init(connectionID: nil, clientName: nil, windowID: nil),
                agentModeVM: context.agentMode,
                agentRaw: selection.agentRaw,
                modelRaw: selection.modelRaw,
                reasoningEffortRaw: selection.reasoningEffortRaw,
                taskLabelKind: .pair,
                workflow: workflow,
                remoteAttachments: attachments,
                remoteInterviewFirst: request.interviewFirst == true,
                validateDispatch: authorizeDispatch,
                workspaceAuthority: .init(
                    target: target, expectedWorkspaceID: workspaceID, allowMatchingControlledSession: false
                )
            )
            let resolved = context.agentMode.currentRemoteSelection(tabID: target.tabID, sessionID: sessionID)
                ?? selection
            context.agentMode.mcpAcceptSessionTarget(target)
            let response = await response(
                request: request,
                workspaceID: workspaceID,
                sessionID: sessionID,
                context: context
            )
            return RemoteCommandResponse(
                commandID: response.commandID,
                accepted: response.accepted,
                workspaceID: response.workspaceID,
                sessionID: response.sessionID,
                runState: response.runState,
                message: response.message,
                eventCursor: response.eventCursor,
                resolvedSelection: RemoteAgentSelection(
                    agentID: resolved.agentRaw,
                    modelID: resolved.modelRaw,
                    reasoningEffort: resolved.reasoningEffortRaw
                )
            )
        } catch {
            switch RemoteMutationFailurePolicy.disposition(for: request.operation) {
            case .rollbackProvisionalSession:
                let discarded = await context.agentMode.mcpDiscardSessionTarget(target)
                guard discarded == .complete else {
                    throw RemoteAgentControlServiceError.partialSuccess(
                        "The remote run could not start and provisional session cleanup was incomplete."
                    )
                }
            case .preserveExistingSession:
                break
            }
            throw error
        }
    }

    private func configureTools(
        _ request: RemoteCommandRequest,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        guard let mutation = request.toolMutation else {
            throw RemoteAgentControlServiceError.commandRejected("A tool setting mutation is required.")
        }

        let context: WindowContext
        if let sessionID = request.sessionID {
            context = try await contextForSession(
                sessionID, requestedWorkspaceID: request.workspaceID, authorizeDispatch: authorizeDispatch
            )
            let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
                tabID: nil,
                sessionID: sessionID,
                createIfNeeded: true,
                sessionName: nil,
                expectedWorkspaceID: workspaceID(for: context, fallback: request.workspaceID),
                purpose: .remoteCommand
            )
            defer { context.agentMode.mcpAcceptSessionTarget(target) }
            guard let session = context.agentMode.sessions[target.tabID],
                  session.activeAgentSessionID == sessionID
            else { throw RemoteAgentControlServiceError.sessionNotFound }
            guard session.selectedAgent == .codexExec else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "Tool controls are only available for Codex chats."
                )
            }
        } else {
            context = try await activateWorkspace(parseWorkspaceID(request.workspaceID), authorizeDispatch: authorizeDispatch)
        }

        if let manager = windowStatesManager,
           manager.allWindows.contains(where: {
               !$0.isClosing && !$0.agentModeViewModel.remoteCodexToolBinding().isMutable
           })
        {
            throw RemoteAgentControlServiceError.commandRejected(
                "Tool controls are locked during an active Codex run."
            )
        }
        try authorizeDispatch()
        let updatedBinding = try context.agentMode.mcpApplyRemoteCodexToolMutation(
            settingID: mutation.settingID,
            enabled: mutation.enabled,
            expectedRevision: mutation.expectedRevision
        )
        return try RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: workspaceID(for: context, fallback: request.workspaceID).uuidString,
            sessionID: request.sessionID,
            message: "Codex tool settings updated.",
            resolvedToolCatalog: DesktopRemoteCatalogService.toolCatalog(
                binding: updatedBinding,
                isMutable: true
            )
        )
    }

    private func configureSession(
        _ request: RemoteCommandRequest,
        authorizeDispatch: @escaping RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        guard request.agentID != nil || request.modelID != nil || request.reasoningEffort != nil else {
            throw RemoteAgentControlServiceError.commandRejected(
                "Choose an agent, model, or reasoning effort to configure."
            )
        }
        let context = try await contextForSession(
            sessionID, requestedWorkspaceID: request.workspaceID, authorizeDispatch: authorizeDispatch
        )
        let expectedWorkspaceID = try workspaceID(for: context, fallback: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            expectedWorkspaceID: expectedWorkspaceID,
            purpose: .remoteCommand
        )
        defer { context.agentMode.mcpAcceptSessionTarget(target) }
        let resolved = try await context.agentMode.mcpConfigureRemoteSession(
            tabID: target.tabID,
            sessionID: sessionID,
            agentRaw: request.agentID,
            modelRaw: request.modelID,
            reasoningEffortRaw: request.reasoningEffort,
            validateDispatch: authorizeDispatch,
            workspaceAuthority: .init(
                target: target,
                expectedWorkspaceID: expectedWorkspaceID,
                allowMatchingControlledSession: false
            )
        )
        let workspaceID = try workspaceID(for: context, fallback: request.workspaceID)
        let response = await response(
            request: request,
            workspaceID: workspaceID,
            sessionID: sessionID,
            context: context
        )
        return RemoteCommandResponse(
            commandID: response.commandID,
            accepted: response.accepted,
            workspaceID: response.workspaceID,
            sessionID: response.sessionID,
            runState: response.runState,
            message: response.message,
            eventCursor: response.eventCursor,
            resolvedSelection: RemoteAgentSelection(
                agentID: resolved.agentRaw,
                modelID: resolved.modelRaw,
                reasoningEffort: resolved.reasoningEffortRaw
            )
        )
    }

    private func continueRun(
        _ request: RemoteCommandRequest,
        files: [RemoteAttachmentUploads.File],
        authorizeDispatch: @escaping RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let message = try requiredMessage(request.message, allowsEmpty: !files.isEmpty)
        let context = try await contextForSession(
            sessionID, requestedWorkspaceID: request.workspaceID, authorizeDispatch: authorizeDispatch
        )
        let expectedWorkspaceID = try workspaceID(for: context, fallback: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: true,
            sessionName: nil,
            expectedWorkspaceID: expectedWorkspaceID,
            purpose: .remoteCommand
        )
        defer { context.agentMode.mcpAcceptSessionTarget(target) }
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        let validateTarget: RemoteDispatchAuthorization = {
            try authorizeDispatch()
            guard self.windowStatesManager?.window(withID: context.window.windowID) === context.window,
                  !context.window.isClosing, !WindowStatesManager.shared.isTerminating
            else {
                throw RemoteAgentControlServiceError.sessionNotFound
            }
            try context.agentMode.requireCurrentMCPWorkspaceTarget(target, expectedWorkspaceID: expectedWorkspaceID)
        }
        try validateTarget()
        if !files.isEmpty, session.runState.isActive || session.instructionContinuation != nil {
            throw RemoteAgentControlServiceError.commandRejected("Wait for the current run to finish before sending attachments.")
        }
        let attachments = try await importAttachments(files, sessionID: sessionID, workspaceID: expectedWorkspaceID, in: context)
        try validateTarget()
        if context.agentMode.mcpRuntime.controlledWriter(sessionID: sessionID)?.session === session {
            _ = try await context.agentMode.mcpDispatchInstruction(
                sessionID: sessionID,
                text: message,
                allowStartingRun: true,
                remoteAttachments: attachments,
                validateInitialStart: validateTarget
            )
        } else {
            _ = try await context.agentMode.submitRemoteSessionMessage(
                to: session, sessionID: sessionID, workspaceID: expectedWorkspaceID,
                text: message, attachments: attachments, validateDispatch: validateTarget
            )
        }
        return await response(
            request: request,
            workspaceID: expectedWorkspaceID,
            sessionID: sessionID,
            context: context
        )
    }

    private func respond(
        _ request: RemoteCommandRequest,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let interactionID = try requiredInteractionID(request.interactionID)
        let context = try await contextForSession(
            sessionID, requestedWorkspaceID: request.workspaceID, authorizeDispatch: authorizeDispatch
        )
        let expectedWorkspaceID = try workspaceID(for: context, fallback: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: false,
            sessionName: nil,
            expectedWorkspaceID: expectedWorkspaceID,
            purpose: .remoteCommand
        )
        defer { context.agentMode.mcpAcceptSessionTarget(target) }
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        try context.agentMode.requireCurrentMCPWorkspaceTarget(
            target, expectedWorkspaceID: expectedWorkspaceID
        )
        guard let interaction = context.agentMode.mcpRuntime.mcpPendingInteraction(for: session),
              interaction.id == interactionID,
              interaction.kind != .instruction
        else {
            throw RemoteAgentControlServiceError.invalidInteractionID
        }
        let summary = AgentModeRemoteSessionQueryService.projectInteraction(
            interaction,
            createdAt: session.lastActivityAt,
            supportsPlainApproval: session.pendingApproval?.supportsPlainApprove ?? true,
            macOnlyApprovalID: session.pendingWorktreeMergeReview?.id ?? session.pendingPermissionsRequest?.id,
            requiresLocalUserInput: session.pendingUserInputRequest?.questions.contains(where: \.isLegacyMCPToolApproval) == true
        )
        if let reason = summary?.responseUnavailableReason {
            throw RemoteAgentControlServiceError.commandRejected(reason)
        }
        let payload: AgentMCPInteractionResponsePayload
        if let questionAnswers = request.questionAnswers {
            guard let questionnaire = summary?.questionnaire,
                  request.answers.isEmpty, request.secret == nil, request.message == nil, request.decision == nil
            else {
                throw RemoteAgentControlServiceError.commandRejected("The pending question does not accept these answers.")
            }
            payload = try Self.questionResponsePayload(
                questionAnswers, questionnaire: questionnaire,
                userInput: interaction.kind == .userInput ? session.pendingUserInputRequest : nil
            )
        } else {
            guard (summary?.questionnaire?.questions.count ?? 0) <= 1 else {
                throw RemoteAgentControlServiceError.commandRejected("Answer every question before submitting.")
            }
            payload = try Self.plainInteractionPayload(request, userInput: session.pendingUserInputRequest)
        }
        guard let command = try context.agentMode.runtimeCommand(sessionID: sessionID),
              command.writer.session === session
        else {
            throw RemoteAgentControlServiceError.sessionNotFound
        }
        try authorizeDispatch()
        try context.agentMode.applyBoundInteractionResponse(
            kind: interaction.kind,
            interactionID: interactionID,
            payload: payload,
            command: command,
            validateResolution: Self.requireRemoteInteractionResolution
        )
        return try await response(
            request: request,
            workspaceID: workspaceID(for: context, fallback: request.workspaceID),
            sessionID: sessionID,
            context: context
        )
    }

    private static func plainInteractionPayload(
        _ request: RemoteCommandRequest, userInput: AgentRequestUserInputRequest?
    ) throws -> AgentMCPInteractionResponsePayload {
        var answers = request.answers
        if let secret = request.secret {
            guard let question = userInput?.questions.first(where: { $0.isSecret }) else {
                throw RemoteAgentControlServiceError.commandRejected(
                    "A secret can only be submitted for a pending secure-entry question."
                )
            }
            // Keep the secret in this one-shot in-memory payload only. It is
            // never placed in text, logs, snapshots, events, or credentials.
            answers[question.id] = [secret]
        }
        let responseText = request.secret == nil ? request.message ?? request.decision : nil
        let responseArgument: AgentModeViewModel.MCPInteractionResponsePayload.ResponseArgument =
            responseText.map(AgentModeViewModel.MCPInteractionResponsePayload.ResponseArgument.scalar) ?? .missing
        return AgentMCPInteractionResponsePayload(
            text: responseText,
            skip: request.decision?.lowercased() == "skip",
            explicitSkip: request.decision?.lowercased() == "skip",
            responseArgument: responseArgument,
            amendment: nil,
            answersByQuestionID: answers
        )
    }

    static func questionResponsePayload(
        _ answers: [String: RemoteQuestionAnswer],
        questionnaire: RemoteQuestionnaire,
        userInput: AgentRequestUserInputRequest?
    ) throws -> AgentMCPInteractionResponsePayload {
        let invalidAnswer = RemoteAgentControlServiceError.commandRejected("Check your answers and try again.")
        guard Set(answers.keys) == Set(questionnaire.questions.map(\.id)) else { throw invalidAnswer }
        var questionDrafts: [String: AgentAskUserAnswer] = [:]
        var inputDrafts: [String: AgentRequestUserInputQuestionDraft] = [:]
        for question in questionnaire.questions {
            guard let answer = answers[question.id], question.accepts(answer) else { throw invalidAnswer }
            let indices = answer.selectedOptionIndices
            if userInput != nil {
                inputDrafts[question.id] = .init(selectedOptionIndex: indices.first, note: answer.normalizedText ?? "")
            } else {
                questionDrafts[question.id] = .init(
                    answers: [],
                    selectedOptions: indices.map { question.options[$0].label },
                    customResponse: answer.normalizedText,
                    skipped: answer.skipped
                )
            }
        }
        return AgentMCPInteractionResponsePayload(
            text: nil, skip: false, responseArgument: .missing, amendment: nil,
            answersByQuestionID: userInput?.buildResponse(from: inputDrafts).answersByQuestionID ?? [:],
            askUserAnswersByQuestionID: questionDrafts
        )
    }

    static func requireRemoteInteractionResolution(_ resolution: AgentPendingInteractionResolution) throws {
        switch resolution {
        case .askUser, .askUserSkip, .userInput, .approval(_, .accept), .approval(_, .decline), .approval(_, .cancel):
            return
        case .mcpElicitation, .worktreeMerge, .permissions, .approval:
            throw RemoteAgentControlServiceError.commandRejected("Review this decision on your Mac.")
        }
    }

    private func cancel(
        _ request: RemoteCommandRequest,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let sessionID = try requiredSessionID(request.sessionID)
        let context = try await contextForSession(
            sessionID, requestedWorkspaceID: request.workspaceID, authorizeDispatch: authorizeDispatch
        )
        let expectedWorkspaceID = try workspaceID(for: context, fallback: request.workspaceID)
        let target = try await context.agentMode.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: sessionID,
            createIfNeeded: false,
            sessionName: nil,
            expectedWorkspaceID: expectedWorkspaceID,
            purpose: .remoteCommand
        )
        defer { context.agentMode.mcpAcceptSessionTarget(target) }
        let session = await context.agentMode.ensureSessionReady(tabID: target.tabID)
        try context.agentMode.requireCurrentMCPWorkspaceTarget(
            target, expectedWorkspaceID: expectedWorkspaceID
        )
        guard session.runState.isActive else {
            throw RemoteAgentControlServiceError.commandRejected(
                "The requested session has no active run to cancel."
            )
        }
        let cancelTarget = context.agentMode.makeRunCancelTarget(
            tabID: target.tabID,
            session: session
        )
        try authorizeDispatch()
        guard await context.agentMode.cancelAgentRun(target: cancelTarget) else {
            throw RemoteAgentControlServiceError.commandRejected(
                "The run changed before cancellation could be applied."
            )
        }
        return try await response(
            request: request,
            workspaceID: workspaceID(for: context, fallback: request.workspaceID),
            sessionID: sessionID,
            context: context
        )
    }

    private func contextBuilder(
        _ request: RemoteCommandRequest,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> RemoteCommandResponse {
        let workspaceID = try parseWorkspaceID(request.workspaceID)
        let instructions = try requiredMessage(request.message)
        let responseType = request.contextBuilderResponseType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard responseType == nil || ["clarify", "question", "plan", "review"].contains(responseType!) else {
            throw RemoteAgentControlServiceError.commandRejected(
                "Unsupported Context Builder response type. Use clarify, question, plan, or review."
            )
        }

        let context = try await activateWorkspace(workspaceID, authorizeDispatch: authorizeDispatch)
        let tool = await context.window.mcpServer.windowMCPTools.first {
            $0.name == MCPWindowToolName.contextBuilder
        }
        guard let tool else { throw RemoteAgentControlServiceError.contextBuilderUnavailable }

        var arguments: [String: Value] = ["instructions": .string(instructions)]
        if let responseType, responseType != "clarify" {
            arguments["response_type"] = .string(responseType)
        }
        if request.contextBuilderExportResponse == true {
            arguments["export_response"] = .bool(true)
        }

        try authorizeDispatch()
        guard !context.window.isClosing, context.workspaceManager.activeWorkspaceID == workspaceID else {
            throw RemoteAgentControlServiceError.commandRejected("The workspace changed before Context Builder could start.")
        }
        let value = try await tool(arguments)
        guard let object = value.objectValue else {
            throw RemoteAgentControlServiceError.commandRejected("Context Builder returned an invalid result.")
        }
        let result = RemoteContextBuilderResult(
            tabID: object["context_id"]?.stringValue ?? "",
            status: object["status"]?.stringValue ?? "completed",
            prompt: object["prompt"]?.stringValue ?? "",
            fileCount: object["file_count"]?.intValue ?? 0,
            totalTokens: object["total_tokens"]?.intValue ?? 0,
            responseType: object["response_type"]?.stringValue,
            plan: object["plan"]?.objectValue?["response"]?.stringValue,
            review: object["review"]?.objectValue?["response"]?.stringValue,
            followUpHint: object["follow_up_hint"]?.stringValue
        )
        return RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: workspaceID.uuidString,
            message: "Context Builder completed.",
            contextBuilderResult: result
        )
    }

    private func activateWorkspace(
        _ workspaceID: UUID,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> WindowContext {
        guard let manager = windowStatesManager else {
            throw RemoteAgentControlServiceError.workspaceNotOpen
        }
        let window = manager.allWindows.first(where: {
            !$0.isClosing && $0.workspaceManager.workspace(withID: workspaceID) != nil
        })
        let workspaceExists = manager.allWindows.contains {
            $0.workspaceManager.workspace(withID: workspaceID) != nil
        }
        switch RemoteWorkspaceActivationPlanner.decision(
            workspaceExists: workspaceExists,
            reusableWindowExists: window != nil
        ) {
        case .reuseExistingWindow:
            guard let window, let workspace = window.workspaceManager.workspace(withID: workspaceID) else {
                throw RemoteAgentControlServiceError.workspaceNotFound
            }
            if window.workspaceManager.activeWorkspaceID != workspaceID {
                try authorizeDispatch()
                let result = await window.workspaceManager.switchWorkspace(to: workspace, saveState: true, reason: "remote_command")
                guard result.didSwitch || window.workspaceManager.activeWorkspaceID == workspaceID else {
                    throw RemoteAgentControlServiceError.commandRejected(
                        result.message ?? "The workspace could not be activated."
                    )
                }
            }
            return WindowContext(window: window)
        case .openNewWindow:
            do {
                try authorizeDispatch()
                let newWindow = try await manager.openNewMainWindow()
                await newWindow.workspaceManager.awaitInitialized()
                guard let workspace = newWindow.workspaceManager.workspace(withID: workspaceID) else {
                    throw RemoteAgentControlServiceError.workspaceNotFound
                }
                try authorizeDispatch()
                let result = await newWindow.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: true)
                guard result.didSwitch || newWindow.workspaceManager.activeWorkspaceID == workspaceID else {
                    throw RemoteAgentControlServiceError.commandRejected(
                        result.message ?? "The workspace could not be activated in the new window."
                    )
                }
                return WindowContext(window: newWindow)
            } catch let error as RemoteAgentControlServiceError {
                throw error
            } catch {
                throw RemoteAgentControlServiceError.commandRejected(
                    "The desktop could not open a window for the saved workspace."
                )
            }
        case .workspaceNotFound:
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
    }

    private func contextForSession(
        _ sessionID: UUID,
        requestedWorkspaceID: String?,
        authorizeDispatch: RemoteDispatchAuthorization
    ) async throws -> WindowContext {
        if let requestedWorkspaceID, let workspaceID = UUID(uuidString: requestedWorkspaceID) {
            let context = try await activateWorkspace(workspaceID, authorizeDispatch: authorizeDispatch)
            if await canResolveSession(sessionID, in: context) {
                return context
            }
        }
        guard let manager = windowStatesManager else {
            throw RemoteAgentControlServiceError.sessionNotFound
        }
        for window in manager.allWindows where !window.isClosing {
            let context = WindowContext(window: window)
            if await canResolveSession(sessionID, in: context) {
                return context
            }
        }
        throw RemoteAgentControlServiceError.sessionNotFound
    }

    private func canResolveSession(
        _ sessionID: UUID,
        in context: WindowContext
    ) async -> Bool {
        if context.agentMode.sessionIndex[sessionID] != nil
            || context.agentMode.sessions.values.contains(where: { $0.activeAgentSessionID == sessionID })
        {
            return true
        }
        guard let workspace = context.workspaceManager.activeWorkspace else {
            return false
        }
        do {
            return try await context.agentMode.mcpResolveSessionID(
                reference: sessionID.uuidString,
                workspace: workspace
            ) == sessionID
        } catch {
            return false
        }
    }

    private func response(
        request: RemoteCommandRequest,
        workspaceID: UUID,
        sessionID: UUID,
        context: WindowContext
    ) async -> RemoteCommandResponse {
        let state = await AgentModeRemoteSessionQueryService(
            agentMode: context.agentMode,
            workspaceManager: context.workspaceManager
        ).remoteSessions().first(where: { $0.sessionID == sessionID })?.runState
        return RemoteCommandResponse(
            commandID: request.commandID,
            accepted: true,
            workspaceID: workspaceID.uuidString,
            sessionID: sessionID,
            runState: state,
            message: "Remote command accepted."
        )
    }

    private func parseWorkspaceID(_ raw: String?) throws -> UUID {
        guard let raw, let workspaceID = UUID(uuidString: raw) else {
            throw RemoteAgentControlServiceError.invalidWorkspaceID
        }
        return workspaceID
    }

    private func workspaceID(for context: WindowContext, fallback: String?) throws -> UUID {
        if let fallback, let workspaceID = UUID(uuidString: fallback) {
            return workspaceID
        }
        guard let workspaceID = context.workspaceManager.activeWorkspaceID else {
            throw RemoteAgentControlServiceError.workspaceNotFound
        }
        return workspaceID
    }

    private func requiredSessionID(_ sessionID: UUID?) throws -> UUID {
        guard let sessionID else { throw RemoteAgentControlServiceError.sessionIDRequired }
        return sessionID
    }

    private func requiredInteractionID(_ interactionID: UUID?) throws -> UUID {
        guard let interactionID else { throw RemoteAgentControlServiceError.interactionIDRequired }
        return interactionID
    }

    private func requiredMessage(_ message: String?, allowsEmpty: Bool = false) throws -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard allowsEmpty || !trimmed.isEmpty else { throw RemoteAgentControlServiceError.messageRequired }
        return trimmed
    }

    private func importAttachments(
        _ files: [RemoteAttachmentUploads.File],
        sessionID: UUID,
        workspaceID: UUID,
        in context: WindowContext
    ) async throws -> [AgentFileAttachment] {
        guard !files.isEmpty else { return [] }
        guard let directory = context.agentMode.attachmentWorkspaceDirectoryProvider() else {
            throw RemoteAgentControlServiceError.commandRejected("The Mac workspace cannot store attachments.")
        }
        let workspace = context.workspaceManager.workspace(withID: workspaceID)
        return try await RemoteAttachmentUploads.prepareFiles(
            files,
            sessionID: sessionID,
            workspaceDirectory: directory,
            retainedRoot: context.agentMode.sessionAttachmentsRootURL(for: workspace)
        )
    }

    private struct WindowContext {
        let window: WindowState

        var agentMode: AgentModeViewModel {
            window.agentModeViewModel
        }

        var workspaceManager: WorkspaceManagerViewModel {
            window.workspaceManager
        }
    }
}
