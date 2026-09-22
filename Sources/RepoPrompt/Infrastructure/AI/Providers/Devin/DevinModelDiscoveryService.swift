import Foundation

actor DevinModelDiscoveryService {
    static let shared = DevinModelDiscoveryService()

    enum Outcome: Equatable {
        case notInstalled
        case discovered(modelCount: Int)
        case noModelsAdvertised
        case failed(message: String)

        /// Transient failures and "not installed" stay uncached so Settings can retry.
        fileprivate var isReusable: Bool {
            switch self {
            case .discovered, .noModelsAdvertised:
                true
            case .notInstalled, .failed:
                false
            }
        }
    }

    typealias InstalledCheck = @Sendable () -> Bool
    typealias SessionRunner = @Sendable (DevinAgentConfig) async throws -> Int?

    private let isInstalled: InstalledCheck
    private let runSession: SessionRunner
    private var inFlight: Task<Outcome, Never>?
    private var inFlightID = 0
    private var lastAttempt: Outcome?
    private var waiterCount = 0

    init(
        isInstalled: @escaping InstalledCheck = { DevinRuntimeLocator.isInstalledSync() },
        runSession: @escaping SessionRunner = { config in
            try await DevinModelDiscoveryService.runThrowawaySession(config)
        }
    ) {
        self.isInstalled = isInstalled
        self.runSession = runSession
    }

    func discoverIfNeeded(force: Bool = false) async -> Outcome {
        if !force, inFlight == nil, let lastAttempt, lastAttempt.isReusable {
            return lastAttempt
        }
        waiterCount += 1
        let task: Task<Outcome, Never>
        let requestID: Int
        if let inFlight, !inFlight.isCancelled {
            task = inFlight
            requestID = inFlightID
        } else {
            inFlightID += 1
            requestID = inFlightID
            task = Task { [isInstalled, runSession] in
                await AgentACPModelRegistry.shared.warmStandardStoreIfNeeded()
                if force {
                    await CLIEnvironmentCache.shared.invalidate()
                }
                guard isInstalled() else { return Outcome.notInstalled }
                do {
                    try Task.checkCancellation()
                    guard let count = try await runSession(
                        DevinAgentConfig(
                            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                            includeRepoPromptMCPServer: false
                        )
                    ), count > 0 else {
                        try Task.checkCancellation()
                        return .noModelsAdvertised
                    }
                    try Task.checkCancellation()
                    return .discovered(modelCount: count)
                } catch is CancellationError {
                    return .failed(message: "cancelled")
                } catch {
                    return .failed(message: error.localizedDescription)
                }
            }
            inFlight = task
        }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.cancelSharedDiscovery(id: requestID) }
        }
        waiterCount -= 1
        if waiterCount == 0 {
            inFlight = nil
        }
        if !Task.isCancelled, outcome.isReusable {
            lastAttempt = outcome
        }
        return outcome
    }

    private func cancelSharedDiscovery(id: Int) {
        guard inFlightID == id, waiterCount <= 1 else { return }
        inFlight?.cancel()
    }

    private static func runThrowawaySession(_ config: DevinAgentConfig) async throws -> Int? {
        let provider = DevinACPAgentProvider(config: config)
        let request = ACPRunRequest(
            agentKind: .devin,
            modelString: nil,
            workspacePath: nil,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        let support = try await provider.support(for: request)
        guard case .supported = support else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Devin ACP is not available."
            )
        }

        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            try Task.checkCancellation()
            _ = try await controller.bootstrap()
            try Task.checkCancellation()
            let count = await controller.currentDiscoveredSessionModels()?.options.count
            await controller.shutdown()
            return count
        } catch {
            await controller.shutdown()
            throw error is CancellationError ? error : provider.normalizeError(error)
        }
    }
}
