import Foundation

enum OracleLaneFailureCode: String, Equatable {
    case emptyResponse = "empty_response"
    case executionFailed = "execution_failed"
    case cancelled
}

struct OracleLaneFailure: Equatable {
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
}

enum OracleLaneOutcome: Equatable {
    case completed
    case failed(String)
}

struct OracleLaneExecutionError: LocalizedError {
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

struct OraclePairRoute: Hashable {
    let workspaceID: UUID
    let tabID: UUID
    let agentModeSessionID: UUID?
    let agentModeRunID: UUID?
}

enum OraclePairClaimKey: Hashable {
    case route(OraclePairRoute)
    case workspace(UUID)
}

enum OraclePairClaimError: Error, Equatable {
    case conflict
}

@MainActor
final class OraclePairClaimRegistry {
    private var claimedKeys: Set<OraclePairClaimKey> = []

    func withClaim<Result>(
        _ keys: Set<OraclePairClaimKey>,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        guard !keys.contains(where: conflicts(with:)) else { throw OraclePairClaimError.conflict }
        claimedKeys.formUnion(keys)
        defer { claimedKeys.subtract(keys) }
        return try await operation()
    }

    private func conflicts(with requested: OraclePairClaimKey) -> Bool {
        claimedKeys.contains { existing in
            switch (requested, existing) {
            case let (.route(requestedRoute), .route(existingRoute)):
                requestedRoute == existingRoute
            case let (.route(route), .workspace(workspaceID)),
                 let (.workspace(workspaceID), .route(route)):
                route.workspaceID == workspaceID
            case let (.workspace(requestedID), .workspace(existingID)):
                requestedID == existingID
            }
        }
    }
}

enum OraclePairCoordinator {
    enum LaneExecution<Success: Sendable> {
        case success(Success)
        case failure(OracleLaneFailure)
    }

    struct Result<Success: Sendable> {
        let primary: LaneExecution<Success>
        let secondary: LaneExecution<Success>
    }

    typealias Operation<Success: Sendable> = @MainActor @Sendable () async throws -> Success
    typealias Completion<Success: Sendable> = @MainActor @Sendable (OracleLane, LaneExecution<Success>) async -> Void

    static func validatedResponse(_ response: String?, lane: OracleLane) throws -> String {
        guard let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OracleLaneExecutionError(
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
        secondary: @escaping Operation<Success>,
        onLaneFinished: Completion<Success>? = nil
    ) async throws -> Result<Success> {
        try await withThrowingTaskGroup(
            of: (OracleLane, LaneExecution<Success>).self,
            returning: Result<Success>.self
        ) { group in
            group.addTask { try await (.primary, execute(primary)) }
            group.addTask { try await (.secondary, execute(secondary)) }

            var primaryResult: LaneExecution<Success>?
            var secondaryResult: LaneExecution<Success>?
            do {
                for try await (lane, result) in group {
                    await onLaneFinished?(lane, result)
                    switch lane {
                    case .primary: primaryResult = result
                    case .secondary: secondaryResult = result
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }

            guard let primaryResult, let secondaryResult else { throw CancellationError() }
            return Result(primary: primaryResult, secondary: secondaryResult)
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
        } catch let error as OracleLaneExecutionError {
            return .failure(OracleLaneFailure(
                message: error.message,
                partialResponse: error.partialResponse,
                code: error.code
            ))
        } catch {
            return .failure(OracleLaneFailure(message: error.localizedDescription))
        }
    }
}
