import Foundation

struct RunBlockerRegistry {
    typealias ToolIdleWaiter = (_ runID: UUID) async throws -> Void
    typealias RunBoolQuery = (_ runID: UUID) -> Bool
    typealias ToolEndedCountProvider = (_ runID: UUID) -> Int
    typealias ChildAgentRunWaitDrainer = (_ runID: UUID, _ source: String) async -> Bool

    static let inactive = RunBlockerRegistry()

    private let toolIdleWaiter: ToolIdleWaiter
    private let activeMCPToolQuery: RunBoolQuery
    private let toolEndedCountProvider: ToolEndedCountProvider
    private let activeChildAgentRunWaitQuery: RunBoolQuery
    private let childAgentRunWaitDrainer: ChildAgentRunWaitDrainer

    init(
        awaitNoActiveMCPTools: @escaping ToolIdleWaiter = { _ in },
        hasActiveMCPTools: @escaping RunBoolQuery = { _ in false },
        toolEndedCount: @escaping ToolEndedCountProvider = { _ in 0 },
        hasActiveChildAgentRunWaits: @escaping RunBoolQuery = { _ in false },
        drainChildAgentRunWaits: @escaping ChildAgentRunWaitDrainer = { _, _ in true }
    ) {
        toolIdleWaiter = awaitNoActiveMCPTools
        activeMCPToolQuery = hasActiveMCPTools
        toolEndedCountProvider = toolEndedCount
        activeChildAgentRunWaitQuery = hasActiveChildAgentRunWaits
        childAgentRunWaitDrainer = drainChildAgentRunWaits
    }

    func awaitNoActiveMCPTools(runID: UUID) async throws {
        try await toolIdleWaiter(runID)
    }

    func hasActiveMCPTools(runID: UUID) -> Bool {
        activeMCPToolQuery(runID)
    }

    func toolEndedCount(runID: UUID) -> Int {
        toolEndedCountProvider(runID)
    }

    func hasActiveChildAgentRunWaits(runID: UUID) -> Bool {
        activeChildAgentRunWaitQuery(runID)
    }

    func drainChildAgentRunWaits(runID: UUID, source: String) async -> Bool {
        await childAgentRunWaitDrainer(runID, source)
    }
}
