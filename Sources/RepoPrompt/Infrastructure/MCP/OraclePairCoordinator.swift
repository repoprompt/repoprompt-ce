import Foundation

enum OracleLaneFailureCode: String, Equatable {
    case emptyResponse = "empty_response"
    case executionFailed = "execution_failed"
    case cancelled
}

struct OracleLaneFailure: LocalizedError, Equatable {
    let message: String
    let partialResponse: String?
    let code: OracleLaneFailureCode

    init(
        message: String,
        partialResponse: String? = nil,
        code: OracleLaneFailureCode = .executionFailed
    ) {
        self.message = message
        self.partialResponse = partialResponse
        self.code = code
    }

    var errorDescription: String? {
        message
    }
}

enum OraclePairCoordinator {
    enum LaneExecution<Success: Sendable> {
        case success(Success)
        case failure(OracleLaneFailure)
    }

    struct LaneOperation<Success: Sendable> {
        let lane: OracleLane
        let operation: Operation<Success>

        init(lane: OracleLane, operation: @escaping Operation<Success>) {
            self.lane = lane
            self.operation = operation
        }
    }

    struct LaneResult<Success: Sendable> {
        let lane: OracleLane
        let execution: LaneExecution<Success>
    }

    struct Result<Success: Sendable> {
        let orderedResults: [LaneResult<Success>]

        init(primary: LaneExecution<Success>, secondary: LaneExecution<Success>) {
            orderedResults = [
                LaneResult(lane: .primary, execution: primary),
                LaneResult(lane: .secondary, execution: secondary)
            ]
        }

        init(executionsByLane: [OracleLane: LaneExecution<Success>]) throws {
            let lanes = executionsByLane.keys.sorted { $0.ordinal < $1.ordinal }
            guard (2 ... OracleLane.allCases.count).contains(lanes.count) else {
                throw OracleLaneValidationError.invalidCount(lanes.count)
            }
            try OracleLane.validateOrderedPrefix(lanes)
            orderedResults = executionsByLane.sorted { lhs, rhs in
                lhs.key.ordinal < rhs.key.ordinal
            }.map { lane, execution in
                LaneResult(lane: lane, execution: execution)
            }
        }

        var orderedLanes: [OracleLane] {
            orderedResults.map(\.lane)
        }

        var executionsByLane: [OracleLane: LaneExecution<Success>] {
            Dictionary(uniqueKeysWithValues: orderedResults.map { ($0.lane, $0.execution) })
        }

        subscript(lane: OracleLane) -> LaneExecution<Success>? {
            orderedResults.first(where: { $0.lane == lane })?.execution
        }

        var primary: LaneExecution<Success> {
            requiredExecution(for: .primary)
        }

        var secondary: LaneExecution<Success> {
            requiredExecution(for: .secondary)
        }

        private func requiredExecution(for lane: OracleLane) -> LaneExecution<Success> {
            guard let execution = self[lane] else {
                preconditionFailure("Validated Oracle result is missing the \(lane.rawValue) lane")
            }
            return execution
        }
    }

    typealias Operation<Success: Sendable> = @MainActor @Sendable () async throws -> Success

    static func validatedResponse(_ response: String?, lane: OracleLane) throws -> String {
        guard let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OracleLaneFailure(
                message: "Oracle \(lane.rawValue) lane returned an empty response.",
                partialResponse: response,
                code: .emptyResponse
            )
        }
        return response
    }

    @MainActor
    static func run<Success: Sendable>(
        primary: @escaping Operation<Success>,
        secondary: @escaping Operation<Success>
    ) async throws -> Result<Success> {
        try await run(operations: [
            LaneOperation(lane: .primary, operation: primary),
            LaneOperation(lane: .secondary, operation: secondary)
        ])
    }

    /// Runs a complete 2...5 Oracle lane prefix concurrently and returns results
    /// in lane order, independent of task completion order.
    @MainActor
    static func run<Success: Sendable>(
        operationsByLane: [OracleLane: Operation<Success>]
    ) async throws -> Result<Success> {
        let operations = operationsByLane
            .map { LaneOperation(lane: $0.key, operation: $0.value) }
            .sorted { $0.lane.ordinal < $1.lane.ordinal }
        return try await run(operations: operations)
    }

    /// Array form used when the caller already owns a stable configured order.
    @MainActor
    static func run<Success: Sendable>(
        operations: [LaneOperation<Success>]
    ) async throws -> Result<Success> {
        let lanes = operations.map(\.lane)
        guard (2 ... OracleLane.allCases.count).contains(lanes.count) else {
            throw OracleLaneValidationError.invalidCount(lanes.count)
        }
        try OracleLane.validateOrderedPrefix(lanes)

        return try await withThrowingTaskGroup(
            of: LaneResult<Success>.self,
            returning: Result<Success>.self
        ) { group in
            for laneOperation in operations {
                group.addTask {
                    let execution = try await execute(laneOperation.operation)
                    return LaneResult(
                        lane: laneOperation.lane,
                        execution: execution
                    )
                }
            }

            var executionsByLane: [OracleLane: LaneExecution<Success>] = [:]
            do {
                for try await laneResult in group {
                    executionsByLane[laneResult.lane] = laneResult.execution
                }
            } catch {
                group.cancelAll()
                throw error
            }

            guard executionsByLane.count == operations.count else { throw CancellationError() }
            return try Result(executionsByLane: executionsByLane)
        }
    }

    @MainActor
    private static func execute<Success: Sendable>(
        _ operation: @escaping Operation<Success>
    ) async throws -> LaneExecution<Success> {
        do {
            return try await .success(operation())
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as OracleLaneFailure {
            return .failure(failure)
        } catch {
            return .failure(OracleLaneFailure(message: error.localizedDescription))
        }
    }
}

/// Preferred generic name for new callers. The compatibility name remains the
/// concrete declaration so the dual-Oracle runtime can migrate incrementally.
typealias OracleGroupCoordinator = OraclePairCoordinator
