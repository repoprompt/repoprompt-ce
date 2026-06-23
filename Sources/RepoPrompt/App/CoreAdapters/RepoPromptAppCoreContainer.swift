import Foundation
import RepoPromptCore

enum WorkspaceAuthorityBackend: String {
    case core
    case legacy
}

enum WorkspaceRuntimeRoutingBackend: String {
    case lifecycleRegistry
    case legacyWindowBound
}

struct WorkspaceSessionRuntimeLifecycleControl: @unchecked Sendable {
    let runtimeID: WorkspaceRuntimeID
    let registry: WorkspaceRuntimeLifecycleRegistry

    func activate(
        initialAdmission: WorkspaceSessionAdmissionToken
    ) async -> WorkspaceRuntimeActivationResult {
        await registry.activate(runtimeID: runtimeID, initialAdmission: initialAdmission)
    }

    func beginDraining() async -> WorkspaceRuntimeDrainResult {
        await registry.beginDraining(runtimeID: runtimeID)
    }

    func waitUntilRemoved() async {
        await registry.waitUntilRemoved(runtimeID: runtimeID)
    }

    func snapshot() async -> WorkspaceRuntimeLifecycleSnapshot? {
        await registry.snapshot(runtimeID: runtimeID)
    }

    func purgeRemoved() async -> Bool {
        await registry.purgeRemoved(runtimeID: runtimeID)
    }
}

struct WorkspaceSessionRuntimeBundle: @unchecked Sendable {
    let sessionID: WorkspaceSessionID
    let commandIngress: any WorkspaceSessionCommandIngress
    let runtimeQuery: WorkspaceSessionQueryCapability
    let runtimeSessionHandle: WorkspaceRuntimeSessionHandle
    let runtimeLifecycle: WorkspaceSessionRuntimeLifecycleControl?
    let hydrate: @Sendable () async -> WorkspaceSessionHydrationResult
    let activateAfterApplyingFirstSnapshot: @Sendable (UInt64) async -> WorkspaceSessionActivationResult
    let factualProvider: any PromptFactualContextProviding
    let shutdown: @Sendable () async -> Void

    var runtimeID: WorkspaceRuntimeID? {
        runtimeLifecycle?.runtimeID
    }

    init(
        sessionID: WorkspaceSessionID,
        commandIngress: any WorkspaceSessionCommandIngress,
        runtimeQuery: WorkspaceSessionQueryCapability,
        runtimeSessionHandle: WorkspaceRuntimeSessionHandle? = nil,
        runtimeLifecycle: WorkspaceSessionRuntimeLifecycleControl? = nil,
        hydrate: @escaping @Sendable () async -> WorkspaceSessionHydrationResult,
        activateAfterApplyingFirstSnapshot: @escaping @Sendable (UInt64) async -> WorkspaceSessionActivationResult,
        factualProvider: any PromptFactualContextProviding,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.sessionID = sessionID
        self.commandIngress = commandIngress
        self.runtimeQuery = runtimeQuery
        self.runtimeSessionHandle = runtimeSessionHandle ?? WorkspaceRuntimeSessionHandle(
            sessionID: sessionID,
            query: runtimeQuery,
            currentSnapshot: { await commandIngress.currentSnapshot() },
            admit: { await commandIngress.admit() },
            execute: { await commandIngress.execute($0) },
            shutdown: { await commandIngress.shutdown() }
        )
        self.runtimeLifecycle = runtimeLifecycle
        self.hydrate = hydrate
        self.activateAfterApplyingFirstSnapshot = activateAfterApplyingFirstSnapshot
        self.factualProvider = factualProvider
        self.shutdown = shutdown
    }
}

struct WorkspaceSessionRuntimeBootstrap: @unchecked Sendable {
    let sessionID: WorkspaceSessionID
    let runtimeID: WorkspaceRuntimeID?
    let commandIngress: DeferredWorkspaceSessionIngress
    let factualProvider: DeferredPromptFactualContextProvider
    let runtimeTask: Task<WorkspaceSessionRuntimeBundle, Error>
}

/// App-wide authority selection and construction root.
///
/// Selection is immutable and resolved before a window asks for a runtime. The inactive branch
/// is represented only by a closure and is never evaluated, which prevents an unused store,
/// watcher graph, persistence writer, or revision allocator from being constructed.
@MainActor
final class RepoPromptAppCoreContainer {
    static let backendDefaultsKey = "coreIsolation.workspaceBackend"
    static let routingBackendDefaultsKey = "coreIsolation.runtimeRoutingBackend"
    static let shared = RepoPromptAppCoreContainer()

    let selectedBackend: WorkspaceAuthorityBackend
    let selectedRoutingBackend: WorkspaceRuntimeRoutingBackend

    private let coreHost: RepoPromptCoreHost?
    let runtimeLifecycleRegistry: WorkspaceRuntimeLifecycleRegistry?
    let runtimeAdapterRegistry: MCPAppRuntimeAdapterRegistry?
    private var claimedWindowIDs: Set<Int> = []
    private var runtimeIDsByWindowID: [Int: WorkspaceRuntimeID] = [:]
    private var runtimeShutdownsByWindowID: [Int: @Sendable () async -> Void] = [:]
    private let shadowComparator = WorkspaceShadowSnapshotComparator()

    init(
        userDefaults: UserDefaults = .standard,
        compiledDefault: WorkspaceAuthorityBackend = .core,
        debugOverride: WorkspaceAuthorityBackend? = nil,
        compiledRoutingDefault: WorkspaceRuntimeRoutingBackend = .lifecycleRegistry,
        debugRoutingOverride: WorkspaceRuntimeRoutingBackend? = nil
    ) {
        let configured = userDefaults.string(forKey: Self.backendDefaultsKey)
            .flatMap(WorkspaceAuthorityBackend.init(rawValue:))
        selectedBackend = debugOverride ?? configured ?? compiledDefault
        let configuredRouting = userDefaults.string(forKey: Self.routingBackendDefaultsKey)
            .flatMap(WorkspaceRuntimeRoutingBackend.init(rawValue:))
        selectedRoutingBackend = debugRoutingOverride ?? configuredRouting ?? compiledRoutingDefault
        if let configuredRaw = userDefaults.string(forKey: Self.backendDefaultsKey), configured == nil {
            fputs("Ignoring invalid \(Self.backendDefaultsKey)=\(configuredRaw); using \(selectedBackend.rawValue)\n", stderr)
        }
        if let configuredRaw = userDefaults.string(forKey: Self.routingBackendDefaultsKey), configuredRouting == nil {
            fputs(
                "Ignoring invalid \(Self.routingBackendDefaultsKey)=\(configuredRaw); using \(selectedRoutingBackend.rawValue)\n",
                stderr
            )
        }
        coreHost = selectedBackend == .core ? RepoPromptCoreHost() : nil
        let lifecycleRegistry = selectedRoutingBackend == .lifecycleRegistry
            ? WorkspaceRuntimeLifecycleRegistry()
            : nil
        runtimeLifecycleRegistry = lifecycleRegistry
        runtimeAdapterRegistry = lifecycleRegistry.map { registry in
            let holder = MCPRuntimeAdapterRegistryWeakHolder()
            let adapterRegistry = MCPAppRuntimeAdapterRegistry { runtimeID in
                Task {
                    _ = await registry.beginDraining(runtimeID: runtimeID)
                    await MainActor.run {
                        holder.registry?.confirmRuntimeDraining(runtimeID: runtimeID)
                    }
                    await registry.waitUntilRemoved(runtimeID: runtimeID)
                    await MainActor.run {
                        _ = holder.registry?.markRemoved(runtimeID: runtimeID)
                        _ = holder.registry?.purgeRemoved(runtimeID: runtimeID)
                    }
                    _ = await registry.purgeRemoved(runtimeID: runtimeID)
                }
            }
            holder.registry = adapterRegistry
            return adapterRegistry
        }
    }

    func makeRuntime(
        windowID: Int,
        coreDependencies: @escaping () -> RepoPromptCoreSessionDependencies,
        legacyFactory: () async throws -> WorkspaceSessionRuntimeBundle
    ) async throws -> WorkspaceSessionRuntimeBundle {
        precondition(claimedWindowIDs.insert(windowID).inserted, "window already claimed writable workspace authority")
        let runtimeID = runtimeLifecycleRegistry.map { _ in WorkspaceRuntimeID() }
        if let runtimeID { runtimeIDsByWindowID[windowID] = runtimeID }
        do {
            let bundle: WorkspaceSessionRuntimeBundle
            switch selectedBackend {
            case .core:
                guard let coreHost else {
                    throw WorkspaceRuntimeConstructionError.missingSelectedBackend
                }
                guard let registration = await coreHost.createSession(
                    id: WorkspaceSessionID(),
                    dependencies: coreDependencies()
                ) else {
                    throw WorkspaceRuntimeConstructionError.duplicateSession
                }
                bundle = WorkspaceSessionRuntimeBundle(
                    sessionID: registration.sessionID,
                    commandIngress: registration.handle,
                    runtimeQuery: registration.handle.query,
                    runtimeSessionHandle: registration.handle.runtimeSessionHandle(),
                    hydrate: { await coreHost.hydrateSession(registration.sessionID) },
                    activateAfterApplyingFirstSnapshot: { sequence in
                        await coreHost.acknowledgeFirstSnapshotApplied(
                            sessionID: registration.sessionID,
                            sequence: sequence
                        )
                    },
                    factualProvider: CorePromptFactualContextProvider(handle: registration.handle),
                    shutdown: {
                        await coreHost.removeSession(registration.sessionID)
                    }
                )
            case .legacy:
                bundle = try await legacyFactory()
            }
            let installed = try await installRuntimeLifecycle(bundle, runtimeID: runtimeID)
            runtimeShutdownsByWindowID[windowID] = installed.shutdown
            return installed
        } catch {
            claimedWindowIDs.remove(windowID)
            runtimeIDsByWindowID.removeValue(forKey: windowID)
            throw error
        }
    }

    /// Synchronous construction seam used by the app's synchronous WindowState initializer.
    /// The selected store and fail-closed ingress exist immediately; the selected backend is
    /// constructed on `runtimeTask`. No command is queued while the target is absent.
    func beginRuntime(
        windowID: Int,
        coreDependencies: @escaping () -> RepoPromptCoreSessionDependencies,
        legacyFactory: @escaping (WorkspaceSessionID) async throws -> WorkspaceSessionRuntimeBundle
    ) -> WorkspaceSessionRuntimeBootstrap {
        precondition(claimedWindowIDs.insert(windowID).inserted, "window already claimed writable workspace authority")
        let sessionID = WorkspaceSessionID()
        let runtimeID = runtimeLifecycleRegistry.map { _ in WorkspaceRuntimeID() }
        if let runtimeID { runtimeIDsByWindowID[windowID] = runtimeID }
        let deferred = DeferredWorkspaceSessionIngress(sessionID: sessionID)
        let deferredFactualProvider = DeferredPromptFactualContextProvider()
        let selectedBackend = selectedBackend
        let coreHost = coreHost
        let task = Task<WorkspaceSessionRuntimeBundle, Error> { @MainActor [self] in
            do {
                let bundle: WorkspaceSessionRuntimeBundle
                switch selectedBackend {
                case .core:
                    guard let coreHost else { throw WorkspaceRuntimeConstructionError.missingSelectedBackend }
                    guard let registration = await coreHost.createSession(
                        id: sessionID,
                        dependencies: coreDependencies()
                    ) else { throw WorkspaceRuntimeConstructionError.duplicateSession }
                    bundle = WorkspaceSessionRuntimeBundle(
                        sessionID: sessionID,
                        commandIngress: registration.handle,
                        runtimeQuery: registration.handle.query,
                        runtimeSessionHandle: registration.handle.runtimeSessionHandle(),
                        hydrate: { await coreHost.hydrateSession(sessionID) },
                        activateAfterApplyingFirstSnapshot: { sequence in
                            await coreHost.acknowledgeFirstSnapshotApplied(
                                sessionID: sessionID,
                                sequence: sequence
                            )
                        },
                        factualProvider: CorePromptFactualContextProvider(handle: registration.handle),
                        shutdown: { await coreHost.removeSession(sessionID) }
                    )
                case .legacy:
                    bundle = try await legacyFactory(sessionID)
                }
                let registeredBundle = try await installRuntimeLifecycle(bundle, runtimeID: runtimeID)
                runtimeShutdownsByWindowID[windowID] = registeredBundle.shutdown
                await deferred.bind(registeredBundle.commandIngress)
                await deferredFactualProvider.bind(registeredBundle.factualProvider)
                return registeredBundle
            } catch {
                claimedWindowIDs.remove(windowID)
                runtimeIDsByWindowID.removeValue(forKey: windowID)
                throw error
            }
        }
        return WorkspaceSessionRuntimeBootstrap(
            sessionID: sessionID,
            runtimeID: runtimeID,
            commandIngress: deferred,
            factualProvider: deferredFactualProvider,
            runtimeTask: task
        )
    }

    func releaseRuntime(windowID: Int) {
        claimedWindowIDs.remove(windowID)
        runtimeShutdownsByWindowID.removeValue(forKey: windowID)
        guard let runtimeID = runtimeIDsByWindowID[windowID] else { return }
        guard let runtimeLifecycleRegistry else {
            runtimeIDsByWindowID.removeValue(forKey: windowID)
            return
        }
        Task { @MainActor [weak self] in
            guard await runtimeLifecycleRegistry.purgeRemoved(runtimeID: runtimeID) else { return }
            if self?.runtimeIDsByWindowID[windowID] == runtimeID {
                self?.runtimeIDsByWindowID.removeValue(forKey: windowID)
            }
        }
    }

    func compareReadOnlyShadow(
        authoritative: WorkspaceSessionSnapshot,
        shadow: WorkspaceSessionSnapshot
    ) async -> WorkspaceShadowSnapshotComparison {
        await shadowComparator.compare(authoritative: authoritative, shadow: shadow)
    }

    func shutdownForAppTermination() async {
        if let runtimeAdapterRegistry {
            for mapping in runtimeAdapterRegistry.latestRoutingTableSnapshot.mappings {
                _ = runtimeAdapterRegistry.beginClosing(runtimeID: mapping.runtimeID)
            }
        }
        for shutdown in runtimeShutdownsByWindowID.values {
            await shutdown()
        }
        if let runtimeLifecycleRegistry {
            let runtimeIDs = Array(runtimeIDsByWindowID.values)
            for runtimeID in runtimeIDs {
                _ = await runtimeLifecycleRegistry.beginDraining(runtimeID: runtimeID)
            }
            for runtimeID in runtimeIDs {
                await runtimeLifecycleRegistry.waitUntilRemoved(runtimeID: runtimeID)
                _ = await runtimeLifecycleRegistry.purgeRemoved(runtimeID: runtimeID)
                _ = runtimeAdapterRegistry?.markRemoved(runtimeID: runtimeID)
                _ = runtimeAdapterRegistry?.purgeRemoved(runtimeID: runtimeID)
            }
        }
        await coreHost?.shutdown()
        claimedWindowIDs.removeAll()
        runtimeIDsByWindowID.removeAll()
        runtimeShutdownsByWindowID.removeAll()
    }

    private func installRuntimeLifecycle(
        _ bundle: WorkspaceSessionRuntimeBundle,
        runtimeID: WorkspaceRuntimeID?
    ) async throws -> WorkspaceSessionRuntimeBundle {
        guard let runtimeID, let runtimeLifecycleRegistry else { return bundle }
        let registration = await runtimeLifecycleRegistry.register(
            runtimeID: runtimeID,
            sessionHandle: bundle.runtimeSessionHandle
        )
        guard registration == .registered else {
            await bundle.shutdown()
            throw WorkspaceRuntimeConstructionError.runtimeRegistration(registration)
        }
        let lifecycle = WorkspaceSessionRuntimeLifecycleControl(
            runtimeID: runtimeID,
            registry: runtimeLifecycleRegistry
        )
        let sessionActivation = bundle.activateAfterApplyingFirstSnapshot
        let runtimeSessionHandle = bundle.runtimeSessionHandle
        return WorkspaceSessionRuntimeBundle(
            sessionID: bundle.sessionID,
            commandIngress: bundle.commandIngress,
            runtimeQuery: bundle.runtimeQuery,
            runtimeSessionHandle: runtimeSessionHandle,
            runtimeLifecycle: lifecycle,
            hydrate: bundle.hydrate,
            activateAfterApplyingFirstSnapshot: { sequence in
                let result = await sessionActivation(sequence)
                guard case .activated = result else { return result }
                guard case let .admitted(initialAdmission) = await runtimeSessionHandle.admit() else {
                    return .notReady(.failed("runtime lifecycle initial admission failed"))
                }
                switch await lifecycle.activate(initialAdmission: initialAdmission) {
                case .activated, .alreadyActive:
                    return result
                case let .invalidState(state):
                    return .notReady(.failed("runtime lifecycle activation failed from \(state.rawValue)"))
                case .runtimeNotFound, .sessionMismatch, .activationMismatch:
                    return .notReady(.failed("runtime lifecycle activation identity mismatch"))
                }
            },
            factualProvider: bundle.factualProvider,
            shutdown: {
                _ = await lifecycle.beginDraining()
                await lifecycle.waitUntilRemoved()
            }
        )
    }
}

@MainActor
private final class MCPRuntimeAdapterRegistryWeakHolder {
    weak var registry: MCPAppRuntimeAdapterRegistry?
}

actor DeferredWorkspaceSessionIngress: WorkspaceSessionCommandIngress {
    nonisolated let sessionID: WorkspaceSessionID
    private var target: (any WorkspaceSessionCommandIngress)?

    init(sessionID: WorkspaceSessionID) {
        self.sessionID = sessionID
    }

    func bind(_ target: any WorkspaceSessionCommandIngress) {
        precondition(self.target == nil, "selected workspace ingress may be bound only once")
        self.target = target
    }

    func currentSnapshot() async -> WorkspaceSessionSnapshot? {
        guard let target else { return nil }
        return await target.currentSnapshot()
    }

    func observations(after sequence: UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot> {
        guard let target else { return AsyncStream { $0.finish() } }
        return await target.observations(after: sequence)
    }

    func admit() async -> WorkspaceSessionAdmissionResult {
        guard let target else { return .notReady(.hydrating) }
        return await target.admit()
    }

    func execute(_ command: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult {
        guard let target else { return .notReady(.hydrating) }
        return await target.execute(command)
    }

    func shutdown() async {
        await target?.shutdown()
    }
}

enum WorkspaceRuntimeConstructionError: Error, Equatable {
    case missingSelectedBackend
    case duplicateSession
    case runtimeRegistration(WorkspaceRuntimeRegistrationResult)
}

struct WorkspaceShadowSnapshotComparison: Equatable {
    let workspacesMatch: Bool
    let activeWorkspaceMatches: Bool
    let selectionsMatch: Bool
}

/// Shadow validation intentionally accepts immutable values only. It owns no runtime,
/// persistence, watcher, revision allocator, or command capability.
private actor WorkspaceShadowSnapshotComparator {
    func compare(
        authoritative: WorkspaceSessionSnapshot,
        shadow: WorkspaceSessionSnapshot
    ) -> WorkspaceShadowSnapshotComparison {
        WorkspaceShadowSnapshotComparison(
            workspacesMatch: authoritative.workspaces == shadow.workspaces,
            activeWorkspaceMatches: authoritative.activeWorkspaceID == shadow.activeWorkspaceID,
            selectionsMatch: authoritative.selectionRevisions == shadow.selectionRevisions
        )
    }
}
