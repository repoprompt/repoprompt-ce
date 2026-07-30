import Foundation

enum OracleLaneFailureCode: String, Equatable {
    case emptyResponse = "empty_response"
    case executionFailed = "execution_failed"
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
        secondary: @escaping Operation<Success>
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
