import Foundation

actor DevinModelDiscoveryService {
    static let shared = DevinModelDiscoveryService()

    enum Outcome: Equatable {
        case notInstalled
        case discovered(modelCount: Int)
        case noModelsAdvertised
        case failed(message: String)
    }

    typealias InstalledCheck = @Sendable () -> Bool
    typealias SessionRunner = @Sendable (DevinAgentConfig) async throws -> Int?

    private let isInstalled: InstalledCheck
    private let runSession: SessionRunner
    private var inFlight: Task<Outcome, Never>?
    private var lastAttempt: Outcome?

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
        if let inFlight {
            return await inFlight.value
        }
        if !force, let lastAttempt {
            return lastAttempt
        }

        let task = Task { [isInstalled, runSession] in
            await AgentACPModelRegistry.shared.warmStandardStoreIfNeeded()
            if force {
                await CLIEnvironmentCache.shared.invalidate()
            }
            guard isInstalled() else { return Outcome.notInstalled }
            do {
                guard let count = try await runSession(
                    DevinAgentConfig(
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        includeRepoPromptMCPServer: false
                    )
                ), count > 0 else {
                    return .noModelsAdvertised
                }
                return .discovered(modelCount: count)
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        if outcome != .notInstalled {
            lastAttempt = outcome
        }
        return outcome
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
            _ = try await controller.bootstrap()
            let count = await controller.currentDiscoveredSessionModels()?.options.count
            await controller.shutdown()
            return count
        } catch {
            await controller.shutdown()
            throw provider.normalizeError(error)
        }
    }
}
