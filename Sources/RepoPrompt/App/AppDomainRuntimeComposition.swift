import Foundation
#if DEBUG
    import os
#endif
import RepoPromptDomainRuntime

private enum AppDomainRuntimeMetrics {
    static let editFlowSink = DomainRuntimeMetricsSink { metric in
        let dimensions = EditFlowPerf.Dimensions(
            toolName: metric.dimensions["tool_name"],
            outcome: metric.dimensions["outcome"],
            queueDelayMicroseconds: metric.name == "mcp_domain_host_queue_wait"
                ? metric.dimensions["duration_microseconds"].flatMap(Int.init)
                : nil,
            durationMicroseconds: metric.name == "mcp_domain_host_execution"
                ? metric.dimensions["duration_microseconds"].flatMap(Int.init)
                : nil
        )
        switch metric.name {
        case "mcp_domain_host_queue_wait":
            EditFlowPerf.event(EditFlowPerf.Stage.MCPToolCall.domainHostQueueWait, dimensions)
        case "mcp_domain_host_execution":
            EditFlowPerf.event(EditFlowPerf.Stage.MCPToolCall.domainHostExecution, dimensions)
        default:
            break
        }
    }
}

/// App-process composition for the M2 workspace/context domain authority.
/// Read providers and protected mutations remain app-owned until later milestones.
final class AppDomainRuntimeComposition: Sendable {
    static let shared = AppDomainRuntimeComposition()

    private static let legacyRuntimeDefaultKeys = [
        "workspace.approvalSettings",
        "agentModeAutoEditEnabled"
    ]

    let oracleConversationStore: DomainOracleConversationStore
    let oracleGroupRuntime: OracleGroupRuntime
    private let defaultRuntime: MCPDomainRuntime

    var runtime: MCPDomainRuntime {
        #if DEBUG
            if let runtime = runtimeForTesting { return runtime }
        #endif
        return defaultRuntime
    }

    #if DEBUG
        private let testRuntime = OSAllocatedUnfairLock<(id: UUID, runtime: MCPDomainRuntime)?>(initialState: nil)

        var runtimeForTesting: MCPDomainRuntime? {
            testRuntime.withLock { $0?.runtime }
        }

        enum RuntimeScopeError: Error { case ownersActive, alreadyScoped }

        /// Test-process-only composition scope. The caller must join its window, request and
        /// transport owners before returning; this never substitutes policy or routing decisions.
        @MainActor
        func withRuntimeForTesting(_ runtime: MCPDomainRuntime, operation: () async throws -> Void) async throws {
            // Initialize the normal singleton dependencies before selecting the test runtime so
            // their fallback references cannot accidentally retain the first fixture's runtime.
            let network = ServerNetworkManager.shared
            _ = AppGlobalMCPServiceComposition.shared
            guard await !(network.isRunning()),
                  !WindowStatesManager.shared.allWindows.contains(where: \.mcpServer.windowToolsEnabled)
            else { throw RuntimeScopeError.ownersActive }
            guard runtimeForTesting == nil else { throw RuntimeScopeError.alreadyScoped }
            let restoreRegistration = try AppGlobalMCPServiceComposition.shared.beginRuntimeScopeForTesting()
            let id = UUID()
            // No suspension separates the exclusivity checks, catalog parking and install.
            testRuntime.withLock { slot in
                precondition(slot == nil)
                slot = (id, runtime)
            }
            let restoreRuntime = {
                self.testRuntime.withLock { slot in
                    precondition(slot?.id == id)
                    slot = nil
                }
            }
            do {
                try await operation()
                await restoreRegistration(restoreRuntime)
            } catch {
                await restoreRegistration(restoreRuntime)
                throw error
            }
        }
    #endif

    static func collectLegacyRuntimeDefaults(from defaults: UserDefaults) -> [String: Data] {
        var collected: [String: Data] = [:]
        for key in legacyRuntimeDefaultKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                collected[key] = data
            } else if JSONSerialization.isValidJSONObject(["v": value]),
                      let data = try? JSONSerialization.data(
                          withJSONObject: value,
                          options: .fragmentsAllowed
                      )
            {
                collected[key] = data
            }
        }
        return collected
    }

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport.appendingPathComponent("RepoPrompt CE", isDirectory: true)
        let defaults = UserDefaults.standard
        let customStoragePath = defaults.string(forKey: "GlobalCustomStorageURL")
        var legacyRuntimeDefaults = Self.collectLegacyRuntimeDefaults(from: defaults)
        if let customStoragePath,
           let bytes = try? JSONEncoder().encode(customStoragePath)
        {
            legacyRuntimeDefaults["GlobalCustomStorageURL"] = bytes
        }
        let workspaceStorageDirectory = customStoragePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? root.appendingPathComponent("Workspaces", isDirectory: true)
        let runtime = MCPDomainRuntime(
            configuration: DomainRuntimeConfiguration(
                mode: .app,
                profileIdentifier: "default",
                storageDirectory: root,
                workspaceStorageDirectory: workspaceStorageDirectory,
                eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
                temporaryDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPrompt CE", isDirectory: true),
                legacyRuntimeDefaults: legacyRuntimeDefaults,
                metrics: AppDomainRuntimeMetrics.editFlowSink
            )
        )
        defaultRuntime = runtime
        oracleConversationStore = DomainOracleConversationStore(
            persistence: runtime.persistenceCoordinator,
            identity: runtime.identity
        )
        let oracleGroupClaimManager = OracleGroupClaimManager(
            persistence: runtime.persistenceCoordinator,
            identity: runtime.identity
        )
        oracleGroupRuntime = OracleGroupRuntime(
            store: oracleConversationStore,
            claimManager: oracleGroupClaimManager
        )
    }
}

/// Coalesces one shared registration task while preventing a late waiter from
/// clearing a newer attempt. Waiters observe the shared task's `Result`
/// directly, so cancelling a waiter does not misclassify the shared work.
@MainActor
final class SharedRegistrationAttempt<Value: Sendable> {
    struct Attempt {
        let id: UInt64
        let task: Task<Value, Error>
    }

    struct Completion {
        let result: Result<Value, Error>
        let wasCurrent: Bool
    }

    private var nextID: UInt64 = 0
    private(set) var current: Attempt?

    func start(
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) -> Attempt {
        precondition(current == nil, "Registration attempt already active")
        nextID &+= 1
        let attempt = Attempt(
            id: nextID,
            task: Task { @MainActor in
                try await operation()
            }
        )
        current = attempt
        return attempt
    }

    func complete(_ attempt: Attempt) async -> Completion {
        let result = await attempt.task.result
        let wasCurrent = current?.id == attempt.id
        if wasCurrent {
            current = nil
        }
        return Completion(result: result, wasCurrent: wasCurrent)
    }
}

/// Process-lifetime owner for application-scoped MCP services. Registration is
/// coalesced so app startup, readiness, and test fixtures all join the same work
/// and no caller receives a handle it could use to remove another caller's tools.
@MainActor
final class AppGlobalMCPServiceComposition {
    enum RegistrationStatus: Equatable {
        case idle
        case registering
        case registered
        case failed(String)

        var diagnosticDescription: String {
            switch self {
            case .idle:
                "idle"
            case .registering:
                "registering"
            case .registered:
                "registered"
            case let .failed(error):
                "failed(\(error))"
            }
        }
    }

    static let shared = AppGlobalMCPServiceComposition(
        runtime: AppDomainRuntimeComposition.shared.runtime,
        windowStates: .shared,
        networkManager: .shared
    )

    private struct RegistrationHandles {
        let appSettings: MCPDomainToolRegistrationHandle
        let windowRouting: MCPDomainToolRegistrationHandle
    }

    private let defaultRuntime: MCPDomainRuntime
    private var runtime: MCPDomainRuntime {
        #if DEBUG
            if let runtime = AppDomainRuntimeComposition.shared.runtimeForTesting { return runtime }
        #endif
        return defaultRuntime
    }

    private let networkManager: ServerNetworkManager
    private let appSettingsService: AppSettingsMCPService
    private let windowRoutingService: WindowRoutingService
    private var registrationHandles: RegistrationHandles?
    private let registrationAttempt = SharedRegistrationAttempt<RegistrationHandles>()
    private var status: RegistrationStatus = .idle

    private init(
        runtime: MCPDomainRuntime,
        windowStates: WindowStatesManager,
        networkManager: ServerNetworkManager
    ) {
        defaultRuntime = runtime
        self.networkManager = networkManager
        appSettingsService = AppSettingsMCPService()
        windowRoutingService = WindowRoutingService(
            windowStates: windowStates,
            networkMgr: networkManager
        )
    }

    #if DEBUG
        private var registrationOwnersForTesting = 0
        private var registrationOwnerWaitersForTesting: [CheckedContinuation<Void, Never>] = []

        struct RegistrationScopeStateForTesting: Equatable {
            let owners: Int
            let attemptID: UInt64?
            let handles: [MCPDomainToolRegistrationHandle]
            let status: RegistrationStatus
        }

        var registrationScopeStateForTesting: RegistrationScopeStateForTesting {
            .init(
                owners: registrationOwnersForTesting,
                attemptID: registrationAttempt.current?.id,
                handles: registrationHandles.map { [$0.appSettings, $0.windowRouting] } ?? [],
                status: status
            )
        }

        /// Park dormant default-runtime handles, never an in-flight registration owner. Each
        /// fixture gets fresh handle/attempt state and unregisters only its own exact handles.
        fileprivate func beginRuntimeScopeForTesting() throws -> (@MainActor (() -> Void) async -> Void) {
            guard registrationOwnersForTesting == 0, registrationAttempt.current == nil, status != .registering else {
                throw AppDomainRuntimeComposition.RuntimeScopeError.ownersActive
            }
            let savedHandles = registrationHandles
            let savedStatus = status
            registrationHandles = nil
            status = .idle
            return { restoreRuntime in
                if self.registrationOwnersForTesting > 0 {
                    await withCheckedContinuation { self.registrationOwnerWaitersForTesting.append($0) }
                }
                precondition(self.registrationAttempt.current == nil)
                if let handles = self.registrationHandles {
                    _ = await self.runtime.toolRegistry.unregister(handles.appSettings)
                    _ = await self.runtime.toolRegistry.unregister(handles.windowRouting)
                }
                // Restore the parked catalog ownership and runtime without another actor yield.
                self.registrationHandles = savedHandles
                self.status = savedStatus
                restoreRuntime()
            }
        }
    #endif

    func registrationStatus() -> RegistrationStatus {
        status
    }

    func ensureRegistered() async throws {
        #if DEBUG
            registrationOwnersForTesting += 1
            defer {
                registrationOwnersForTesting -= 1
                if registrationOwnersForTesting == 0 {
                    let waiters = registrationOwnerWaitersForTesting
                    registrationOwnerWaitersForTesting.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
        #endif
        if let registrationHandles,
           await AppDomainRuntimeComposition.shared.isActive(registrationHandles.appSettings),
           await AppDomainRuntimeComposition.shared.isActive(registrationHandles.windowRouting)
        {
            await restoreAvailabilityPublicationIfNeeded()
            status = .registered
            return
        }

        if let attempt = registrationAttempt.current {
            try await finishRegistration(attempt)
            return
        }

        status = .registering
        let attempt = registrationAttempt.start {
            @MainActor [runtime, networkManager, appSettingsService, windowRoutingService] in
            try await runtime.start()
            await windowRoutingService.prepareDomainTools()
            let appSettingsTools = await appSettingsService.tools
            let windowRoutingTools = await windowRoutingService.tools
            let requests = try [
                MCPDomainToolRegistrationRequest(
                    registrationID: appSettingsService.domainRegistrationID,
                    scope: .application,
                    bindings: appSettingsTools.map { try $0.domainBinding() }
                ),
                MCPDomainToolRegistrationRequest(
                    registrationID: windowRoutingService.domainRegistrationID,
                    scope: .application,
                    bindings: windowRoutingTools.map { try $0.domainBinding() }
                )
            ]
            let results = try await runtime.toolRegistry.registerAtomically(requests)
            if results.contains(where: { $0.disposition != .unchanged }) {
                ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
                await networkManager.broadcastToolListChanged()
            }
            return RegistrationHandles(
                appSettings: results[0].handle,
                windowRouting: results[1].handle
            )
        }
        try await finishRegistration(attempt)
    }

    private func finishRegistration(
        _ attempt: SharedRegistrationAttempt<RegistrationHandles>.Attempt
    ) async throws {
        let completion = await registrationAttempt.complete(attempt)
        switch completion.result {
        case let .success(handles):
            if completion.wasCurrent {
                registrationHandles = handles
                status = .registered
            }
            await restoreAvailabilityPublicationIfNeeded()
        case let .failure(error):
            if completion.wasCurrent {
                status = .failed(String(reflecting: error))
            }
            throw error
        }
    }

    private func restoreAvailabilityPublicationIfNeeded() async {
        let publishedNames = Set(ToolAvailabilityStore.shared.toolSummaries.map(\.name))
        guard !publishedNames.isSuperset(of: MCPGlobalToolName.orderedToolNames) else { return }

        let appSettingsTools = await appSettingsService.tools
        let windowRoutingTools = await windowRoutingService.tools
        ToolAvailabilityStore.shared.registerTools(appSettingsTools + windowRoutingTools)
    }
}
