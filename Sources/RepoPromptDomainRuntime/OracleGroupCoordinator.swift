import Foundation

package struct OracleLaneExecutionResponse: Equatable, Sendable {
    package let response: String
    package let executionProfile: OracleExecutionProfile?

    package init(response: String, executionProfile: OracleExecutionProfile? = nil) {
        self.response = response
        self.executionProfile = executionProfile
    }
}

package struct OracleLaneFailure: Error, LocalizedError, Equatable, Sendable {
    package let code: String
    package let message: String
    package let partialResponse: String?
    package let executionProfile: OracleExecutionProfile?

    package init(
        code: String = "provider_error",
        message: String,
        partialResponse: String? = nil,
        executionProfile: OracleExecutionProfile? = nil
    ) {
        self.code = code
        self.message = message
        self.partialResponse = partialResponse
        self.executionProfile = executionProfile
    }

    package var errorDescription: String? { message }
}

package struct OracleLaneCancellation: Error, Equatable, Sendable {
    package let executionProfile: OracleExecutionProfile?

    package init(executionProfile: OracleExecutionProfile? = nil) {
        self.executionProfile = executionProfile
    }
}

package struct OracleLaneExecutionContext: Sendable {
    package let input: OracleInput
    private let deltaHandler: @Sendable (String) async -> Void

    package init(
        input: OracleInput,
        deltaHandler: @escaping @Sendable (String) async -> Void
    ) {
        self.input = input
        self.deltaHandler = deltaHandler
    }

    package func emitDelta(_ text: String) async {
        await deltaHandler(text)
    }
}

package typealias OracleLaneOperation = @Sendable (
    OracleLaneExecutionContext
) async throws -> OracleLaneExecutionResponse

package struct OracleLanePlan: Sendable {
    package let lane: OracleLaneDescriptor
    package let publicChatID: String
    package let operation: OracleLaneOperation

    package init(
        lane: OracleLaneDescriptor,
        publicChatID: String,
        operation: @escaping OracleLaneOperation
    ) throws {
        let publicChatID = publicChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicChatID.isEmpty else { throw OracleGroupContractError.invalidPublicChatID }
        self.lane = lane
        self.publicChatID = publicChatID
        self.operation = operation
    }
}

package enum OracleGroupCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case singleLaneBypassRequired
    case invalidLanePlan

    package var errorDescription: String? {
        switch self {
        case .singleLaneBypassRequired:
            "Single-Oracle execution must bypass OracleGroupCoordinator."
        case .invalidLanePlan:
            "Oracle lane plans must be one contiguous ordered group prefix of two to five lanes."
        }
    }
}

package struct OracleGroupCoordinator: Sendable {
    package typealias ProgressHandler = @Sendable (OracleProgressEvent) async -> Void

    package init() {}

    package func execute(
        group: OracleGroupDescriptor,
        turnID: OracleTurnID,
        input: OracleInput,
        plans: [OracleLanePlan],
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> OracleGroupResult {
        try Self.validate(group: group, plans: plans)
        await progress(OracleProgressEvent(
            kind: .groupPrepared,
            groupID: group.id,
            turnID: turnID,
            text: "Prepared \(plans.count) Oracle lanes"
        ))

        let indexedResults = try await withThrowingTaskGroup(
            of: (Int, OracleLaneResult).self,
            returning: [(Int, OracleLaneResult)].self
        ) { taskGroup in
            for plan in plans {
                taskGroup.addTask {
                    let gate = OracleLaneProgressGate(
                        groupID: group.id,
                        turnID: turnID,
                        laneID: plan.lane.laneID,
                        progress: progress
                    )
                    await gate.start()
                    let result = try await Self.executeLane(
                        plan,
                        input: input,
                        gate: gate
                    )
                    await gate.settle(status: result.status)
                    return (plan.lane.laneID.index, result)
                }
            }

            var results: [(Int, OracleLaneResult)] = []
            results.reserveCapacity(plans.count)
            while let result = try await taskGroup.next() {
                results.append(result)
            }
            return results
        }

        let ordered = indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        let status: OracleGroupStatus = if ordered[0].status != .completed {
            .failed
        } else if ordered.allSatisfy({ $0.status == .completed }) {
            .completed
        } else {
            .partialFailure
        }
        let incompleteAdditionalCount = ordered.dropFirst().count { $0.status != .completed }
        let warnings: [OracleGroupWarning]
        if status == .partialFailure {
            let warningMessage: String
            switch incompleteAdditionalCount {
            case 1: warningMessage = "One lane did not complete"
            case 2: warningMessage = "Two lanes did not complete"
            case 3: warningMessage = "Three lanes did not complete"
            case 4: warningMessage = "Four lanes did not complete"
            default: warningMessage = "\(incompleteAdditionalCount) lanes did not complete"
            }
            warnings = [OracleGroupWarning(code: "lane_failures", message: warningMessage)]
        } else {
            warnings = []
        }
        let result = try OracleGroupResult(
            groupID: group.id,
            status: status,
            oracleResults: ordered,
            warnings: warnings
        )
        await progress(OracleProgressEvent(
            kind: .groupSettled,
            groupID: group.id,
            turnID: turnID,
            text: status.rawValue
        ))
        return result
    }

    private static func validate(group: OracleGroupDescriptor, plans: [OracleLanePlan]) throws {
        guard plans.count != 1 else { throw OracleGroupCoordinatorError.singleLaneBypassRequired }
        guard plans.count == group.size,
              (2 ... OracleRosterContract.maximumCount).contains(plans.count),
              plans.map(\.lane.laneID.index) == Array(plans.indices),
              plans.allSatisfy({ $0.lane.group == group }),
              Set(plans.map(\.publicChatID)).count == plans.count
        else {
            throw OracleGroupCoordinatorError.invalidLanePlan
        }
    }

    private static func executeLane(
        _ plan: OracleLanePlan,
        input: OracleInput,
        gate: OracleLaneProgressGate
    ) async throws -> OracleLaneResult {
        let response: OracleLaneExecutionResponse
        do {
            try Task.checkCancellation()
            response = try await plan.operation(OracleLaneExecutionContext(
                input: input,
                deltaHandler: { text in await gate.delta(text) }
            ))
        } catch let cancellation as OracleLaneCancellation {
            return try OracleLaneResult(
                laneIndex: plan.lane.laneID.index,
                chatID: plan.publicChatID,
                providerID: plan.lane.model.providerID,
                modelID: plan.lane.model.modelID,
                status: .cancelled,
                executionProfile: cancellation.executionProfile,
                error: OracleLaneError(code: "cancelled", message: "Oracle lane was cancelled.")
            )
        } catch is CancellationError {
            return try OracleLaneResult(
                laneIndex: plan.lane.laneID.index,
                chatID: plan.publicChatID,
                providerID: plan.lane.model.providerID,
                modelID: plan.lane.model.modelID,
                status: .cancelled,
                error: OracleLaneError(code: "cancelled", message: "Oracle lane was cancelled.")
            )
        } catch let failure as OracleLaneFailure {
            return try OracleLaneResult(
                laneIndex: plan.lane.laneID.index,
                chatID: plan.publicChatID,
                providerID: plan.lane.model.providerID,
                modelID: plan.lane.model.modelID,
                status: .failed,
                executionProfile: failure.executionProfile,
                error: Self.structuralLaneError(
                    code: failure.code,
                    message: failure.message,
                    partialResponse: failure.partialResponse
                )
            )
        } catch {
            return try OracleLaneResult(
                laneIndex: plan.lane.laneID.index,
                chatID: plan.publicChatID,
                providerID: plan.lane.model.providerID,
                modelID: plan.lane.model.modelID,
                status: .failed,
                error: Self.structuralLaneError(
                    code: "provider_error",
                    message: String(String(describing: error).prefix(512))
                )
            )
        }

        guard !response.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try OracleLaneResult(
                laneIndex: plan.lane.laneID.index,
                chatID: plan.publicChatID,
                providerID: plan.lane.model.providerID,
                modelID: plan.lane.model.modelID,
                status: .failed,
                executionProfile: response.executionProfile,
                error: OracleLaneError(
                    code: "empty_response",
                    message: "Oracle lane returned an empty response."
                )
            )
        }
        return try OracleLaneResult(
            laneIndex: plan.lane.laneID.index,
            chatID: plan.publicChatID,
            providerID: plan.lane.model.providerID,
            modelID: plan.lane.model.modelID,
            status: .completed,
            executionProfile: response.executionProfile,
            response: response.response
        )
    }

    private static func structuralLaneError(
        code: String,
        message: String,
        partialResponse: String? = nil
    ) -> OracleLaneError {
        let codeIsBlank = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let messageIsBlank = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return OracleLaneError(
            code: codeIsBlank ? "provider_error" : code,
            message: messageIsBlank ? "Oracle lane failed." : message,
            partialResponse: partialResponse
        )
    }
}

private actor OracleLaneProgressGate {
    private let groupID: OracleGroupID
    private let turnID: OracleTurnID
    private let laneID: OracleLaneID
    private let progress: OracleGroupCoordinator.ProgressHandler
    private var nextSequence: UInt64 = 0
    private var terminal = false

    init(
        groupID: OracleGroupID,
        turnID: OracleTurnID,
        laneID: OracleLaneID,
        progress: @escaping OracleGroupCoordinator.ProgressHandler
    ) {
        self.groupID = groupID
        self.turnID = turnID
        self.laneID = laneID
        self.progress = progress
    }

    func start() async {
        guard !terminal else { return }
        await emit(kind: .laneStarted, text: nil)
    }

    func delta(_ text: String) async {
        guard !terminal else { return }
        await emit(kind: .laneDelta, text: text)
    }

    func settle(status: OracleLaneResultStatus) async {
        guard !terminal else { return }
        terminal = true
        await emit(kind: .laneSettled, text: status.rawValue)
    }

    private func emit(kind: OracleProgressKind, text: String?) async {
        let sequence = nextSequence
        nextSequence &+= 1
        await progress(OracleProgressEvent(
            kind: kind,
            groupID: groupID,
            turnID: turnID,
            laneID: laneID,
            sequence: sequence,
            text: text
        ))
    }
}
