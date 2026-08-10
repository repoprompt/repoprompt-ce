import Foundation
import MCP
import RepoPromptDomainRuntime

/// Portable Oracle state and paired execution for the direct headless backend.
///
/// The macOS app owns richer UI/session persistence, so this coordinator keeps
/// the protocol contract independent of app-only types while projecting the
/// same dual-Oracle wire shape introduced by PR #9.
actor DirectHeadlessOracleCoordinator {
    private enum Lane: String, Sendable {
        case primary
        case secondary
    }

    private enum LaneFailureCode: String, Sendable {
        case emptyResponse = "empty_response"
        case executionFailed = "execution_failed"
    }

    private struct LaneFailure: Error, Sendable {
        let message: String
        let partialResponse: String?
        let code: LaneFailureCode
    }

    private enum LaneExecution: Sendable {
        case success(String)
        case failure(LaneFailure)
    }

    private struct Message: Sendable {
        let role: String
        let text: String
    }

    private struct Conversation: Sendable {
        let id: UUID
        let providerID: String
        var route: DirectHeadlessProviderRoute
        var model: String?
        var pairID: UUID?
        var lane: Lane?
        var messages: [Message]
        var updatedAt: Date
    }

    private struct Pair: Sendable {
        let id: UUID
        let primaryID: UUID
        let secondaryID: UUID
        var route: DirectHeadlessProviderRoute
        var historyDiverged: Bool
        var updatedAt: Date
    }

    private struct PairExecution: Sendable {
        let pair: Pair
        let primaryModel: String
        let secondaryModel: String
        let primary: LaneExecution
        let secondary: LaneExecution

        var status: String {
            switch (primary, secondary) {
            case (.success, .success): "completed"
            case (.failure, .failure): "failed"
            default: "partial_failure"
            }
        }
    }

    private struct PairPreparation: Sendable {
        var pair: Pair
        var primary: Conversation
        var secondary: Conversation
    }

    private static let secondaryModelKey = "models.secondary_oracle_model"
    private static let pairFailurePrefix = "[[RPCE_ORACLE_PAIR_FAILURE_V1:"
    private static let pairFailureSuffix = "]]"

    private let providerCoordinator: DirectHeadlessProviderCoordinator
    private let settingsStore: DomainDirectSettingsStore
    private var conversations: [UUID: Conversation] = [:]
    private var pairs: [UUID: Pair] = [:]
    private var pairByConversation: [UUID: UUID] = [:]
    private var inFlightClaims: Set<DomainContextIdentity> = []

    init(
        providerCoordinator: DirectHeadlessProviderCoordinator,
        settingsStore: DomainDirectSettingsStore
    ) {
        self.providerCoordinator = providerCoordinator
        self.settingsStore = settingsStore
    }

    func utilityResult(
        operation: String,
        limit: Int,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let normalizedOperation = operation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedOperation {
        case "sessions":
            let route = try await providerCoordinator.resolveRoute(for: request)
            return .object([
                "op": .string("sessions"),
                "sessions": .array(Array(sessionValues(route: route).prefix(max(1, min(limit, 200))))),
                "backend": .string("headless")
            ])
        case "models", "providers", "":
            let providers = await providerCoordinator.providerCatalog().map(\.value)
            let secondaryModel = try await configuredSecondaryModel()
            return .object([
                "op": .string(normalizedOperation.isEmpty ? "models" : normalizedOperation),
                "models": .array(providers),
                "providers": .array(providers),
                "dual_oracle_enabled": .bool(secondaryModel != nil),
                "secondary_oracle_model": secondaryModel.map(Value.string) ?? .null,
                "backend": .string("headless")
            ])
        default:
            throw MCPError.invalidParams("unsupported oracle_utils op '\(operation)'")
        }
    }

    func start(
        providerID: String?,
        message: String,
        model: String?,
        mode: String,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let route = try await providerCoordinator.resolveRoute(for: request)
        let validatedMode = try Self.validatedMode(mode)
        let primaryModel = try await resolvedPrimaryModel(model)
        if let secondaryModel = try await configuredSecondaryModel() {
            return try await sendPaired(
                providerID: providerID,
                requestedID: nil,
                forceNew: true,
                message: message,
                primaryModel: primaryModel,
                secondaryModel: secondaryModel,
                mode: validatedMode,
                route: route,
                request: request
            )
        }
        return try await createSingle(
            providerID: providerID,
            message: message,
            model: primaryModel,
            route: route,
            request: request
        )
    }

    func send(
        providerID: String?,
        requestedID: UUID?,
        forceNew: Bool,
        message: String,
        model: String?,
        mode: String,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let route = try await providerCoordinator.resolveRoute(for: request)
        let validatedMode = try Self.validatedMode(mode)
        let primaryModel = try await resolvedPrimaryModel(model)
        if let secondaryModel = try await configuredSecondaryModel() {
            let continuationID = requestedID ?? (forceNew ? nil : latestPrimaryPairID(route: route))
            return try await sendPaired(
                providerID: providerID,
                requestedID: continuationID,
                forceNew: forceNew,
                message: message,
                primaryModel: primaryModel,
                secondaryModel: secondaryModel,
                mode: validatedMode,
                route: route,
                request: request
            )
        }
        let continuationID = requestedID ?? (forceNew ? nil : latestSingleID(route: route))
        if let continuationID, !forceNew {
            return try await continueSingle(
                id: continuationID,
                message: message,
                model: primaryModel,
                route: route,
                request: request
            )
        }
        return try await createSingle(
            providerID: providerID,
            message: message,
            model: primaryModel,
            route: route,
            request: request
        )
    }

    func buildContext(
        providerID: String?,
        instructions: String,
        model: String?,
        responseType: String?,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        let route = try await providerCoordinator.resolveRoute(for: request)
        let normalizedResponseType = responseType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let primaryModel = try await resolvedPrimaryModel(model)
        let responseMode: String?
        switch normalizedResponseType {
        case nil, "", "clarify":
            responseMode = nil
        case "plan":
            responseMode = "plan"
        case "question":
            responseMode = "chat"
        case "review":
            responseMode = "review"
        case let invalid?:
            throw MCPError.invalidParams("Invalid response_type: \(invalid)")
        }
        // Only explicit response-generating modes use the Oracle pair. The
        // default/clarify path remains the legacy one-provider direct result.
        guard let responseMode,
              let normalizedResponseType,
              let secondaryModel = try await configuredSecondaryModel()
        else {
            return try await createSingle(
                providerID: providerID,
                message: instructions,
                model: primaryModel,
                route: route,
                request: request
            )
        }
        let pairValue = try await sendPaired(
            providerID: providerID,
            requestedID: nil,
            forceNew: true,
            message: instructions,
            primaryModel: primaryModel,
            secondaryModel: secondaryModel,
            mode: responseMode,
            route: route,
            request: request
        )
        guard let pairObject = pairValue.objectValue,
              let primaryChatID = pairObject["primary_chat_id"]?.stringValue
        else {
            throw MCPError.internalError("Context Builder Oracle pair result was malformed.")
        }
        let responseKey = normalizedResponseType == "review" ? "review" : "plan"
        let result: [String: Value] = [
            "status": .string("completed"),
            "prompt": .string(instructions),
            "file_count": .int(0),
            "total_tokens": .int(0),
            "selection": .string(""),
            "response_type": .string(normalizedResponseType),
            "context_id": .string(route.identity.contextID.uuidString),
            responseKey: pairValue,
            "follow_up_hint": .string(
                "Continue this conversation with oracle_send(chat_id: \"\(primaryChatID)\", new_chat: false)"
            )
        ]
        return .object(result)
    }

    func conversationLog(
        id: UUID?,
        limit: Int,
        request: DomainPhysicalReadRequest
    ) async throws -> Value {
        let route = try await providerCoordinator.resolveRoute(for: request)
        let conversation: Conversation
        if let id {
            guard let found = conversations[id], found.route.identity == route.identity else {
                throw MCPError.invalidParams("unknown chat_id")
            }
            conversation = found
        } else {
            guard let latest = conversations.values
                // Paired turns settle both members at the same instant. Match
                // the app route by choosing the Primary projection unless the
                // caller explicitly asks for the Secondary chat ID.
                .filter({
                    $0.route.identity == route.identity
                        && $0.lane != .secondary
                })
                .max(by: { $0.updatedAt < $1.updatedAt })
            else {
                return .object(["messages": .array([])])
            }
            conversation = latest
        }
        let messages = conversation.messages.suffix(max(1, min(limit, 50))).map {
            Value.object(["role": .string($0.role), "text": .string($0.text)])
        }
        var object: [String: Value] = [
            "chat_id": .string(conversation.id.uuidString),
            "context_id": .string(conversation.route.identity.contextID.uuidString),
            "messages": .array(Array(messages))
        ]
        if let pairID = conversation.pairID,
           let pair = pairs[pairID],
           let lane = conversation.lane
        {
            object["oracle_pair_id"] = .string(pairID.uuidString)
            object["oracle_lane"] = .string(lane.rawValue)
            object["primary_chat_id"] = .string(pair.primaryID.uuidString)
            object["secondary_chat_id"] = .string(pair.secondaryID.uuidString)
            object["oracle_history_diverged"] = .bool(pair.historyDiverged)
        }
        return .object(object)
    }

    private func configuredSecondaryModel() async throws -> String? {
        await settingsStore.bootstrap()
        switch try await settingsStore.effectiveValue(for: Self.secondaryModelKey) {
        case let .string(raw):
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        case .null:
            return nil
        default:
            throw MCPError.internalError("Secondary Oracle setting has an invalid stored type.")
        }
    }

    private func resolvedPrimaryModel(_ requested: String?) async throws -> String? {
        if let requested = Self.normalizedModel(requested) {
            return requested
        }
        return try await configuredPlanningModel()
    }

    private func configuredPlanningModel() async throws -> String? {
        await settingsStore.bootstrap()
        switch try await settingsStore.effectiveValue(for: "models.planning_model") {
        case let .string(raw):
            return Self.normalizedModel(raw)
        case .null:
            return nil
        default:
            throw MCPError.internalError("Planning model setting has an invalid stored type.")
        }
    }

    private func createSingle(
        providerID: String?,
        message: String,
        model: String?,
        route: DirectHeadlessProviderRoute,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        try claim(route.identity)
        defer { releaseClaim(route.identity) }
        let text = try await providerCoordinator.runProviderOnce(
            message: message,
            providerID: providerID,
            model: model,
            request: request,
            route: route
        )
        let id = UUID()
        conversations[id] = Conversation(
            id: id,
            providerID: Self.storedProviderID(providerID),
            route: route,
            model: Self.normalizedModel(model),
            pairID: nil,
            lane: nil,
            messages: [Message(role: "user", text: message), Message(role: "assistant", text: text)],
            updatedAt: Date()
        )
        return Self.singleValue(id: id, response: text)
    }

    private func continueSingle(
        id: UUID,
        message: String,
        model: String?,
        route: DirectHeadlessProviderRoute,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        try claim(route.identity)
        defer { releaseClaim(route.identity) }
        guard var conversation = conversations[id], conversation.route.identity == route.identity else {
            throw MCPError.invalidParams("unknown chat_id")
        }
        guard pairByConversation[id] == nil else {
            throw MCPError.invalidParams(
                "Paired Oracle histories cannot be continued while Secondary Oracle is disabled. Start a new chat."
            )
        }

        let prompt = Self.continuationPrompt(messages: conversation.messages, message: message)
        let text = try await providerCoordinator.runProviderOnce(
            message: prompt,
            providerID: conversation.providerID,
            // Preserve the pre-dual direct behavior: an omitted continuation
            // model remains an omitted provider override.
            model: model,
            request: request,
            route: route
        )
        conversation.messages.append(Message(role: "user", text: message))
        conversation.messages.append(Message(role: "assistant", text: text))
        if let normalized = Self.normalizedModel(model) {
            conversation.model = normalized
        }
        conversation.route = route
        conversation.updatedAt = Date()
        conversations[id] = conversation
        return Self.singleValue(id: id, response: text)
    }

    private func sendPaired(
        providerID: String?,
        requestedID: UUID?,
        forceNew: Bool,
        message: String,
        primaryModel: String?,
        secondaryModel: String,
        mode: String,
        route: DirectHeadlessProviderRoute,
        request: DomainPhysicalToolRequest
    ) async throws -> Value {
        try claim(route.identity)
        defer { releaseClaim(route.identity) }

        var preparation = try preparePair(
            providerID: providerID,
            requestedID: requestedID,
            forceNew: forceNew,
            primaryModel: primaryModel,
            secondaryModel: secondaryModel,
            route: route
        )
        let carrierEnvironments = try await pairedCarrierEnvironments()
        try Task.checkCancellation()

        let resolvedPrimaryModel = Self.normalizedModel(primaryModel)
            ?? preparation.primary.model
            ?? "default"
        let resolvedSecondaryModel = Self.normalizedModel(secondaryModel) ?? "default"
        preparation.primary.model = resolvedPrimaryModel
        preparation.secondary.model = resolvedSecondaryModel
        preparation.primary.route = route
        preparation.secondary.route = route
        preparation.pair.route = route

        let primaryPrompt = preparation.primary.messages.isEmpty
            ? message
            : Self.continuationPrompt(messages: preparation.primary.messages, message: message)
        let secondaryPrompt = preparation.secondary.messages.isEmpty
            ? message
            : Self.continuationPrompt(messages: preparation.secondary.messages, message: message)

        // Keep pair creation and the common user turn local until both lanes
        // have settled. Reservation failure and true cancellation therefore
        // cannot leave phantom pairs or unacknowledged history behind.
        preparation.primary.messages.append(Message(role: "user", text: message))
        preparation.secondary.messages.append(Message(role: "user", text: message))
        let turnStartedAt = Date()
        preparation.primary.updatedAt = turnStartedAt
        preparation.secondary.updatedAt = turnStartedAt

        let laneProviderCoordinator = providerCoordinator
        let primaryProviderID = preparation.primary.providerID
        let secondaryProviderID = preparation.secondary.providerID
        let executions: (LaneExecution, LaneExecution)
        do {
            executions = try await withThrowingTaskGroup(
                of: (Lane, LaneExecution).self,
                returning: (LaneExecution, LaneExecution).self
            ) { group in
                group.addTask {
                    let result = try await Self.executeLane(
                        providerCoordinator: laneProviderCoordinator,
                        lane: .primary,
                        prompt: primaryPrompt,
                        providerID: primaryProviderID,
                        model: resolvedPrimaryModel,
                        request: request,
                        route: route,
                        carrierEnvironment: carrierEnvironments.primary
                    )
                    return (.primary, result)
                }
                group.addTask {
                    let result = try await Self.executeLane(
                        providerCoordinator: laneProviderCoordinator,
                        lane: .secondary,
                        prompt: secondaryPrompt,
                        providerID: secondaryProviderID,
                        model: resolvedSecondaryModel,
                        request: request,
                        route: route,
                        carrierEnvironment: carrierEnvironments.secondary
                    )
                    return (.secondary, result)
                }

                var primaryResult: LaneExecution?
                var secondaryResult: LaneExecution?
                do {
                    for try await (lane, result) in group {
                        switch lane {
                        case .primary: primaryResult = result
                        case .secondary: secondaryResult = result
                        }
                    }
                } catch {
                    group.cancelAll()
                    throw error
                }
                guard let primaryResult, let secondaryResult else {
                    throw CancellationError()
                }
                return (primaryResult, secondaryResult)
            }
        } catch is CancellationError {
            throw CancellationError()
        }

        if case let .success(text) = executions.0 {
            preparation.primary.messages.append(Message(role: "assistant", text: text))
        }
        if case let .success(text) = executions.1 {
            preparation.secondary.messages.append(Message(role: "assistant", text: text))
        }
        let completedAt = Date()
        preparation.primary.updatedAt = completedAt
        preparation.secondary.updatedAt = completedAt
        preparation.pair.historyDiverged = Self.userHistory(preparation.primary.messages)
            != Self.userHistory(preparation.secondary.messages)
        preparation.pair.updatedAt = completedAt

        conversations[preparation.primary.id] = preparation.primary
        conversations[preparation.secondary.id] = preparation.secondary
        pairs[preparation.pair.id] = preparation.pair
        pairByConversation[preparation.primary.id] = preparation.pair.id
        pairByConversation[preparation.secondary.id] = preparation.pair.id

        let execution = PairExecution(
            pair: preparation.pair,
            primaryModel: resolvedPrimaryModel,
            secondaryModel: resolvedSecondaryModel,
            primary: executions.0,
            secondary: executions.1
        )
        let value = Self.pairValue(execution: execution, mode: mode)
        guard execution.status == "failed" else { return value }
        throw try Self.pairFailureError(execution: execution, value: value)
    }

    private nonisolated static func executeLane(
        providerCoordinator: DirectHeadlessProviderCoordinator,
        lane: Lane,
        prompt: String,
        providerID: String,
        model: String,
        request: DomainPhysicalToolRequest,
        route: DirectHeadlessProviderRoute,
        carrierEnvironment: [String: String]
    ) async throws -> LaneExecution {
        do {
            let text = try await providerCoordinator.runProviderOnce(
                message: prompt,
                providerID: providerID,
                model: model,
                request: request,
                route: route,
                carrierEnvironment: carrierEnvironment
            )
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(LaneFailure(
                    message: "Oracle \(lane.rawValue) lane returned an empty response.",
                    partialResponse: text,
                    code: .emptyResponse
                ))
            }
            return .success(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(LaneFailure(
                message: error.localizedDescription,
                partialResponse: nil,
                code: .executionFailed
            ))
        }
    }

    private func preparePair(
        providerID: String?,
        requestedID: UUID?,
        forceNew: Bool,
        primaryModel: String?,
        secondaryModel: String,
        route: DirectHeadlessProviderRoute
    ) throws -> PairPreparation {
        if !forceNew, let requestedID {
            guard var source = conversations[requestedID] else {
                throw MCPError.invalidParams("unknown chat_id")
            }
            guard source.route.identity == route.identity else {
                throw MCPError.invalidParams("unknown chat_id")
            }
            if let pairID = pairByConversation[requestedID] {
                guard let pair = pairs[pairID],
                      var primary = conversations[pair.primaryID],
                      var secondary = conversations[pair.secondaryID],
                      pair.route.identity == route.identity,
                      primary.route.identity == route.identity,
                      secondary.route.identity == route.identity
                else {
                    throw MCPError.invalidRequest(
                        "Oracle pair \(pairID.uuidString) is incomplete; start a new Oracle chat instead of continuing it."
                    )
                }
                primary.route = route
                secondary.route = route
                var currentPair = pair
                currentPair.route = route
                return PairPreparation(pair: currentPair, primary: primary, secondary: secondary)
            }

            let pairID = UUID()
            let secondaryID = UUID()
            source.pairID = pairID
            source.lane = .primary
            source.route = route
            if let normalized = Self.normalizedModel(primaryModel) {
                source.model = normalized
            }
            let secondary = Conversation(
                id: secondaryID,
                providerID: source.providerID,
                route: route,
                model: Self.normalizedModel(secondaryModel),
                pairID: pairID,
                lane: .secondary,
                messages: [],
                updatedAt: Date()
            )
            let pair = Pair(
                id: pairID,
                primaryID: requestedID,
                secondaryID: secondaryID,
                route: route,
                historyDiverged: !Self.userHistory(source.messages).isEmpty,
                updatedAt: Date()
            )
            return PairPreparation(pair: pair, primary: source, secondary: secondary)
        }

        let pairID = UUID()
        let primaryID = UUID()
        let secondaryID = UUID()
        let storedProviderID = Self.storedProviderID(providerID)
        let now = Date()
        let primary = Conversation(
            id: primaryID,
            providerID: storedProviderID,
            route: route,
            model: Self.normalizedModel(primaryModel),
            pairID: pairID,
            lane: .primary,
            messages: [],
            updatedAt: now
        )
        let secondary = Conversation(
            id: secondaryID,
            providerID: storedProviderID,
            route: route,
            model: Self.normalizedModel(secondaryModel),
            pairID: pairID,
            lane: .secondary,
            messages: [],
            updatedAt: now
        )
        let pair = Pair(
            id: pairID,
            primaryID: primaryID,
            secondaryID: secondaryID,
            route: route,
            historyDiverged: false,
            updatedAt: now
        )
        return PairPreparation(pair: pair, primary: primary, secondary: secondary)
    }

    private func pairedCarrierEnvironments() async throws -> (
        primary: [String: String],
        secondary: [String: String]
    ) {
        let primaryCarrier = DomainChildLaunchContext.current
        if let prepareFreshCarrier = DomainAdditionalChildLaunchContext.prepareFreshCarrier {
            guard let secondaryCarrier = try await prepareFreshCarrier() else {
                throw MCPError.internalError("Failed to reserve the Secondary Oracle child launch.")
            }
            return (primaryCarrier?.environment ?? [:], secondaryCarrier.environment)
        }
        // Direct unit callers can legitimately have no nested-MCP carrier. A
        // real wrapped invocation must never duplicate a single-use token.
        if primaryCarrier?.environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] != nil {
            throw MCPError.internalError("Secondary Oracle requires an independent child launch reservation.")
        }
        return ([:], [:])
    }

    private func claim(_ identity: DomainContextIdentity) throws {
        guard inFlightClaims.insert(identity).inserted else {
            throw MCPError.invalidRequest("This Oracle route already has an in-flight request.")
        }
    }

    private func releaseClaim(_ identity: DomainContextIdentity) {
        inFlightClaims.remove(identity)
    }

    private func sessionValues(route: DirectHeadlessProviderRoute) -> [Value] {
        conversations.values
            .filter { $0.route.identity == route.identity }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { conversation in
                var object: [String: Value] = [
                    "chat_id": .string(conversation.id.uuidString),
                    "context_id": .string(conversation.route.identity.contextID.uuidString),
                    "provider": .string(conversation.providerID),
                    "model_raw_id": .string(conversation.model ?? "default"),
                    "updated_at": .string(ISO8601DateFormatter().string(from: conversation.updatedAt))
                ]
                if let pairID = conversation.pairID,
                   let lane = conversation.lane,
                   let pair = pairs[pairID]
                {
                    object["oracle_pair_id"] = .string(pairID.uuidString)
                    object["oracle_lane"] = .string(lane.rawValue)
                    object["primary_chat_id"] = .string(pair.primaryID.uuidString)
                    object["secondary_chat_id"] = .string(pair.secondaryID.uuidString)
                    object["oracle_history_diverged"] = .bool(pair.historyDiverged)
                }
                return .object(object)
            }
    }

    private func latestPrimaryPairID(route: DirectHeadlessProviderRoute) -> UUID? {
        conversations.values
            .filter {
                $0.route.identity == route.identity
                    && $0.pairID != nil
                    && $0.lane == .primary
            }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .id
    }

    private func latestSingleID(route: DirectHeadlessProviderRoute) -> UUID? {
        conversations.values
            .filter { $0.route.identity == route.identity && $0.pairID == nil }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .id
    }

    private nonisolated static func singleValue(id: UUID, response: String) -> Value {
        .object([
            "chat_id": .string(id.uuidString),
            "response": .string(response),
            "backend": .string("headless")
        ])
    }

    private nonisolated static func pairValue(execution: PairExecution, mode: String) -> Value {
        let primaryID = execution.pair.primaryID.uuidString
        let secondaryID = execution.pair.secondaryID.uuidString
        var object: [String: Value]
        switch execution.primary {
        case let .success(response):
            object = [
                "chat_id": .string(primaryID),
                "mode": .string(mode),
                "response": .string(response)
            ]
        case let .failure(failure):
            object = [
                "chat_id": .string(primaryID),
                "mode": .string(mode),
                "errors": .array([.string(failure.message)])
            ]
        }
        object["status"] = .string(execution.status)
        object["context_id"] = .string(execution.pair.route.identity.contextID.uuidString)
        object["oracle_pair_id"] = .string(execution.pair.id.uuidString)
        object["primary_chat_id"] = .string(primaryID)
        object["secondary_chat_id"] = .string(secondaryID)
        object["oracle_history_diverged"] = .bool(execution.pair.historyDiverged)
        object["oracle_results"] = .object([
            "primary": laneValue(
                lane: .primary,
                execution: execution.primary,
                pairID: execution.pair.id,
                chatID: execution.pair.primaryID,
                model: execution.primaryModel,
                mode: mode
            ),
            "secondary": laneValue(
                lane: .secondary,
                execution: execution.secondary,
                pairID: execution.pair.id,
                chatID: execution.pair.secondaryID,
                model: execution.secondaryModel,
                mode: mode
            )
        ])
        return .object(object)
    }

    private nonisolated static func laneValue(
        lane: Lane,
        execution: LaneExecution,
        pairID: UUID,
        chatID: UUID,
        model: String,
        mode: String
    ) -> Value {
        var object: [String: Value]
        switch execution {
        case let .success(response):
            object = [
                "status": .string("completed"),
                "mode": .string(mode),
                "response": .string(response)
            ]
        case let .failure(failure):
            object = [
                "status": .string("failed"),
                "error": .string(failure.message),
                "error_code": .string(failure.code.rawValue)
            ]
            if let partialResponse = failure.partialResponse {
                object["partial_response"] = .string(partialResponse)
            }
        }
        object["oracle_lane"] = .string(lane.rawValue)
        object["oracle_pair_id"] = .string(pairID.uuidString)
        object["chat_id"] = .string(chatID.uuidString)
        object["model_raw_id"] = .string(model)
        let modelDisplayName = (try? DomainAppSettingsCatalog.secondaryOracleModelSelection(raw: model))?
            .displayName
            ?? (model == "default" ? "Default" : model)
        object["model_display_name"] = .string(modelDisplayName)
        return .object(object)
    }

    private nonisolated static func pairFailureError(
        execution: PairExecution,
        value: Value
    ) throws -> MCPError {
        let data = try JSONEncoder().encode(value)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode the Oracle pair failure payload.")
        }
        let envelope = pairFailurePrefix
            + Data(payload.utf8).base64EncodedString()
            + pairFailureSuffix
        let summaries = [
            failureSummary(lane: .primary, execution: execution.primary),
            failureSummary(lane: .secondary, execution: execution.secondary)
        ].compactMap(\.self)
        return .serverError(code: -32000, message: summaries.joined(separator: "\n") + "\n" + envelope)
    }

    private nonisolated static func failureSummary(
        lane: Lane,
        execution: LaneExecution
    ) -> String? {
        guard case let .failure(failure) = execution else { return nil }
        let label = lane == .primary ? "Primary" : "Secondary"
        return "\(label) Oracle failed: \(failure.message)"
    }

    private nonisolated static func storedProviderID(_ requested: String?) -> String {
        let normalized = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.flatMap { $0.isEmpty ? nil : $0 } ?? "codexExec"
    }

    private nonisolated static func normalizedModel(_ raw: String?) -> String? {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        if let selection = try? DomainAppSettingsCatalog.secondaryOracleModelSelection(raw: normalized) {
            return selection.canonicalRawID
        }
        return normalized
    }

    private nonisolated static func continuationPrompt(messages: [Message], message: String) -> String {
        let history = messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")
        return history + "\n\nuser: " + message
    }

    private nonisolated static func userHistory(_ messages: [Message]) -> [String] {
        messages.filter { $0.role == "user" }.map(\.text)
    }

    private nonisolated static func validatedMode(_ raw: String) throws -> String {
        let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["chat", "plan", "review"].contains(mode) else {
            throw MCPError.invalidParams("Invalid mode: \(mode). Valid modes: chat, plan, review")
        }
        return mode
    }
}
