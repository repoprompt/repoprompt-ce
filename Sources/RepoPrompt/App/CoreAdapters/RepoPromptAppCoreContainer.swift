import Foundation
import RepoPromptCore

enum WorkspaceAuthorityBackend: String {
    case core
    case legacy
}

struct WorkspaceSessionRuntimeBundle: @unchecked Sendable {
    let sessionID: WorkspaceSessionID
    let commandIngress: any WorkspaceSessionCommandIngress
    let hydrate: @Sendable () async -> WorkspaceSessionHydrationResult
    let activateAfterApplyingFirstSnapshot: @Sendable (UInt64) async -> WorkspaceSessionActivationResult
    let shutdown: @Sendable () async -> Void
}

struct WorkspaceSessionRuntimeBootstrap: @unchecked Sendable {
    let sessionID: WorkspaceSessionID
    let commandIngress: DeferredWorkspaceSessionIngress
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
    static let shared = RepoPromptAppCoreContainer()

    let selectedBackend: WorkspaceAuthorityBackend

    private let coreHost: RepoPromptCoreHost?
    private var claimedWindowIDs: Set<Int> = []
    private let shadowComparator = WorkspaceShadowSnapshotComparator()

    init(
        userDefaults: UserDefaults = .standard,
        compiledDefault: WorkspaceAuthorityBackend = .core,
        debugOverride: WorkspaceAuthorityBackend? = nil
    ) {
        let configured = userDefaults.string(forKey: Self.backendDefaultsKey)
            .flatMap(WorkspaceAuthorityBackend.init(rawValue:))
        selectedBackend = debugOverride ?? configured ?? compiledDefault
        if let configuredRaw = userDefaults.string(forKey: Self.backendDefaultsKey), configured == nil {
            fputs("Ignoring invalid \(Self.backendDefaultsKey)=\(configuredRaw); using \(selectedBackend.rawValue)\n", stderr)
        }
        coreHost = selectedBackend == .core ? RepoPromptCoreHost() : nil
    }

    func makeRuntime(
        windowID: Int,
        coreDependencies: @escaping () -> RepoPromptCoreSessionDependencies,
        legacyFactory: () async throws -> WorkspaceSessionRuntimeBundle
    ) async throws -> WorkspaceSessionRuntimeBundle {
        precondition(claimedWindowIDs.insert(windowID).inserted, "window already claimed writable workspace authority")
        do {
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
                return WorkspaceSessionRuntimeBundle(
                    sessionID: registration.sessionID,
                    commandIngress: registration.handle,
                    hydrate: { await coreHost.hydrateSession(registration.sessionID) },
                    activateAfterApplyingFirstSnapshot: { sequence in
                        await coreHost.acknowledgeFirstSnapshotApplied(
                            sessionID: registration.sessionID,
                            sequence: sequence
                        )
                    },
                    shutdown: {
                        await coreHost.removeSession(registration.sessionID)
                    }
                )
            case .legacy:
                return try await legacyFactory()
            }
        } catch {
            claimedWindowIDs.remove(windowID)
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
        let deferred = DeferredWorkspaceSessionIngress(sessionID: sessionID)
        let selectedBackend = selectedBackend
        let coreHost = coreHost
        let task = Task<WorkspaceSessionRuntimeBundle, Error> { @MainActor [weak self] in
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
                        hydrate: { await coreHost.hydrateSession(sessionID) },
                        activateAfterApplyingFirstSnapshot: { sequence in
                            await coreHost.acknowledgeFirstSnapshotApplied(
                                sessionID: sessionID,
                                sequence: sequence
                            )
                        },
                        shutdown: { await coreHost.removeSession(sessionID) }
                    )
                case .legacy:
                    bundle = try await legacyFactory(sessionID)
                }
                await deferred.bind(bundle.commandIngress)
                return bundle
            } catch {
                self?.claimedWindowIDs.remove(windowID)
                throw error
            }
        }
        return WorkspaceSessionRuntimeBootstrap(
            sessionID: sessionID,
            commandIngress: deferred,
            runtimeTask: task
        )
    }

    func releaseRuntime(windowID: Int) {
        claimedWindowIDs.remove(windowID)
    }

    func compareReadOnlyShadow(
        authoritative: WorkspaceSessionSnapshot,
        shadow: WorkspaceSessionSnapshot
    ) async -> WorkspaceShadowSnapshotComparison {
        await shadowComparator.compare(authoritative: authoritative, shadow: shadow)
    }

    func shutdownForAppTermination() async {
        await coreHost?.shutdown()
        claimedWindowIDs.removeAll()
    }
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
