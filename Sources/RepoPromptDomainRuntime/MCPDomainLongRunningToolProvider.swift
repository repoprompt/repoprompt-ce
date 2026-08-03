import Foundation
import MCP

package enum DomainChildLaunchContext {
    @TaskLocal package static var current: DomainChildLaunchCarrier?
}

package enum DomainInteractionPresentationContext {
    @TaskLocal package static var requestID: UUID?
}

package struct DomainLongRunningInteractionAdapter: Sendable {
    package let isAvailable: @Sendable (DomainInteractionRequest) async -> Bool
    package let resolveDefaultTimeoutSeconds: @Sendable (DomainInteractionRequest) async throws -> TimeInterval
    package let cancel: @Sendable (UUID) async -> Void

    package init(
        isAvailable: @escaping @Sendable (DomainInteractionRequest) async -> Bool,
        resolveDefaultTimeoutSeconds: @escaping @Sendable (DomainInteractionRequest) async throws -> TimeInterval,
        cancel: @escaping @Sendable (UUID) async -> Void
    ) {
        self.isAvailable = isAvailable
        self.resolveDefaultTimeoutSeconds = resolveDefaultTimeoutSeconds
        self.cancel = cancel
    }
}

package struct MCPDomainLongRunningToolProvider: Sendable {
    package typealias PrepareChildLaunch = @Sendable (
        _ toolName: String,
        _ arguments: [String: Value],
        _ securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchCarrier?

    package static let toolNames: Set<String> = [
        "oracle_utils",
        "ask_oracle",
        "oracle_send",
        "context_builder",
        "ask_user",
        "agent_explore",
        "agent_run",
        "agent_manage",
        "share_thoughts",
        "set_status",
        "wait_for_next_user_instruction"
    ]

    private let identity: DomainRuntimeIdentity
    private let policyStore: DomainMutationPolicyStore
    private let interactionBroker: DomainInteractionBroker
    private let activityCenter: DomainActivityCenter
    private let prepareChildLaunch: PrepareChildLaunch

    package init(
        identity: DomainRuntimeIdentity,
        policyStore: DomainMutationPolicyStore,
        interactionBroker: DomainInteractionBroker,
        activityCenter: DomainActivityCenter,
        prepareChildLaunch: @escaping PrepareChildLaunch = { _, _, _ in nil }
    ) {
        self.identity = identity
        self.policyStore = policyStore
        self.interactionBroker = interactionBroker
        self.activityCenter = activityCenter
        self.prepareChildLaunch = prepareChildLaunch
    }

    package func wrapping(
        _ binding: MCPDomainToolBinding,
        interactionAdapter: DomainLongRunningInteractionAdapter? = nil
    ) -> MCPDomainToolBinding {
        guard Self.toolNames.contains(binding.definition.name) else { return binding }
        let definition = binding.definition
        return MCPDomainToolBinding(definition: definition) { arguments in
            try await execute(
                binding: binding,
                arguments: arguments,
                interactionAdapter: interactionAdapter
            )
        }
    }

    private func execute(
        binding: MCPDomainToolBinding,
        arguments: [String: Value],
        interactionAdapter: DomainLongRunningInteractionAdapter?
    ) async throws -> Value {
        try Task.checkCancellation()
        let toolName = binding.definition.name
        let securityContext = MCPDomainInvocationSecurityContext.current
        let activity = await activityCenter.begin(
            kind: activityKind(toolName),
            toolName: toolName,
            invocationID: securityContext?.invocationID,
            sessionID: sessionID(arguments)
        )
        guard let activity else { throw CancellationError() }

        do {
            let value: Value
            if toolName == "ask_user" {
                value = try await executeInteraction(
                    binding: binding,
                    arguments: arguments,
                    securityContext: securityContext,
                    activity: activity,
                    interactionAdapter: interactionAdapter
                )
            } else {
                let authorizations = try await authorizeIfNeeded(
                    toolName: toolName,
                    arguments: arguments,
                    context: securityContext
                )
                try Task.checkCancellation()
                let carrier: DomainChildLaunchCarrier?
                if requiresChildLaunch(toolName: toolName, arguments: arguments) {
                    guard let securityContext else {
                        throw MCPError.invalidParams(
                            "approval_required_noninteractive: missing verified invocation identity"
                        )
                    }
                    carrier = try await prepareChildLaunch(toolName, arguments, securityContext)
                } else {
                    carrier = nil
                }
                for authorization in authorizations {
                    try await policyStore.revalidate(authorization)
                }
                try Task.checkCancellation()
                value = try await DomainChildLaunchContext.$current.withValue(carrier) {
                    try await binding(arguments)
                }
            }
            _ = await activityCenter.finish(
                activity,
                state: .completed,
                commitID: UUID()
            )
            return value
        } catch is CancellationError {
            _ = await activityCenter.finish(
                activity,
                state: .cancelled,
                commitID: UUID(),
                statusText: "Cancelled"
            )
            throw CancellationError()
        } catch {
            _ = await activityCenter.finish(
                activity,
                state: .failed,
                commitID: UUID(),
                statusText: Self.safeErrorText(error)
            )
            throw error
        }
    }

    private func executeInteraction(
        binding: MCPDomainToolBinding,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext?,
        activity: DomainActivityToken,
        interactionAdapter: DomainLongRunningInteractionAdapter?
    ) async throws -> Value {
        _ = await activityCenter.update(
            activity,
            state: .waitingForInteraction,
            statusText: "Waiting for user response"
        )
        let requestSeed = DomainInteractionRequest(
            toolName: binding.definition.name,
            clientID: securityContext?.connectionID,
            invocationID: securityContext?.invocationID,
            runID: securityContext?.principal.runID,
            payload: arguments,
            deadline: .distantFuture
        )
        let timeout = try await interactionTimeout(
            arguments,
            request: requestSeed,
            adapter: interactionAdapter
        )
        let request = DomainInteractionRequest(
            id: requestSeed.id,
            toolName: requestSeed.toolName,
            clientID: requestSeed.clientID,
            invocationID: requestSeed.invocationID,
            runID: requestSeed.runID,
            payload: requestSeed.payload,
            deadline: Date().addingTimeInterval(timeout + 1)
        )
        let appUI = interactionAdapter.map { adapter in
            DomainInteractionProvider(
                kind: .appUI,
                isAvailable: adapter.isAvailable,
                present: { request in
                    try await DomainInteractionPresentationContext.$requestID.withValue(request.id) {
                        try await binding(arguments)
                    }
                },
                cancel: adapter.cancel
            )
        }
        let result = await interactionBroker.request(request, appUI: appUI)
        switch result {
        case let .response(value, _):
            return value
        case .timedOut:
            return .object([
                "answers": .object([:]),
                "timed_out": .bool(true),
                "skipped": .bool(false),
                "elapsed_seconds": .int(max(0, Int(timeout.rounded(.down))))
            ])
        case .cancelled:
            throw CancellationError()
        case .unavailable:
            throw MCPError.invalidParams(
                "interaction_unavailable: this client did not negotiate elicitation and no app UI presenter is available"
            )
        case let .failed(message):
            throw MCPError.internalError("ask_user interaction failed: \(message)")
        }
    }

    private func authorizeIfNeeded(
        toolName: String,
        arguments: [String: Value],
        context: DomainToolInvocationSecurityContext?
    ) async throws -> [DomainMutationAuthorizationSnapshot] {
        let classes = approvalClasses(toolName: toolName, arguments: arguments)
        guard !classes.isEmpty else { return [] }
        var snapshots: [DomainMutationAuthorizationSnapshot] = []
        for approvalClass in classes {
            snapshots.append(try await policyStore.authorize(
                context: context,
                toolName: toolName,
                action: approvalClass,
                workspaceID: context?.workspaceID,
                canonicalRoots: []
            ))
        }
        return snapshots
    }

    private func approvalClasses(
        toolName: String,
        arguments: [String: Value]
    ) -> [String] {
        switch toolName {
        case "ask_oracle", "oracle_send", "context_builder":
            return ["ai_cost", "external_process"]
        case "agent_explore":
            return normalizedOperation(arguments, fallback: "") == "start"
                ? ["ai_cost", "external_process"]
                : []
        case "agent_run":
            let operation = normalizedOperation(arguments, fallback: "wait")
            return ["start", "steer", "respond"].contains(operation)
                ? ["ai_cost", "external_process"]
                : []
        case "agent_manage":
            let operation = canonicalOperation(arguments, fallback: "list_sessions")
            if ["resume_session", "handoff"].contains(operation) {
                return ["ai_cost", "external_process"]
            }
            return operation == "create_session" ? ["external_process"] : []
        default:
            return []
        }
    }

    private func requiresChildLaunch(
        toolName: String,
        arguments: [String: Value]
    ) -> Bool {
        switch toolName {
        case "context_builder", "ask_oracle", "oracle_send":
            return true
        case "agent_explore":
            return normalizedOperation(arguments, fallback: "") == "start"
        case "agent_run":
            let operation = normalizedOperation(arguments, fallback: "wait")
            return ["start", "steer", "respond"].contains(operation)
        default:
            return false
        }
    }

    private func normalizedOperation(
        _ arguments: [String: Value],
        fallback: String
    ) -> String {
        guard let operation = arguments["op"]?.stringValue else { return fallback }
        return operation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func canonicalOperation(
        _ arguments: [String: Value],
        fallback: String
    ) -> String {
        let operation = normalizedOperation(arguments, fallback: fallback)
        return operation == "extract_handoff" ? "handoff" : operation
    }

    private func activityKind(_ toolName: String) -> DomainActivityKind {
        switch toolName {
        case "ask_oracle", "oracle_send", "oracle_utils":
            .oracle
        case "context_builder":
            .contextBuilder
        case "agent_explore":
            .agentExplore
        case "agent_run":
            .agentRun
        case "agent_manage":
            .agentManage
        case "ask_user":
            .interaction
        default:
            .sessionControl
        }
    }

    private func sessionID(_ arguments: [String: Value]) -> UUID? {
        guard let raw = arguments["session_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private func interactionTimeout(
        _ arguments: [String: Value],
        request: DomainInteractionRequest,
        adapter: DomainLongRunningInteractionAdapter?
    ) async throws -> TimeInterval {
        if let suppliedValue = arguments["timeout_seconds"] {
            guard let supplied = suppliedValue.intValue, supplied > 0 else {
                throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
            }
            return TimeInterval(supplied)
        }
        if let adapter {
            let resolved: TimeInterval
            do {
                resolved = try await adapter.resolveDefaultTimeoutSeconds(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return 300
            }
            guard resolved.isFinite, resolved > 0 else {
                throw MCPError.internalError("ask_user workspace timeout is invalid")
            }
            return resolved
        }
        return 300
    }

    private static func safeErrorText(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled" }
        let text = String(describing: error)
        return String(text.prefix(512))
    }
}
